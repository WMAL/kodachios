#!/usr/bin/env python3
# Kodachi Command Windows - typed direct execution layer
#
# SPDX-License-Identifier: LicenseRef-Kodachi-SAN-1.1
# Copyright (c) 2013-2026 Warith Al Maawali
#
# This file is part of Kodachi OS.
# For full license terms, see LICENSE.md or visit:
# https://kodachi.cloud/docs/license.html
#
# Commercial or organizational use requires a written license.
# Contact: warith@digi77.com
#
"""Typed direct execution for Cairo GTK controls.

The generated contract is shared with ColonyOps, but this module is not.  GTK
loads the data, validates it, and starts the named business executable itself.
Legacy shell payloads remain source evidence only and never reach ``Popen``.
"""

from __future__ import annotations

import json
import hashlib
import os
import shlex
import signal
import subprocess
import time
from pathlib import Path


CONTRACT_PATH = Path(
    "/usr/local/share/kodachi/dock/gtk-direct-operations.json")
SCHEMA_VERSION = 1
SUDO = "/usr/bin/sudo"

# kodachi-repo-apt announces itself on stdout the moment it becomes root, so
# the Repository Manager can tell "pkexec is still waiting for a password" from
# "the helper is alive but quiet". That sentinel is PROTOCOL, and this module is
# the OTHER consumer of the same helper: 16 dock cells in
# gtk-direct-operations.json run it with outputMode "bounded-text", and the
# transcript built below is shown to the operator verbatim. Without this filter
# every one of those cells opens with a line of machine protocol.
#
# THIS IS NOW DEFENCE IN DEPTH, NOT THE FIX, and saying so matters because a
# reader who thinks it is the fix will not look for the real one. Filtering
# here covers the DOCK path only: the Tauri dashboard runs the same 16 verbs
# from Rust (commands_linux.rs, via colonyops-linux-command-manifest.json) and
# never touches this module, so a filter here left 16 of 32 leaking surfaces
# uncovered. The actual fix is that the helper emits the sentinel ONLY when
# asked, behind an explicit --protocol flag that only the Repository Manager
# passes. This strip stays because it is three lines and it catches a future
# caller that passes the flag by mistake.
#
# THE LITERAL IS DUPLICATED IN THREE FILES ON PURPOSE. The helper runs as root
# and deliberately imports no kodachi_* module, so a shared constant would mean
# widening a privileged program's import surface to save a string. A contract
# asserts all three copies are identical instead.
HELPER_STARTED = "kodachi-helper-started:"
PROXY_BASENAMES = {
    "bash",
    "dash",
    "fish",
    "ksh",
    "kodachi-command-window",
    "kodachi-dock-action",
    "kodachi-dock-status",
    "sh",
    "tcsh",
    "zsh",
}
DIRECT_KINDS = {"linux", "rust", "workflow-profile"}
EXPECTED_ACTIONABLE_DENOMINATORS = {
    "commandWindowRows": 410,
    "torExitDraftControls": 87,
    "torExcludePresetDraftControls": 4,
    "torExcludeCountryDraftControls": 76,
    "repositoryStaticTemplates": 19,
    "statusWindowCommandControls": 0,
}
DENIED_EXECUTABLES = {
    "/bin/rm", "/usr/bin/rm", "/bin/sudo", "/usr/bin/sudo",
}
LINUX_EXECUTABLES = frozenset({
    "/usr/bin/gnunet-fs-gtk",
    "/usr/bin/mousepad",
    "/usr/bin/nyx",
    "/usr/bin/sleep",
    "/usr/bin/syncthing",
    "/usr/bin/systemctl",
    "/usr/bin/thunar",
    "/usr/bin/xfce4-terminal",
    "/usr/bin/x-terminal-emulator",
    "/usr/bin/xdg-open",
    "/usr/local/libexec/kodachi/kodachi-browser-profile",
    "/usr/local/libexec/kodachi/kodachi-decoy-traffic",
    "/usr/local/libexec/kodachi/kodachi-display-mode",
    "/usr/local/libexec/kodachi/kodachi-repo-apt",
    "/usr/local/libexec/kodachi/kodachi-sshkeys-regen",
})


class DirectContractError(RuntimeError):
    """The generated direct-operation contract is absent or unsafe."""


