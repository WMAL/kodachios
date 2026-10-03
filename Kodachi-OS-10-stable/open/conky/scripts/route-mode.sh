#!/usr/bin/env bash
set -u
# F19: answer from the snapshot-generation memo when nothing this script reads has
# changed (conky-snapshot-memo.sh explains why the output is identical). Any doubt
# falls through to the unchanged body below.
if [[ -z "${CONKY_MEMO_INNER:-}" && -r "${BASH_SOURCE[0]%/*}/conky-snapshot-memo.sh" ]]; then
    . "${BASH_SOURCE[0]%/*}/conky-snapshot-memo.sh" && conky_memo_run "${BASH_SOURCE[0]}" "$@"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true

BIN="$(conky_gateway_find_binary 2>/dev/null || true)"

gv() {
  conky_gateway_get_or_default "$1" "$2" 2 "$BIN"
}
bool_onoff() {
  # Builtin lowercasing: the old `$(printf | tr)` forked a subshell and exec'd tr per call.
  #
  # "Unknown" IS A THIRD ANSWER. conky-status publishes "?" for a reading it could
  # not take, and a JSON null arrives here as this script's own default, so the old
  # catch-all turned both into a flat "Off" and the HUD printed
  # "VPN Off  TOR Off  TORRIFY Off" off reads that never happened. That is the
  # defect a user reported on the dashboard's Tor row on 2026-09-28. The DNSCrypt
  # block below has had the three-state treatment since 2026-09-17; the other four
  # fields did not.
  case "${1,,}" in
    true|yes|on|1) printf 'On' ;;
    \?|unknown|null|n/a|na|"") printf 'Unknown' ;;
    *) printf 'Off' ;;
  esac
}
# ONE SNAPSHOT READ FOR ALL EIGHTEEN KEYS, NOT EIGHTEEN. Live-ISO gaps b21/b25, measured
# 2026-09-04 on testvm-kodachi-0425b0 at load 0.5: `route-mode.sh mode` cost 112 forks and
# 298 ms per run, the single most expensive directive in conkyrc-security.conf, and it runs
# every 17 seconds (about 400 forks a minute on its own). Every one of those forks was the
# per-key gateway path (stat + jq + subshells) repeated once per key (twelve keys then,
# eighteen since the `_known` companions) over the same file.
# conky_gateway_get_many reads the snapshot once for all keys with identical TTL, alias and
# absent-means-default semantics, and falls back to per-key reads whenever the batch cannot
# be served. Defaults differ per key, so the batch uses one sentinel and the per-key default
# is applied here; a sentinel value that survives is by construction "absent".
ROUTE_KEYS=(
  data.routing.connected data.routing.protocol data.routing.server data.routing.tun_device
  data.tor.torrified data.tor.onoff data.tor.tor_dns
  data.dns.dnscrypt_active data.dns.configured_as_resolver data.dns.dnscrypt_service_up
  data.health.internet.status data.auth.login
  data.dns.dnscrypt_known data.dns.dnscrypt_onoff
  data.routing.connected_known data.tor.torrified_known data.tor.tor_dns_known
  data.tor.running_known
)
# The five `_known` defaults are "false" (round 3c, R4, 2026-10-01). They used to be
# "true" so a snapshot written before those fields existed kept the old On/Off rendering,
# but a default is also what a key gets when the gateway MISSES ON PURPOSE (a snapshot
# from before the last Kodachi state change, conky-gateway-common.sh) and
# `conky-status get` cannot answer either: "true" then turned that unread state into a
# known "Off" ("Torrify Off", "VPN Off", mode "Direct"). Every snapshot conky-status
# writes carries these fields, so an absent one now means "not read": Unknown.
# conky-status publishes dnscrypt_known false (with null booleans and dnscrypt_onoff
# "Unknown") when its DNSCrypt readback failed.
ROUTE_DEFAULTS=(false None "" "" false Off false false false false N/A N/A false "" false false false false)
ROUTE_ABSENT="__CONKY_ROUTE_ABSENT__"
route_vals=()
if declare -F conky_gateway_get_many >/dev/null 2>&1; then
  # The batch's own fallback forwards these, so a stale snapshot costs the same eighteen
  # per-key reads with the once-resolved $BIN that the old loop cost, not eighteen resolutions.
  mapfile -t route_vals < <(CONKY_GATEWAY_MANY_TIMEOUT=2 CONKY_GATEWAY_MANY_BIN="$BIN" conky_gateway_get_many "$ROUTE_ABSENT" "${ROUTE_KEYS[@]}" 2>/dev/null)
fi
if [[ "${#route_vals[@]}" -ne "${#ROUTE_KEYS[@]}" ]]; then
  # Short or absent batch: read per key, exactly the old path, with the same sentinel so
  # an absent key is told apart from a read the same way on both paths.
  route_vals=()
  for _i in "${!ROUTE_KEYS[@]}"; do
    route_vals+=("$(gv "${ROUTE_KEYS[$_i]}" "$ROUTE_ABSENT")")
  done
fi
route_absent=()
for _i in "${!ROUTE_KEYS[@]}"; do
  if [[ "${route_vals[$_i]}" == "$ROUTE_ABSENT" ]]; then
    route_absent[$_i]=1
    route_vals[$_i]="${ROUTE_DEFAULTS[$_i]}"
  fi