def _contract_path():
    path = CONTRACT_PATH
    if path.is_file():
        try:
            stat = path.stat()
        except OSError as exc:
            raise DirectContractError(
                f"the GTK direct-operation contract cannot be inspected: {exc}") from exc
        if path.is_symlink() or stat.st_uid != 0 or stat.st_mode & 0o022:
            raise DirectContractError(
                "the GTK direct-operation contract is not a root-owned, "
                "non-writable regular file")
        return path
    raise DirectContractError(
        "the GTK direct-operation contract is not installed; refusing a "
        "legacy shell fallback"
    )


def _read_contract(path=None):
    source = Path(path) if path is not None else _contract_path()
    try:
        document = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise DirectContractError(
            f"the GTK direct-operation contract is unreadable: {exc}"
        ) from exc
    if document.get("schemaVersion") != SCHEMA_VERSION:
        raise DirectContractError("the contract schema version is unsupported")
    denominators = document.get("actionableControlDenominators")
    if (not isinstance(denominators, dict)
            or denominators != EXPECTED_ACTIONABLE_DENOMINATORS
            or document.get("gtkActionableControlOccurrenceCount")
            != sum(EXPECTED_ACTIONABLE_DENOMINATORS.values())):
        raise DirectContractError(
            "the contract actionable-control denominator is not generator-derived")
    if document.get("gtkProxyCellCount") != 0:
        raise DirectContractError("the contract still contains presentation proxies")
    command_window = document.get("commandWindow")
    if not isinstance(command_window, dict):
        raise DirectContractError("the contract has no commandWindow object")
    operations = command_window.get("operations")
    if not isinstance(operations, list) or not operations:
        raise DirectContractError("the contract has no command-window operations")
    if command_window.get("gtkProxyCellCount") != 0:
        raise DirectContractError("the command-window contract contains a proxy")
    encoded = json.dumps(
        operations, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    measured = hashlib.sha256(encoded).hexdigest()
    if command_window.get("directOperationsSha256") != measured:
        raise DirectContractError("the direct-operation contract digest is invalid")
    cells = document.get("cells")
    if not isinstance(cells, list) or not cells:
        raise DirectContractError("the contract has no canonical cell inventory")
    cell_map = {}
    for cell in cells:
        cell_id = cell.get("id") if isinstance(cell, dict) else None
        if not isinstance(cell_id, str) or not cell_id or cell_id in cell_map:
            raise DirectContractError("the canonical cell inventory has an invalid ID")
        cell_map[cell_id] = cell
    return source, document, operations, cell_map


def _validate_string_list(value, field, identity):
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise DirectContractError(f"{identity}: {field} must be a string list")
    return list(value)


def _validate_binding(binding, identity, cells, linux_executables):
    if not isinstance(binding, dict):
        raise DirectContractError(f"{identity}: direct binding is not an object")
    kind = binding.get("kind")
    if kind not in DIRECT_KINDS:
        raise DirectContractError(f"{identity}: unsupported direct kind {kind!r}")
    executable = binding.get("executable")
    if not isinstance(executable, str) or not executable.startswith("/"):
        raise DirectContractError(f"{identity}: executable is not absolute")
    if os.path.basename(executable) in PROXY_BASENAMES:
        raise DirectContractError(
            f"{identity}: presentation proxy {executable!r} cannot execute a GTK control"
        )
    if executable in DENIED_EXECUTABLES:
        raise DirectContractError(
            f"{identity}: denied executable {executable!r} cannot execute a GTK control")
    if kind == "linux" and executable not in linux_executables:
        raise DirectContractError(
            f"{identity}: executable {executable!r} is outside the canonical "
            "Linux target set")
    cell_id = binding.get("cellId")
    cell = cells.get(cell_id)
    if cell is None:
        raise DirectContractError(f"{identity}: binding has no canonical cell")
    if ((kind in {"rust", "workflow-profile"}
         and not cell_id.startswith("rust."))
            or (kind == "linux" and not cell_id.startswith("linux."))):
        raise DirectContractError(
            f"{identity}: binding kind differs from its canonical cell ID")
    canonical_executable = cell.get("executable")
    if canonical_executable != executable:
        raise DirectContractError(
            f"{identity}: binding executable differs from its canonical cell")
    if kind in {"rust", "workflow-profile"}:
        service = binding.get("service") or cell.get("service") or cell.get("binary")
        if (not isinstance(service, str) or not service
                or executable != "/opt/kodachi/dashboard/hooks/" + service):
            raise DirectContractError(
                f"{identity}: Rust target is outside the canonical hook set")
    argv = _validate_string_list(binding.get("argv"), "argv", identity)
    canonical_argv = cell.get("argvTemplate", cell.get("argv"))
    if canonical_argv != argv:
        raise DirectContractError(
            f"{identity}: binding argv differs from its canonical cell")
    timeout = binding.get("timeoutSeconds")
    if (timeout != cell.get("timeoutSeconds")
            or not isinstance(timeout, int) or timeout <= 0):
        raise DirectContractError(
            f"{identity}: binding timeout differs from its canonical cell")
    stdin_parameters = _validate_string_list(
        binding.get("stdinParameters", []), "stdinParameters", identity
    )
    parameters = binding.get("parameters", [])
    if not isinstance(parameters, list) or not all(
        isinstance(item, dict) and isinstance(item.get("name"), str)
        for item in parameters
    ):
        raise DirectContractError(f"{identity}: parameters are malformed")
    source_evidence = binding.get("sourceEvidence")
    if not isinstance(source_evidence, dict) or not source_evidence.get("path"):
        raise DirectContractError(f"{identity}: sourceEvidence is missing")
    run_as = binding.get("runAsUser")
    if run_as is not None and (
        not isinstance(run_as, str)
        or not run_as
        or any(ch not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
               for ch in run_as)
    ):
        raise DirectContractError(f"{identity}: runAsUser is invalid")
    if not isinstance(binding.get("needsSudo"), bool):
        raise DirectContractError(f"{identity}: needsSudo must be boolean")
    if not isinstance(binding.get("dangerLevel"), str):
        raise DirectContractError(f"{identity}: dangerLevel is missing")
    if not isinstance(binding.get("confirmation"), dict):
        raise DirectContractError(f"{identity}: confirmation metadata is missing")
    for field, binding_value in (
        ("needsSudo", binding.get("needsSudo")),
        ("runAsUser", binding.get("runAsUser")),
        ("stdinParameters", stdin_parameters),
        ("parameters", parameters),
        ("dangerLevel", binding.get("dangerLevel")),
        ("confirmation", binding.get("confirmation")),
        ("sourceEvidence", source_evidence),
    ):
        canonical_value = cell.get(field)
        if field in {"stdinParameters", "parameters"} and canonical_value is None:
            canonical_value = []
        if canonical_value != binding_value:
            raise DirectContractError(
                f"{identity}: binding {field} differs from its canonical cell")
    validated = dict(binding)
    validated.update({
        "argv": argv,
        "stdinParameters": stdin_parameters,
        "parameters": parameters,
    })
    return validated


def _validate_execution_policy(operation, bindings, identity):
    policy = operation.get("executionPolicy")
    if not isinstance(policy, dict):
        raise DirectContractError(f"{identity}: executionPolicy is missing")
    step_policy = policy.get("stepPolicy")
    expected_policy = (
        "profile" if len(bindings) == 1 and bindings[0].get("profile")
        else "single" if len(bindings) == 1
        else "direct-sequence"
    )
    if step_policy != expected_policy:
        raise DirectContractError(
            f"{identity}: execution policy differs from its binding shape")
    steps = policy.get("orderedSteps")
    if (not isinstance(steps, list)
            or (not steps and step_policy != "profile")):
        raise DirectContractError(f"{identity}: ordered execution steps are missing")
    for step in steps:
        if (not isinstance(step, dict)
                or not isinstance(step.get("commandId"), str)
                or not isinstance(step.get("condition"), str)
                or not step.get("condition")):
            raise DirectContractError(f"{identity}: ordered step is malformed")
        delay = step.get("delaySeconds")
        if delay is not None and (
                not isinstance(delay, (int, float)) or delay < 0 or delay > 300):
            raise DirectContractError(f"{identity}: ordered step delay is unsafe")
        if (step_policy != "profile"
                and step.get("condition") not in {"always", "if_success", "if_fail"}):
            raise DirectContractError(
                f"{identity}: unsupported direct step condition "
                f"{step.get('condition')!r}")
    if step_policy == "single":
        if (len(steps) != 1
                or steps[0]["commandId"] != bindings[0]["cellId"]):
            raise DirectContractError(
                f"{identity}: single-step identity differs from its binding")
    elif step_policy == "profile":
        binding = bindings[0]
        profile_digest = binding.get("profileDigest")
        child_ids = binding.get("childCommandIds")
        included_profiles = binding.get("includedProfiles", [])
        if (not isinstance(profile_digest, str) or len(profile_digest) != 64
                or any(ch not in "0123456789abcdef" for ch in profile_digest)
                or not isinstance(child_ids, list)
                or not isinstance(included_profiles, list)
                or not all(isinstance(item, str) and item
                           for item in included_profiles)
                or (not child_ids and not included_profiles)
                or child_ids != [step["commandId"] for step in steps]):
            raise DirectContractError(
                f"{identity}: workflow profile identity or child order is invalid")
        if binding.get("orderedSteps") != steps:
            raise DirectContractError(
                f"{identity}: workflow binding and operation steps differ")
    else:
        if ([step["commandId"] for step in steps]
                != [binding["cellId"] for binding in bindings]):
            raise DirectContractError(
                f"{identity}: direct sequence order differs from its bindings")
        if any(step.get("postReadback") or step.get("rollback") for step in steps):
            raise DirectContractError(
                f"{identity}: direct sequence has backend semantics with no owner")
    launch_policy = policy.get("launchHandoffPolicy")
    if not isinstance(launch_policy, dict):
        raise DirectContractError(f"{identity}: launch handoff policy is missing")
    occurrences = operation["occurrences"]
    modes = sorted({item["execution"] for item in occurrences})
    if (launch_policy.get("executionModes") != modes
            or launch_policy.get("launch") != ("launch" in modes)
            or launch_policy.get("handoff")
            != any(item["handoff"] for item in occurrences)):
        raise DirectContractError(
            f"{identity}: launch handoff policy differs from its occurrences")
    if policy.get("postReadbackPolicy") not in {
            "none", "explicit-check-control"}:
        raise DirectContractError(f"{identity}: post-readback policy is invalid")
    rollback = policy.get("rollbackPolicy")
    if not isinstance(rollback, list):
        raise DirectContractError(f"{identity}: rollback policy is malformed")
    expected_rollback = [step.get("rollback") for step in steps
                         if step.get("rollback")]
    if rollback != expected_rollback:
        raise DirectContractError(
            f"{identity}: rollback policy differs from the ordered steps")
    if step_policy != "profile":
        if any(step.get("postReadback") or step.get("rollback") for step in steps):
            raise DirectContractError(
                f"{identity}: local execution policy has backend semantics with no owner")
        if rollback:
            raise DirectContractError(
                f"{identity}: local rollback policy has no execution owner")
        if policy.get("postReadbackPolicy") == "explicit-check-control":
            # One generated status operation may be reused by an explicit
            # Check control and by a report-style Act control.  The policy is
            # owned when at least one real occurrence is the check producer;
            # requiring every reuse to carry that role rejects valid aliases.
            if not any(item.get("role") == "check" for item in occurrences):
                raise DirectContractError(
                    f"{identity}: local post-readback policy has no execution owner")
    return dict(policy)


class DirectOperations:
    """Validated mapping from registry identity to direct executable plans."""

    def __init__(self, path=None, linux_executables=LINUX_EXECUTABLES):
        self.path, self.document, operations, cells = _read_contract(path)
        self.operations = {}
        operation_ids = set()
        for operation in operations:
            if not isinstance(operation, dict):
                raise DirectContractError("command-window operation is not an object")
            category = operation.get("category")
            label = operation.get("label")
            if not isinstance(category, str) or not isinstance(label, str):
                raise DirectContractError("command-window operation has no identity")
            key = (category, label)
            if key in self.operations:
                raise DirectContractError(f"duplicate command-window operation {key!r}")
            operation_id = operation.get("id")
            if (not isinstance(operation_id, str)
                    or not operation_id.startswith("gtk.operation.")):
                raise DirectContractError(
                    f"{category} / {label}: generated operation ID is invalid")
            if operation_id in operation_ids:
                raise DirectContractError(
                    f"duplicate generated operation ID {operation_id!r}")
            operation_ids.add(operation_id)
            occurrences = operation.get("occurrences")
            if (not isinstance(occurrences, list) or not occurrences
                    or not all(
                        isinstance(item, dict)
                        and item.get("execution") in {"wait", "launch"}
                        and isinstance(item.get("handoff"), bool)
                        for item in occurrences)):
                raise DirectContractError(
                    f"{category} / {label}: execution occurrences are malformed")
            raw_bindings = operation.get("directBindings")
            if not isinstance(raw_bindings, list) or not raw_bindings:
                raise DirectContractError(f"{category} / {label}: no direct binding")
            bindings = [
                _validate_binding(
                    binding, f"{category} / {label}", cells,
                    frozenset(linux_executables))
                for binding in raw_bindings
            ]
            if operation.get("cellId") != bindings[0]["cellId"]:
                raise DirectContractError(
                    f"{category} / {label}: operation cell differs from binding")
            stored = dict(operation)
            stored["directBindings"] = bindings
            stored["executionPolicy"] = _validate_execution_policy(
                stored, bindings, f"{category} / {label}")
            self.operations[key] = stored
        controls = self.document["commandWindow"].get("controls")
        if not isinstance(controls, list) or not controls:
            raise DirectContractError("the command-window control inventory is absent")
        control_ids = set()
        reference_count = 0
        for control in controls:
            control_id = control.get("id") if isinstance(control, dict) else None
            if (not isinstance(control_id, str)
                    or not control_id.startswith("gtk.control.")
                    or control_id in control_ids):
                raise DirectContractError("the control inventory has an invalid ID")
            control_ids.add(control_id)
            references = control.get("references")
            if not isinstance(references, list):
                raise DirectContractError(f"{control_id}: control has no registry reference")
            if not references:
                # PRODUCER-OWNED KINDS CARRY NO REGISTRY REFERENCE BY DESIGN.
                # `surface` was the only one when this was written. `sandbox`
                # joined it and this line was not updated, so regenerating the
                # manifest after the Firejail Sandbox window landed produced a
                # contract this loader REFUSES ENTIRELY, which breaks every GTK
                # command window, not just that one. That is why the manifest
                # sat 8 rows stale on master instead of failing visibly.
                #
                # AND IT HAPPENED A SECOND TIME, 2026-08-26, which is why this
                # list is now derived from the producers rather than from the
                # kind that happened to exist when somebody last looked. The
                # Containers window landed, `sandbox()` in kodachi_windows.py
                # was RENAMED to `isolated()` and a new `launch()` producer was
                # added, so the regenerated contract carries kinds `isolated`
                # and `launch` and ZERO `sandbox`. `sandbox` is dropped here
                # because it now has 0 call sites in kodachi_windows.py, and
                # keeping a dead kind in an exemption list is what widens this
                # door silently. The dispatch at `elif kind == "sandbox"` in
                # kodachi-command-window is dead for the same reason.
                #
                # Neither exemption launders a wiring defect, both were read at
                # the producer rather than assumed: an `isolated` row carries
                # its own app_id/executable/profile and is exec'd through
                # kodachi-isolation-launcher directly, and a `launch` row
                # carries a literal absolute argv TUPLE that the producer
                # itself refuses unless argv[0] is absolute and every element
                # is a string literal, which is a stricter boundary than a
                # registry reference, not a weaker one. A `surface` row is
                # drawn by its own producer exactly as before.
                # A `fact` row is a READING, and its execution is owned by its SECTION rather
                # than by the row: `mode: "facts"` declares ONE `source` registry pair, the
                # driver resolves it through the same `resolve()` every other row uses, runs it
                # ONCE, and paints every row in the panel from that single reply. So the row
                # genuinely carries no registry reference of its own, and it is exempt for the
                # same reason the three below are: the producer owns the execution, not because
                # anything is unwired.
                if control.get("kind") not in ("surface", "isolated", "launch", "fact"):
                    raise DirectContractError(
                        f"{control_id}: actionable control has no registry reference")
                continue
            for reference in references:
                reference_count += 1
                registry_key = reference.get("registryKey") \
                    if isinstance(reference, dict) else None
                role = reference.get("role") if isinstance(reference, dict) else None
                if (not isinstance(registry_key, list) or len(registry_key) != 2
                        or not all(isinstance(item, str) and item
                                   for item in registry_key)
                        or not isinstance(role, str) or not role):
                    raise DirectContractError(
                        f"{control_id}: registry key or role is malformed")
                operation = self.operations.get(tuple(registry_key))
                if operation is None or reference.get("cellId") != operation.get("cellId"):
                    raise DirectContractError(
                        f"{control_id}: registry reference differs from its operation")
        command_window = self.document["commandWindow"]
        occurrence_count = sum(
            len(operation["occurrences"]) for operation in self.operations.values())
        denominators = self.document["actionableControlDenominators"]
        if (command_window.get("uniqueRegistryOperations") != len(self.operations)
                or command_window.get("registryReferenceOccurrences")
                != occurrence_count
                or reference_count != occurrence_count
                or command_window.get("actionableRows")
                != denominators["commandWindowRows"]):
            raise DirectContractError(
                "the generated command-window census differs from its inventory")

    def operation(self, key):
        identity = tuple(key or ())
        operation = self.operations.get(identity)
        if operation is None:
            shown = " / ".join(identity) if identity else "<missing identity>"
            raise DirectContractError(
                f"{shown}: no generated direct operation; refusing legacy payload"
            )
        return operation

    def bindings(self, key):
        return self.operation(key)["directBindings"]

    def launch_allows_handoff(self, key):
        policy = self.operation(key)["executionPolicy"]["launchHandoffPolicy"]
        if not policy["launch"]:
            raise DirectContractError(
                "the generated operation is not declared as a launcher")
        return policy["handoff"]

    def preview(self, key, parameters=None):
        bindings = self.bindings(key)
        values = dict(parameters or {})
        allowed = {item["name"] for binding in bindings
                   for item in binding["parameters"]}
        unexpected = sorted(set(values) - allowed)
        if unexpected:
            raise DirectContractError(
                "unexpected typed parameter(s): " + ", ".join(unexpected))
        commands = []
        for binding in bindings:
            names = {item["name"] for item in binding["parameters"]}
            selected = {name: values[name] for name in names if name in values}
            if names and not selected:
                argv = [binding["executable"], *binding["argv"]]
                if binding.get("needsSudo") or binding.get("runAsUser"):
                    prefix = [SUDO, "-n"]
                    if binding.get("runAsUser"):
                        prefix.extend(["-u", binding["runAsUser"]])
                    argv = [*prefix, *argv]
            else:
                argv = self.argv_for(binding, selected)
            commands.append(shlex.join(argv))
        return " && ".join(commands)

    def argv_for(self, binding, parameters=None):
        values = dict(parameters or {})
        descriptors = {item["name"]: item for item in binding["parameters"]}
        allowed = set(descriptors)
        unexpected = sorted(set(values) - allowed)
        if unexpected:
            raise DirectContractError(
                "unexpected typed parameter(s): " + ", ".join(unexpected)
            )
        argv = []
        for token in binding["argv"]:
            if token.startswith("{") and token.endswith("}") and token.count("{") == 1:
                name = token[1:-1]
                value = values.get(name)
                if not isinstance(value, str) or not value:
                    raise DirectContractError(f"required typed parameter {name!r} is absent")
                if any(ord(character) < 32 or ord(character) == 127
                       for character in value):
                    raise DirectContractError(
                        f"typed parameter {name!r} contains a control character")
                kind = descriptors.get(name, {}).get("type")
                if kind == "device" and not value.startswith("/dev/"):
                    raise DirectContractError(
                        f"typed device parameter {name!r} is not under /dev/")
                if kind in {"file", "path", "directory"} and not value.startswith("/"):
                    raise DirectContractError(
                        f"typed path parameter {name!r} is not absolute")
                options = descriptors.get(name, {}).get("options")
                if isinstance(options, list) and options and value not in options:
                    raise DirectContractError(
                        f"typed parameter {name!r} is outside its declared options")
                argv.append(value)
            else:
                if "{" in token or "}" in token:
                    raise DirectContractError(
                        f"partial argv interpolation is forbidden: {token!r}"
                    )
                argv.append(token)
        for descriptor in binding["parameters"]:
            if descriptor.get("type") != "boolean":
                continue
            name = descriptor["name"]
            value = values.get(name, False)
            if not isinstance(value, bool):
                raise DirectContractError(
                    f"typed boolean parameter {name!r} must be true or false")
            flag = descriptor.get("flag")
            if (not isinstance(flag, str) or not flag.startswith("--")
                    or len(flag) <= 2
                    or any(not (character.isascii() and (
                        character.isalnum() or character == "-"))
                           for character in flag[2:])):
                raise DirectContractError(
                    f"typed boolean parameter {name!r} has no safe declared flag")
            if value and flag not in argv:
                argv.append(flag)
        executable = binding["executable"]
        if not os.path.isfile(executable) or not os.access(executable, os.X_OK):
            raise DirectContractError(
                f"canonical executable is absent or not executable: {executable}"
            )
        business = [executable, *argv]
        if binding.get("needsSudo") or binding.get("runAsUser"):
            if not os.path.isfile(SUDO) or not os.access(SUDO, os.X_OK):
                raise DirectContractError(f"non-interactive privilege tool is absent: {SUDO}")
            privileged = [SUDO, "-n"]
            if binding.get("runAsUser"):
                privileged.extend(["-u", binding["runAsUser"]])
            return [*privileged, *business]
        return business


_REGISTRY = None


def registry(path=None, reload=False):
    global _REGISTRY
    if path is not None:
        return DirectOperations(path)
    if reload or _REGISTRY is None:
        _REGISTRY = DirectOperations()
    return _REGISTRY


def _stdin_for(binding, stdin_values):
    names = binding["stdinParameters"]
    if not names:
        if stdin_values not in (None, b"", ""):
            raise DirectContractError("stdin was supplied to an operation that forbids it")
        return None
    if isinstance(stdin_values, bytearray):
        if len(stdin_values) > 65536:
            raise DirectContractError("confidential stdin exceeds 65536 bytes")
        return stdin_values
    if not isinstance(stdin_values, dict):
        raise DirectContractError(
            "required stdin must have one mutable bytearray owner")
    missing = [name for name in names
               if not isinstance(stdin_values.get(name), bytearray)]
    if missing:
        raise DirectContractError("required stdin value(s) are absent: " + ", ".join(missing))
    payload = bytearray()
    for index, name in enumerate(names):
        if index:
            payload.append(10)
        payload.extend(stdin_values[name])
    payload.append(10)
    if len(payload) > 65536:
        wipe_secret(payload)
        raise DirectContractError("confidential stdin exceeds 65536 bytes")
    return payload


def wipe_secret(value):
    """Overwrite every mutable secret owner reachable from ``value``."""
    if isinstance(value, bytearray):
        value[:] = b"\0" * len(value)
        value.clear()
    elif isinstance(value, dict):
        for item in value.values():
            wipe_secret(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            wipe_secret(item)


def _write_secret(pipe, secret):
    view = memoryview(secret)
    written = 0
    try:
        while written < len(view):
            count = os.write(pipe.fileno(), view[written:])
            if count <= 0:
                raise OSError("secret stdin pipe stopped accepting bytes")
            written += count
    finally:
        view.release()
        pipe.close()


def _strip_helper_protocol(body):
    """Drop kodachi-repo-apt's startup sentinel from user-visible output.

    Line-anchored, so a package name or an apt message that merely CONTAINS
    the literal is not silently eaten from the transcript the operator reads.
    Only a line that begins with it is protocol.
    """
    if HELPER_STARTED not in body:
        return body
    return "\n".join(line for line in body.split("\n")
                      if not line.startswith(HELPER_STARTED))


def _terminate(proc):
    if getattr(proc, "stdin", None) is not None and getattr(proc.stdin, "closed", False):
        proc.stdin = None
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.communicate(timeout=1.0)
        return
    except (subprocess.TimeoutExpired, ValueError):
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        proc.communicate(timeout=1.0)
    except (subprocess.TimeoutExpired, ValueError):
        try:
            proc.wait(timeout=1.0)
        except (subprocess.TimeoutExpired, ValueError):
            pass


def run(key, parameters=None, stdin_values=None, timeout=240, contract=None,
        sleeper=time.sleep):
    """Run every direct binding in order and stop at the first failure."""
    direct = contract or registry()
    transcript = []
    final_code = 0
    result_code = 0
    bindings = direct.bindings(key)
    policy = direct.operation(key)["executionPolicy"]
    steps = policy["orderedSteps"]
    all_parameter_names = {
        item["name"] for binding in bindings for item in binding["parameters"]
    }
    values = dict(parameters or {})
    unexpected = sorted(set(values) - all_parameter_names)
    if unexpected:
        raise DirectContractError(
            "unexpected typed parameter(s): " + ", ".join(unexpected))
    all_stdin_names = {
        name for binding in bindings for name in binding["stdinParameters"]
    }
    if isinstance(stdin_values, dict):
        unexpected_stdin = sorted(set(stdin_values) - all_stdin_names)
        if unexpected_stdin:
            raise DirectContractError(
                "unexpected stdin parameter(s): " + ", ".join(unexpected_stdin))
    elif stdin_values not in (None, b"", ""):
        accepting = sum(bool(binding["stdinParameters"]) for binding in bindings)
        if accepting != 1 or not isinstance(stdin_values, bytearray):
            raise DirectContractError(
                "one mutable stdin owner requires exactly one accepting step")
    try:
        previous_code = 0
        if policy["stepPolicy"] == "profile":
            # The workflow-manager binding owns every child condition, delay,
            # readback and rollback in the profile digest.  GTK invokes that
            # backend exactly once and must not reinterpret or truncate it.
            execution_plan = [(bindings[0], None)]
        else:
            execution_plan = list(zip(bindings, steps))
        for binding, step in execution_plan:
            if step is not None:
                condition = step["condition"]
                if condition == "if_success" and previous_code != 0:
                    continue
                if condition == "if_fail" and previous_code == 0:
                    continue
                delay = step.get("delaySeconds")
                if delay:
                    sleeper(delay)
            parameter_names = {item["name"] for item in binding["parameters"]}
            binding_values = {name: values[name] for name in parameter_names
                              if name in values}
            if isinstance(stdin_values, dict):
                if binding["stdinParameters"]:
                    binding_stdin = {
                        name: stdin_values[name]
                        for name in binding["stdinParameters"] if name in stdin_values
                    }
                else:
                    binding_stdin = None
            elif binding["stdinParameters"]:
                binding_stdin = stdin_values
            else:
                binding_stdin = None
            argv = direct.argv_for(binding, binding_values)
            input_buffer = _stdin_for(binding, binding_stdin)
            proc = subprocess.Popen(
                argv,
                stdin=subprocess.PIPE if input_buffer is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            if input_buffer is not None:
                secret_pipe = proc.stdin
                try:
                    _write_secret(secret_pipe, input_buffer)
                except (OSError, ValueError):
                    proc.stdin = None
                    _terminate(proc)
                    raise
                finally:
                    proc.stdin = None
                    wipe_secret(input_buffer)
            try:
                step_timeout = binding["timeoutSeconds"]
                stdout, stderr = proc.communicate(timeout=step_timeout)
                final_code = proc.returncode
                previous_code = final_code
                if final_code != 0 and result_code == 0:
                    result_code = final_code
            except subprocess.TimeoutExpired:
                _terminate(proc)
                return 124, (
                    "\n".join(transcript)
                    + f"\nThe direct operation exceeded {step_timeout} seconds and was stopped.\n"
                ).lstrip()
            body = (stdout or b"").decode("utf-8", "replace")
            body += (stderr or b"").decode("utf-8", "replace")
            body = _strip_helper_protocol(body)
            if body:
                transcript.append(body.rstrip())
            if final_code != 0 and policy["stepPolicy"] != "direct-sequence":
                break
        return result_code, "\n".join(transcript)
    except (OSError, ValueError) as exc:
        return 1, ("\n".join(transcript)
                   + f"\nDirect execution failed: {exc}\n").lstrip()
    finally:
        wipe_secret(stdin_values)


def launch(key, parameters=None, stdin_values=None, survival_seconds=0.75,
           contract=None):
    """Launch exactly one direct binding and prove it survives the handoff."""
    direct = contract or registry()
    allow_handoff = direct.launch_allows_handoff(key)
    bindings = direct.bindings(key)
    if len(bindings) != 1:
        raise DirectContractError("launch operations must have exactly one direct binding")
    binding = bindings[0]
    argv = direct.argv_for(binding, parameters)
    if stdin_values not in (None, b"", ""):
        raise DirectContractError("launch operations cannot own confidential stdin")
    input_text = _stdin_for(binding, None)
    try:
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            errors="replace",
            start_new_session=True,
        )
        if input_text is not None and proc.stdin is not None:
            proc.stdin.write(input_text)
            proc.stdin.close()
        code = proc.wait(timeout=survival_seconds)
    except subprocess.TimeoutExpired:
        return 0, "Opened. The direct application is still running."
    except (OSError, ValueError) as exc:
        return 1, f"Could not open the direct application: {exc}"
    if code == 0 and allow_handoff:
        return 0, "Opened. The direct application completed its handoff."
    if code == 0:
        return 1, "The direct application exited before the survival check completed."
    return code, f"The direct application exited with code {code}."