done
# Round 4 (V8, measured on <lab-host>, 2026-10-01): when the snapshot predates the
# last state change, the gateway answers EACH key with its own `conky-status get`, so a
# value and its `_known` companion are two reads seconds apart. During the collection that
# follows a torrify the value's read timed out (absent, so its default `false`) while the
# companion's read landed on the new snapshot (`true`), and the pair printed a known
# "TORRIFY Off" 22 s after the torrify finished. An absent value is never a reading,
# whatever its companion says.
route_unread_if_absent() {
  [[ -n "${route_absent[$1]:-}" ]] && route_vals[$2]=false
  return 0
}
route_unread_if_absent 0 14   # data.routing.connected -> connected_known
route_unread_if_absent 4 15   # data.tor.torrified -> torrified_known
route_unread_if_absent 6 16   # data.tor.tor_dns -> tor_dns_known
route_unread_if_absent 5 17   # data.tor.onoff -> running_known
for _i in 7 8 9 13; do        # the DNSCrypt row's four inputs -> dnscrypt_known
  route_unread_if_absent "$_i" 12
done
vpn_connected="${route_vals[0]}"
vpn_protocol="${route_vals[1]}"
vpn_server="${route_vals[2]}"
vpn_tun="${route_vals[3]}"
torrified="${route_vals[4]}"
tor_onoff="${route_vals[5]}"
tor_dns="${route_vals[6]}"
dnscrypt_active="${route_vals[7]}"
dnscrypt_configured="${route_vals[8]}"
dnscrypt_listening="${route_vals[9]}"
internet="${route_vals[10]}"
auth="${route_vals[11]}"
dnscrypt_known="${route_vals[12]}"
dnscrypt_onoff="${route_vals[13]}"
vpn_known="${route_vals[14]}"
torrified_known="${route_vals[15]}"
tor_dns_known="${route_vals[16]}"
tor_running_known="${route_vals[17]}"
# A null boolean reaches this script as its own default (`false`), so the `_known`
# companion is the only way to tell "measured off" from "not measured". Positive
# evidence is never overridden: only an Off is downgraded to Unknown.
demote_unread() {
  local current="$1" known="$2"
  # Only a literal true is known (conky_known_is_true); "?", null or "" demote too.
  if [[ "$current" == "Off" ]] && ! conky_known_is_true "$known"; then
    printf 'Unknown'
  else
    printf '%s' "$current"
  fi
}
vpn_on="$(demote_unread "$(bool_onoff "$vpn_connected")" "$vpn_known")"
torrify_on="$(demote_unread "$(bool_onoff "$torrified")" "$torrified_known")"
tor_daemon_on="$(demote_unread "$(bool_onoff "$tor_onoff")" "$tor_running_known")"
tor_dns_on="$(demote_unread "$(bool_onoff "$tor_dns")" "$tor_dns_known")"
# A failed DNSCrypt readback is not a reading of Off: its booleans are null,
# which the gateway treats as absent and defaults to false, so without this
# check the panel printed "DNSCRYPT Off" while dnscrypt-proxy was running.
if ! conky_known_is_true "$dnscrypt_known" || [[ "$dnscrypt_onoff" == "Unknown" || "$dnscrypt_active" == "null" ]]; then
  dnscrypt_on="Unknown"
elif [[ "$dnscrypt_active" =~ ^[Tt]rue$ && "$dnscrypt_configured" =~ ^[Tt]rue$ && "$dnscrypt_listening" =~ ^[Tt]rue$ ]]; then
  dnscrypt_on="On"
else
  dnscrypt_on="Off"
fi

[[ -n "$vpn_protocol" && "$vpn_protocol" != "None" && "$vpn_protocol" != "null" ]] || vpn_protocol="VPN"

# "Direct" IS A CLAIM: it tells the user their traffic leaves unprotected. It may
# only be printed when both protections were actually READ and both said off.
mode="Direct"
if [[ "$torrify_on" == "On" && "$vpn_on" == "On" ]]; then
  mode="Tor over ${vpn_protocol}"
elif [[ "$torrify_on" == "On" ]]; then
  mode="Torified"
elif [[ "$vpn_on" == "On" ]]; then
  mode="$vpn_protocol"
elif [[ "$torrify_on" == "Unknown" || "$vpn_on" == "Unknown" ]]; then
  mode="Unknown"
fi

case "${1:-summary}" in
  mode) printf '%s\n' "$mode" ;;
  compact)
    printf 'NET %s  AUTH %s  VPN %s  TOR %s  TORRIFY %s  DNSCRYPT %s\n' "$internet" "$auth" "$vpn_on" "$tor_daemon_on" "$torrify_on" "$dnscrypt_on"
    ;;
  json)
    printf '{"mode":"%s","vpn":"%s","protocol":"%s","server":"%s","tun":"%s","tor":"%s","torrify":"%s","tor_dns":"%s","dnscrypt":"%s"}\n' "$mode" "$vpn_on" "$vpn_protocol" "$vpn_server" "$vpn_tun" "$tor_daemon_on" "$torrify_on" "$tor_dns_on" "$dnscrypt_on"
    ;;
  *)
    printf '%s | VPN %s | Tor %s | Torrify %s | DNSCrypt %s\n' "$mode" "$vpn_on" "$tor_daemon_on" "$torrify_on" "$dnscrypt_on"
    ;;
esac
