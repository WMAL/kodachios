--==============================================================================
-- Conky Gauges - Cairo-based circular gauges for Kodachi
--
-- SPDX-License-Identifier: LicenseRef-Kodachi-SAN-1.1
-- Copyright (c) 2013-2026 Warith Al Maawali
--
-- This file is part of Kodachi OS.
-- For full license terms, see LICENSE.md or visit:
-- https://kodachi.cloud/docs/license.html
--
-- Commercial or organizational use requires a written license.
-- Contact: warith@digi77.com
--
-- Author: Warith Al Maawali
-- Version: 9.0.1
-- Last updated: 2026-02-05
--
-- Description:
-- Cairo-based circular gauges for Kodachi desktop monitoring.
-- Order: UP/DOWN, CPU/MEM, DISK/SWAP, PING/BWIDTH
-- Ping gauge has two indicators: domain ping (outer) and DNS ping (inner)
-- Security hardened: Input validation, nil checks, pcall error handling
--==============================================================================

require 'cairo'
-- Optional: newer conky (Kodachi trixie 1.22.1) ships cairo_xlib as a separate
-- module (libcairo_xlib.so); older conky on other distros (e.g. Ubuntu 22.04's
-- 1.12.2) does not, and a hard require there aborts the whole gauge script so no
-- gauge draws. cairo_xlib_surface_create is still a global from require 'cairo',
-- so guard the require and keep drawing regardless of distro.
pcall(function() require 'cairo_xlib' end)

--------------------------------------------------------------------------------
-- Input validation patterns (security hardening)
-- Only allow alphanumeric and dash for interface names
local VALID_INTERFACE_PATTERN = "^[%w%-]+$"

--------------------------------------------------------------------------------
-- Sanitize input to prevent shell injection
local function sanitize_input(input, pattern)
    if not input or input == "" then
        return nil
    end
    input = tostring(input):gsub("%s+", "")
    if not input:match(pattern) then
        return nil
    end
    return input
end

--------------------------------------------------------------------------------
-- Safe shell command execution with error handling
local function safe_popen(cmd)
    local handle = io.popen(cmd .. " 2>/dev/null")
    if not handle then
        return nil
    end
    local result = handle:read("*a")
    local success = handle:close()
    if not success or not result then
        return nil
    end
    return result
end

-- Build absolute script path from current user home.
local function script_path(script_name)
    local home = os.getenv("HOME")
    if not home or home == "" then
        return nil
    end
    return home .. "/.config/kodachi/conky/scripts/" .. script_name
end

--------------------------------------------------------------------------------
-- Run a gateway wrapper script safely and trim first line output.
local function gateway_script_value(script_name, args, fallback)
    local path = script_path(script_name)
    if not path then
        return fallback
    end

    local cmd = path
    if args and args ~= "" then
        cmd = cmd .. " " .. args
    end

    local result = safe_popen(cmd)
    if not result then
        return fallback
    end

    local line = result:match("([^\n\r]+)") or ""
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then
        return fallback
    end

    return line
end

--------------------------------------------------------------------------------
-- Run a gateway wrapper script once and return ALL of its output lines.
--
-- Sibling of gateway_script_value above, for scripts that answer several fields in one
-- invocation. Same safety rules: nil script path or a failed popen yields nil and every
-- caller must have a fallback.
local function gateway_script_lines(script_name, args, expected)
    local path = script_path(script_name)
    if not path then
        return nil
    end

    local cmd = path
    if args and args ~= "" then
        cmd = cmd .. " " .. args
    end

    local result = safe_popen(cmd)
    if not result then
        return nil
    end

    local lines = {}
    for line in result:gmatch("([^\n\r]+)") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        lines[#lines + 1] = line
    end

    -- ANTI-VACUITY: a caller that unpacks positionally is corrupted, not merely degraded,
    -- by a short read, because every field after the missing one shifts up by one. Refuse
    -- the batch rather than return a plausible-looking wrong answer, and let the caller
    -- fall back to its per-field path.
    if expected and #lines ~= expected then
        return nil
    end

    return lines
end

--------------------------------------------------------------------------------
-- Get default network interface dynamically (with validation)
local function get_default_interface()
    local result = gateway_script_value("network-status.sh", "active", "eth0")
    if not result or result == "N/A" then
        return "eth0"
    end
    result = result:gsub("%s+", "")
    -- Validate interface name (alphanumeric + dash only)
    local validated = sanitize_input(result, VALID_INTERFACE_PATTERN)
    if validated then
        return validated
    end
    return "eth0"
end

local default_iface = get_default_interface()

--------------------------------------------------------------------------------
-- Network speed tracking for percentage calculation (in KB/s)
local max_upload_speed = 1024    -- Initial baseline 1 MB/s
local max_download_speed = 1024  -- Initial baseline 1 MB/s

--------------------------------------------------------------------------------
-- DNS servers and domains for random ping
-- Privacy-respecting DNS servers only (no Google)
-- Store last ping values
local last_dns_ping = 0
local last_domain_ping = 0
local ping_update_counter = 0

--------------------------------------------------------------------------------
-- Security status cache (AUTH, VPN, TORRIFIED, DNS)
local security_status = {auth=0, vpn=0, torrified=0, dns=0}
local security_update_counter = 0

--------------------------------------------------------------------------------
-- Get security status from script
local function get_security_status()
    security_update_counter = security_update_counter + 1
    -- Update every 5 cycles (~15 seconds with 3s update interval)
    if security_update_counter % 5 == 1 then
        local result = gateway_script_value("security-status.sh", "all", nil)
        if result then
            local auth, vpn, torrified, dns = result:match("(%d)%s+(%d)%s+(%d)%s+(%d)")
            security_status.auth = tonumber(auth) or 0
            security_status.vpn = tonumber(vpn) or 0
            security_status.torrified = tonumber(torrified) or 0
            security_status.dns = tonumber(dns) or 0
        end
    end
    return security_status
end

--------------------------------------------------------------------------------
-- Draw Security Status Binary - 4 columns x 8 rows BINARY gauge style
-- [V][V][T][T]  x 2 rows = VPN/TOR top
-- [D][D][A][A]  x 2 rows = DNS/AUTH bottom
-- Text goes to the right of this block
local function draw_security_binary(cr)
    local status = get_security_status()
    local start_x, start_y = 5, 4
    local block_size = 5
    local spacing = 1

    -- Single color for enabled (cyan)
    local color_enabled = 0x06B6D4

    -- 4 columns x 6 rows = 24 blocks
    -- Quadrant mapping:
    -- Top-left (col 0-1, row 0-2): AUTH
    -- Top-right (col 2-3, row 0-2): VPN
    -- Bottom-left (col 0-1, row 3-5): TORRIFIED
    -- Bottom-right (col 2-3, row 3-5): DNS (DNSCrypt/TorDNS)
    for row = 0, 5 do
        for col = 0, 3 do
            local bx = start_x + col * (block_size + spacing)
            local by = start_y + row * (block_size + spacing)

            -- Determine service based on quadrant
            local service
            if row < 3 then
                service = col < 2 and "auth" or "vpn"
            else
                service = col < 2 and "torrified" or "dns"
            end

            local is_active = status[service] == 1
            -- 2 = unknown (security-status.sh): the readback failed, so draw
            -- a distinct amber block instead of the dim "off" block.
            local is_unknown = status[service] == 2
            local color = color_enabled

            if is_unknown then
                cairo_rectangle(cr, bx, by, block_size, block_size)
                cairo_set_source_rgba(cr, rgb_to_r_g_b(0xF59E0B, 0.45))
                cairo_fill(cr)
            elseif is_active then
                -- Outer glow (BINARY gauge style)
                cairo_rectangle(cr, bx, by, block_size, block_size)
                cairo_set_source_rgba(cr, rgb_to_r_g_b(color, 0.6))
                cairo_fill(cr)
                -- Inner bright core (BINARY gauge style)
                cairo_rectangle(cr, bx + 1, by + 1, block_size - 2, block_size - 2)
                cairo_set_source_rgba(cr, rgb_to_r_g_b(color, 1.0))
                cairo_fill(cr)
            else
                -- Dim inactive (BINARY gauge style)
                cairo_rectangle(cr, bx, by, block_size, block_size)
                cairo_set_source_rgba(cr, rgb_to_r_g_b(0xFFFFFF, 0.12))
                cairo_fill(cr)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Get ping value via gateway wrapper (returns ms)
local function get_gateway_ping_ms()
    local result = gateway_script_value("random-ping.sh", "", nil)
    if not result then
        return 0
    end

    result = result:gsub("%s+", "")
    local ping_ms = tonumber(result)
    if not ping_ms or ping_ms <= 0 then
        return 0
    end
    return ping_ms
end

--------------------------------------------------------------------------------
-- Get random ping gauge percentages from gateway
-- Updates every 10 cycles (~30 seconds with 3s update interval)
local function get_random_ping_values()
    ping_update_counter = ping_update_counter + 1
    -- Update every 10 cycles (about every 30 seconds)
    if ping_update_counter % 10 == 1 then
        local ping_ms = get_gateway_ping_ms()
        local percent = math.min(100, math.max(0, math.floor((ping_ms / 500) * 100)))
        -- Outer and inner rings mirror gateway ping value.
        last_dns_ping = percent
        last_domain_ping = percent
    end
    return last_dns_ping, last_domain_ping
end

--------------------------------------------------------------------------------
-- ONE net-traffic.sh CALL PER DRAW INSTEAD OF THREE.
--
-- get_total_bandwidth_percent, and get_gateway_traffic_kib("up") and ("down"), were three
-- separate gateway invocations on EVERY 3-second draw. Measured on testvm-kodachi-0425b0
-- (live <lab-host> beta) 2026-09-04: one gateway call costs ~322 ms and ~15 forks, so this
-- panel alone was ~80 calls and ~1,088 forks a minute, and /proc cutime+cstime attributed
-- 16.33 CPU-seconds per minute of child work to it. The whole idle image forks 5,180 a
-- minute on 4 vCPUs, with 73.4 CPU-s/min across the four conky panels.
--
-- The refresh rate and the displayed values do not change: net-traffic.sh gauges reads the
-- same three snapshot keys the three separate calls read, in one pass, and falls back to
-- the per-key path whenever the batch cannot be served.
local traffic_batch = {lines = nil}
local traffic_batch_cycle = -1
local draw_cycle = 0

local function refresh_traffic_batch()
    if traffic_batch_cycle == draw_cycle then
        return
    end
    traffic_batch_cycle = draw_cycle
    -- nil on a short or failed read, which leaves the per-field fallbacks in charge.
    traffic_batch.lines = gateway_script_lines("net-traffic.sh", "gauges", 3)
end

local function traffic_batch_value(index)
    -- A caller that cannot be mapped to a batch position (any field other than up/down)
    -- gets nil and falls through to its own per-field gateway call.
    if not index then
        return nil
    end
    refresh_traffic_batch()
    local lines = traffic_batch.lines
    if not lines then
        return nil
    end
    return lines[index]
end

-- Get current traffic value from gateway wrappers (KiB/s).
local function get_gateway_traffic_kib(field)
    -- Batch first (one call serves up, down and totalpercent); per-field call only if the
    -- batch could not be served, so the values are identical on both paths.
    local value = traffic_batch_value(field == "up" and 1 or field == "down" and 2 or nil)
    if not value then
        value = gateway_script_value("net-traffic.sh", field, "0")
    end
    local parsed = tonumber((value or ""):match("[-+]?[0-9]*%.?[0-9]+"))
    if not parsed or parsed < 0 then
        return 0
    end
    return parsed
end

--------------------------------------------------------------------------------
-- Get total bandwidth percentage from gateway wrappers.
local function get_total_bandwidth_percent()
    local value = traffic_batch_value(3)
    if not value then
        value = gateway_script_value("net-traffic.sh", "totalpercent", "0")
    end
    local parsed = tonumber((value or ""):match("[-+]?[0-9]+"))
    if not parsed then
        return 0
    end
    return math.min(100, math.max(0, math.floor(parsed)))
end

-- Get swap percentage from gateway wrapper.
--
-- Cached for 10 draws (~30 s at the 3 s update_interval), the same idiom
-- get_security_status and get_random_ping_values already use in this file. Swap occupancy
-- on a live image moves over minutes, not seconds, so a 3-second gateway call for it was
-- 20 invocations a minute to redraw a number that had not changed. The first draw still
-- reads it, so nothing is blank at startup.
local last_swap_percent = 0
local swap_update_counter = 0
local function get_swap_percent()
    swap_update_counter = swap_update_counter + 1
    if swap_update_counter % 10 ~= 1 then
        return last_swap_percent
    end
    local value = gateway_script_value("system-status.sh", "swapperc", "0")
    local parsed = tonumber((value or ""):match("[-+]?[0-9]+"))
    if not parsed then
        return last_swap_percent
    end
    last_swap_percent = math.min(100, math.max(0, parsed))
    return last_swap_percent
end

--------------------------------------------------------------------------------
--                                                                    gauge DATA
-- Order: UP/DOWN, CPU/MEM, DISK/SWAP, PING/BWIDTH
gauge = {
-- Row 1: Network Upload (orange)
{
    name='upspeedf',               arg=default_iface,           max_value=100,
    gauge_style='ring',
    x=35,                          y=70,
    graph_radius=18,
    graph_thickness=5,
    graph_start_angle=180,
    graph_unit_angle=2.7,          graph_unit_thickness=2.7,
    graph_bg_colour=0xffffff,      graph_bg_alpha=0.10,
    graph_fg_colour=0xFFB347,      graph_fg_alpha=0.4,
    hand_fg_colour=0xFFB347,       hand_fg_alpha=1.0,
    txt_radius=30,
    txt_weight=0,                  txt_size=11.0,
    txt_fg_colour=0xFFB347,        txt_fg_alpha=1.0,
    graduation_radius=22,
    graduation_thickness=0,        graduation_mark_thickness=1,
    graduation_unit_angle=27,
    graduation_fg_colour=0xFFFFFF, graduation_fg_alpha=0.2,
    caption='UP',
    caption_weight=1,              caption_size=10.0,
    caption_fg_colour=0xFFB347,    caption_fg_alpha=0.7,
    is_network=true,
    network_type='upload',
},
-- Row 1: Network Download (pink)
{
    name='downspeedf',             arg=default_iface,           max_value=100,
    gauge_style='ring',
    x=110,                         y=70,
    graph_radius=18,
    graph_thickness=5,
    graph_start_angle=180,
    graph_unit_angle=2.7,          graph_unit_thickness=2.7,
    graph_bg_colour=0xffffff,      graph_bg_alpha=0.10,
    graph_fg_colour=0xEC4899,      graph_fg_alpha=0.4,
    hand_fg_colour=0xEC4899,       hand_fg_alpha=1.0,
    txt_radius=30,
    txt_weight=0,                  txt_size=11.0,
    txt_fg_colour=0xEC4899,        txt_fg_alpha=1.0,
    graduation_radius=22,
    graduation_thickness=0,        graduation_mark_thickness=1,
    graduation_unit_angle=27,
    graduation_fg_colour=0xFFFFFF, graduation_fg_alpha=0.2,
    caption='DOWN',
    caption_weight=1,              caption_size=10.0,
    caption_fg_colour=0xEC4899,    caption_fg_alpha=0.7,
    is_network=true,
    network_type='download',
},
-- Row 2: CPU gauge (cyan)
{
    name='cpu',                    arg='cpu0',                  max_value=100,
    gauge_style='ring',
    x=35,                          y=130,
    graph_radius=18,
    graph_thickness=5,
    graph_start_angle=180,
    graph_unit_angle=2.7,          graph_unit_thickness=2.7,
    graph_bg_colour=0xffffff,      graph_bg_alpha=0.10,
    graph_fg_colour=0x06B6D4,      graph_fg_alpha=0.4,
    hand_fg_colour=0x06B6D4,       hand_fg_alpha=1.0,
    txt_radius=30,
    txt_weight=0,                  txt_size=11.0,
    txt_fg_colour=0x06B6D4,        txt_fg_alpha=1.0,
    graduation_radius=22,
    graduation_thickness=0,        graduation_mark_thickness=1,
    graduation_unit_angle=27,
    graduation_fg_colour=0xFFFFFF, graduation_fg_alpha=0.2,
    caption='CPU',
    caption_weight=1,              caption_size=10.0,
    caption_fg_colour=0x06B6D4,    caption_fg_alpha=0.7,
},
-- Row 2: Memory gauge (green)
{
    name='memperc',                arg='',                      max_value=100,
    gauge_style='ring',
    x=110,                         y=130,
    graph_radius=18,
    graph_thickness=5,
    graph_start_angle=180,
    graph_unit_angle=2.7,          graph_unit_thickness=2.7,
    graph_bg_colour=0xffffff,      graph_bg_alpha=0.10,
    graph_fg_colour=0x8BB158,      graph_fg_alpha=0.4,
    hand_fg_colour=0x8BB158,       hand_fg_alpha=1.0,
    txt_radius=30,
    txt_weight=0,                  txt_size=11.0,
    txt_fg_colour=0x8BB158,        txt_fg_alpha=1.0,
    graduation_radius=22,
    graduation_thickness=0,        graduation_mark_thickness=1,
    graduation_unit_angle=27,
    graduation_fg_colour=0xFFFFFF, graduation_fg_alpha=0.2,
    caption='MEM',
    caption_weight=1,              caption_size=10.0,
    caption_fg_colour=0x8BB158,    caption_fg_alpha=0.7,
},
-- Row 3: Disk gauge (purple)
{
    name='fs_used_perc',           arg='/',                     max_value=100,
    gauge_style='ring',
    x=35,                          y=190,
    graph_radius=18,
    graph_thickness=5,
    graph_start_angle=180,
    graph_unit_angle=2.7,          graph_unit_thickness=2.7,
    graph_bg_colour=0xffffff,      graph_bg_alpha=0.10,
    graph_fg_colour=0xA855F7,      graph_fg_alpha=0.4,
    hand_fg_colour=0xA855F7,       hand_fg_alpha=1.0,
    txt_radius=30,
    txt_weight=0,                  txt_size=11.0,
    txt_fg_colour=0xA855F7,        txt_fg_alpha=1.0,
    graduation_radius=22,
    graduation_thickness=0,        graduation_mark_thickness=1,
    graduation_unit_angle=27,
    graduation_fg_colour=0xFFFFFF, graduation_fg_alpha=0.2,
    caption='DISK',
    caption_weight=1,              caption_size=10.0,
    caption_fg_colour=0xA855F7,    caption_fg_alpha=0.7,
},
-- Row 3: Swap gauge (yellow)
{
    name='swapperc',               arg='',                      max_value=100,
    gauge_style='ring',
    x=110,                         y=190,
    graph_radius=18,
    graph_thickness=5,
    graph_start_angle=180,
    graph_unit_angle=2.7,          graph_unit_thickness=2.7,
    graph_bg_colour=0xffffff,      graph_bg_alpha=0.10,
    graph_fg_colour=0xFFD700,      graph_fg_alpha=0.4,
    hand_fg_colour=0xFFD700,       hand_fg_alpha=1.0,
    txt_radius=30,
    txt_weight=0,                  txt_size=11.0,
    txt_fg_colour=0xFFD700,        txt_fg_alpha=1.0,
    graduation_radius=22,
    graduation_thickness=0,        graduation_mark_thickness=1,
    graduation_unit_angle=27,
    graduation_fg_colour=0xFFFFFF, graduation_fg_alpha=0.2,
    caption='SWAP',
    caption_weight=1,              caption_size=10.0,
    caption_fg_colour=0xFFD700,    caption_fg_alpha=0.7,
    is_swap=true,
},
-- Row 4: Ping gauge (red) - dual ring for DNS and Domain ping
{
    name='ping',                   arg='',                      max_value=100,
    gauge_style='ring',
    x=35,                          y=260,
    graph_radius=18,
    graph_thickness=5,
    graph_start_angle=180,
    graph_unit_angle=2.7,          graph_unit_thickness=2.7,
    graph_bg_colour=0xffffff,      graph_bg_alpha=0.10,
    graph_fg_colour=0xFF6B6B,      graph_fg_alpha=0.4,
    hand_fg_colour=0xFF6B6B,       hand_fg_alpha=1.0,
    -- Inner ring for domain ping
    inner_graph_radius=12,
    inner_graph_fg_colour=0x4ECDC4, inner_graph_fg_alpha=0.4,
    inner_hand_fg_colour=0x4ECDC4, inner_hand_fg_alpha=1.0,
    txt_radius=30,
    txt_weight=0,                  txt_size=11.0,
    txt_fg_colour=0xFF6B6B,        txt_fg_alpha=1.0,
    graduation_radius=22,
    graduation_thickness=0,        graduation_mark_thickness=1,
    graduation_unit_angle=27,
    graduation_fg_colour=0xFFFFFF, graduation_fg_alpha=0.2,
    caption='PING',
    caption_weight=1,              caption_size=10.0,
    caption_fg_colour=0xFF6B6B,    caption_fg_alpha=0.7,
    is_ping=true,
},
-- Row 4: Bandwidth gauge (white)
{
    name='bandwidth',              arg='',                      max_value=100,
    gauge_style='ring',
    x=110,                         y=260,
    graph_radius=18,
    graph_thickness=5,
    graph_start_angle=180,
    graph_unit_angle=2.7,          graph_unit_thickness=2.7,
    graph_bg_colour=0xffffff,      graph_bg_alpha=0.10,
    graph_fg_colour=0xFFFFFF,      graph_fg_alpha=0.4,
    hand_fg_colour=0xFFFFFF,       hand_fg_alpha=1.0,
    txt_radius=30,
    txt_weight=0,                  txt_size=11.0,
    txt_fg_colour=0xFFFFFF,        txt_fg_alpha=1.0,
    graduation_radius=22,
    graduation_thickness=0,        graduation_mark_thickness=1,
    graduation_unit_angle=27,
    graduation_fg_colour=0xFFFFFF, graduation_fg_alpha=0.2,
    caption='BW',
    caption_weight=1,              caption_size=10.0,
    caption_fg_colour=0xFFFFFF,    caption_fg_alpha=0.7,
    is_bandwidth=true,
},
}

-------------------------------------------------------------------------------
--                                                                 rgb_to_r_g_b
function rgb_to_r_g_b(colour, alpha)
    return ((colour / 0x10000) % 0x100) / 255., ((colour / 0x100) % 0x100) / 255., (colour % 0x100) / 255., alpha
end

-------------------------------------------------------------------------------
--                                                          STYLE: BINARY
-- Digital matrix-style gauge with 16 blocks lighting up
function draw_gauge_binary(cr, data, value, inner_value)
    local max_value = data['max_value']
    local x, y = data['x'], data['y']
    local color = data['graph_fg_colour']
    local percent = math.min(math.max(0, value), max_value) / max_value

    local blocks_total = 16
    local blocks_lit = math.floor(blocks_total * percent)
    local block_size = 6
    local spacing = 2
    local grid_size = (block_size + spacing) * 4 - spacing
    local start_x = x - grid_size/2
    local start_y = y - grid_size/2

    local positions = {
        {0,3}, {1,3}, {2,3}, {3,3},
        {3,2}, {3,1}, {3,0},
        {2,0}, {1,0}, {0,0},
        {0,1}, {0,2},
        {1,2}, {2,2}, {1,1}, {2,1}
    }

    for i = 1, blocks_total do
        local pos = positions[i]
        local bx = start_x + pos[1] * (block_size + spacing)
        local by = start_y + pos[2] * (block_size + spacing)

        if i <= blocks_lit then
            cairo_rectangle(cr, bx, by, block_size, block_size)
            cairo_set_source_rgba(cr, rgb_to_r_g_b(color, 0.6))
            cairo_fill(cr)
            cairo_rectangle(cr, bx + 1, by + 1, block_size - 2, block_size - 2)
            cairo_set_source_rgba(cr, rgb_to_r_g_b(color, 1.0))
            cairo_fill(cr)
        else
            cairo_rectangle(cr, bx, by, block_size, block_size)
            cairo_set_source_rgba(cr, rgb_to_r_g_b(0xFFFFFF, 0.12))
            cairo_fill(cr)
        end
    end

    -- Value and caption
    cairo_set_source_rgba(cr, rgb_to_r_g_b(color, 1.0))
    cairo_select_font_face(cr, "DejaVu Sans", CAIRO_FONT_SLANT_NORMAL, 0)
    cairo_set_font_size(cr, 11)
    cairo_move_to(cr, x - 6, y + grid_size/2 + 12)
    cairo_show_text(cr, tostring(math.floor(value)))
    cairo_stroke(cr)

    cairo_set_font_size(cr, 10)
    cairo_set_source_rgba(cr, rgb_to_r_g_b(color, 0.7))
    cairo_move_to(cr, x - 8, y + grid_size/2 + 22)
    cairo_show_text(cr, data['caption'])
    cairo_stroke(cr)
end

-------------------------------------------------------------------------------
--                                                          STYLE: HEXAGON
-- Honeycomb gauge with 6 segments lighting up clockwise
function draw_gauge_hexagon(cr, data, value, inner_value)
    local max_value = data['max_value']
    local x, y = data['x'], data['y']
    local radius = data['graph_radius']
    local color = data['graph_fg_colour']
    local percent = math.min(math.max(0, value), max_value) / max_value

    local segments_lit = math.floor(6 * percent)
    local seg_radius = radius * 0.38
    local seg_distance = radius * 0.62

    local function hex_shape(cx, cy, r, filled)
        cairo_new_path(cr)
        for i = 0, 5 do
            local angle = (i * math.pi / 3) - math.pi / 6
            local hx = cx + r * math.cos(angle)
            local hy = cy + r * math.sin(angle)
            if i == 0 then
                cairo_move_to(cr, hx, hy)
            else
                cairo_line_to(cr, hx, hy)
            end
        end
        cairo_close_path(cr)
        if filled then
            cairo_fill(cr)
        else
            cairo_set_line_width(cr, 2)
            cairo_stroke(cr)
        end
    end

    -- Main hexagon outline
    cairo_set_source_rgba(cr, rgb_to_r_g_b(0xFFFFFF, 0.1))
    hex_shape(x, y, radius, false)

    -- 6 segment hexagons
    for i = 0, 5 do
        local angle = (i * math.pi / 3)
        local sx = x + seg_distance * math.cos(angle)
        local sy = y + seg_distance * math.sin(angle)

        if i < segments_lit then
            cairo_set_source_rgba(cr, rgb_to_r_g_b(color, 0.5))
            hex_shape(sx, sy, seg_radius, true)
            cairo_set_source_rgba(cr, rgb_to_r_g_b(color, 1.0))
            hex_shape(sx, sy, seg_radius, false)
        else
            cairo_set_source_rgba(cr, rgb_to_r_g_b(0xFFFFFF, 0.12))
            hex_shape(sx, sy, seg_radius, false)
        end
    end

    -- Center glow based on value
    if percent > 0 then
        cairo_set_source_rgba(cr, rgb_to_r_g_b(color, 0.4 * percent))
        hex_shape(x, y, seg_radius * 0.7, true)
    end

    -- Value text in center
    cairo_set_source_rgba(cr, rgb_to_r_g_b(color, 1.0))
    cairo_select_font_face(cr, "DejaVu Sans", CAIRO_FONT_SLANT_NORMAL, 0)
    cairo_set_font_size(cr, 11)
    cairo_move_to(cr, x - 6, y + 3)
    cairo_show_text(cr, tostring(math.floor(value)))
    cairo_stroke(cr)

    -- Caption below
    cairo_set_font_size(cr, 10)
    cairo_set_source_rgba(cr, rgb_to_r_g_b(color, 0.7))
    cairo_move_to(cr, x - 10, y + radius + 12)
    cairo_show_text(cr, data['caption'])
    cairo_stroke(cr)
end

-------------------------------------------------------------------------------
--                                                            angle_to_position
function angle_to_position(start_angle, current_angle)
    local pos = current_angle + start_angle
    return ( ( pos * (2 * math.pi / 360) ) - (math.pi / 2) )
end

-------------------------------------------------------------------------------
--                                                              draw_gauge_ring
function draw_gauge_ring(cr, data, value, inner_value)
    local max_value = data['max_value']
    local x, y = data['x'], data['y']
    local graph_radius = data['graph_radius']
    local graph_thickness, graph_unit_thickness = data['graph_thickness'], data['graph_unit_thickness']
    local graph_start_angle = data['graph_start_angle']
    local graph_unit_angle = data['graph_unit_angle']
    local graph_bg_colour, graph_bg_alpha = data['graph_bg_colour'], data['graph_bg_alpha']
    local graph_fg_colour, graph_fg_alpha = data['graph_fg_colour'], data['graph_fg_alpha']
    local hand_fg_colour, hand_fg_alpha = data['hand_fg_colour'], data['hand_fg_alpha']
    local graph_end_angle = (max_value * graph_unit_angle) % 360

    -- background ring
    cairo_arc(cr, x, y, graph_radius, angle_to_position(graph_start_angle, 0), angle_to_position(graph_start_angle, graph_end_angle))
    cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_bg_colour, graph_bg_alpha))
    cairo_set_line_width(cr, graph_thickness)
    cairo_stroke(cr)

    -- FIXED: Use math.min for clamping instead of modulo wrapping
    local val = math.min(math.max(0, value), max_value)
    local start_arc = 0
    local stop_arc = 0
    local i = 1
    while i <= val do
        start_arc = (graph_unit_angle * i) - graph_unit_thickness
        stop_arc = (graph_unit_angle * i)
        cairo_arc(cr, x, y, graph_radius, angle_to_position(graph_start_angle, start_arc), angle_to_position(graph_start_angle, stop_arc))
        cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_fg_colour, graph_fg_alpha))
        cairo_stroke(cr)
        i = i + 1
    end
    local angle = start_arc

    -- hand
    start_arc = (graph_unit_angle * val) - (graph_unit_thickness * 2)
    stop_arc = (graph_unit_angle * val)
    cairo_arc(cr, x, y, graph_radius, angle_to_position(graph_start_angle, start_arc), angle_to_position(graph_start_angle, stop_arc))
    cairo_set_source_rgba(cr, rgb_to_r_g_b(hand_fg_colour, hand_fg_alpha))
    cairo_stroke(cr)

    -- Draw inner ring if this is a ping gauge with inner value
    if inner_value and data['inner_graph_radius'] then
        local inner_radius = data['inner_graph_radius']
        local inner_fg_colour = data['inner_graph_fg_colour']
        local inner_fg_alpha = data['inner_graph_fg_alpha']
        local inner_hand_colour = data['inner_hand_fg_colour']
        local inner_hand_alpha = data['inner_hand_fg_alpha']

        -- Inner background ring
        cairo_arc(cr, x, y, inner_radius, angle_to_position(graph_start_angle, 0), angle_to_position(graph_start_angle, graph_end_angle))
        cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_bg_colour, graph_bg_alpha * 0.5))
        cairo_set_line_width(cr, 3)
        cairo_stroke(cr)

        -- FIXED: Use math.min for clamping instead of modulo wrapping
        local inner_val = math.min(math.max(0, inner_value), max_value)
        i = 1
        while i <= inner_val do
            start_arc = (graph_unit_angle * i) - graph_unit_thickness
            stop_arc = (graph_unit_angle * i)
            cairo_arc(cr, x, y, inner_radius, angle_to_position(graph_start_angle, start_arc), angle_to_position(graph_start_angle, stop_arc))
            cairo_set_source_rgba(cr, rgb_to_r_g_b(inner_fg_colour, inner_fg_alpha))
            cairo_set_line_width(cr, 3)
            cairo_stroke(cr)
            i = i + 1
        end

        -- Inner hand
        start_arc = (graph_unit_angle * inner_val) - (graph_unit_thickness * 2)
        stop_arc = (graph_unit_angle * inner_val)
        cairo_arc(cr, x, y, inner_radius, angle_to_position(graph_start_angle, start_arc), angle_to_position(graph_start_angle, stop_arc))
        cairo_set_source_rgba(cr, rgb_to_r_g_b(inner_hand_colour, inner_hand_alpha))
        cairo_stroke(cr)
    end

    -- text
    local txt_radius = data['txt_radius']
    local txt_weight, txt_size = data['txt_weight'], data['txt_size']
    local txt_fg_colour, txt_fg_alpha = data['txt_fg_colour'], data['txt_fg_alpha']
    local movex = txt_radius * math.cos(angle_to_position(graph_start_angle, angle))
    local movey = txt_radius * math.sin(angle_to_position(graph_start_angle, angle))

    -- CLAMP THE VERTICAL REACH SO A LABEL CANNOT LAND ON THE RING BELOW OR ABOVE.
    --
    -- The value is drawn at the END OF ITS ARC, so a LOW value on one ring sits at
    -- the bottom of it and a MID value on the next sits at the top of that one, and
    -- with this layout the two land in exactly the same place:
    --     ring rows are at y = 70, 130, 190, 260   (gaps 60, 60, 70)
    --     txt_radius = 30
    --     upper label max y = 70 + 30 = 100
    --     lower label min y = 130 - 30 = 100       COINCIDENT
    -- Measured on screen by <agent> at 3440x1440 with ORDINARY idle values:
    -- UP=9 (orange) overlapping CPU=55 (cyan), and DOWN=1 touching MEM=57. Any time a
    -- network gauge is low and CPU or MEM is mid-range, which is most of the time,
    -- that spot is unreadable.
    --
    -- The clamp keeps the horizontal arc-following behaviour (movex is untouched, so
    -- the label still tracks the needle left to right) and only limits how far it can
    -- travel vertically. With the smallest row gap at 60 and txt_size 11, the label
    -- half-height is ~5.5, so anything under 60/2 - 5.5 = 24.5 is safe; 22 leaves a
    -- 2.5px margin and still sits outside graduation_radius=22 horizontally.
    -- Overridable per gauge for layouts with different spacing.
    local txt_max_dy = data['txt_max_dy'] or 22
    if movey > txt_max_dy then
        movey = txt_max_dy
    elseif movey < -txt_max_dy then
        movey = -txt_max_dy
    end
    cairo_select_font_face(cr, "DejaVu Sans", CAIRO_FONT_SLANT_NORMAL, txt_weight)
    cairo_set_font_size(cr, txt_size)
    cairo_set_source_rgba(cr, rgb_to_r_g_b(txt_fg_colour, txt_fg_alpha))
    cairo_move_to(cr, x + movex - (txt_size / 2), y + movey + 3)
    cairo_show_text(cr, value)
    cairo_stroke(cr)

    -- caption
    local caption = data['caption']
    local caption_weight, caption_size = data['caption_weight'], data['caption_size']
    local caption_fg_colour, caption_fg_alpha = data['caption_fg_colour'], data['caption_fg_alpha']
    local tox = graph_radius * (math.cos((graph_start_angle * 2 * math.pi / 360) - (math.pi / 2)))
    local toy = graph_radius * (math.sin((graph_start_angle * 2 * math.pi / 360) - (math.pi / 2)))
    cairo_select_font_face(cr, "DejaVu Sans", CAIRO_FONT_SLANT_NORMAL, caption_weight)
    cairo_set_font_size(cr, caption_size)
    cairo_set_source_rgba(cr, rgb_to_r_g_b(caption_fg_colour, caption_fg_alpha))
    cairo_move_to(cr, x + tox + 5, y + toy + 1)
    if graph_start_angle < 105 then
        cairo_move_to(cr, x + tox - 35, y + toy + 1)
    end
    cairo_show_text(cr, caption)
    cairo_stroke(cr)
end

-------------------------------------------------------------------------------
--                                                               go_gauge_rings
function go_gauge_rings(cr)
    local function load_gauge_rings(cr, data)
        local str, value = '', 0
        local inner_value = nil

        if data['is_ping'] then
            -- Ping gauge with dual indicators
            local dns_ping, domain_ping = get_random_ping_values()
            value = dns_ping
            inner_value = domain_ping
        elseif data['is_bandwidth'] then
            value = get_total_bandwidth_percent()
        elseif data['is_swap'] then
            value = get_swap_percent()
        elseif data['is_network'] then
            local raw_value = 0
            if data['network_type'] == 'upload' then
                raw_value = get_gateway_traffic_kib("up")
            elseif data['network_type'] == 'download' then
                raw_value = get_gateway_traffic_kib("down")
            end

            if data['network_type'] == 'upload' then
                if raw_value > max_upload_speed then
                    max_upload_speed = raw_value
                end
                value = math.min(100, math.max(0, math.floor((raw_value / max_upload_speed) * 100)))
            elseif data['network_type'] == 'download' then
                if raw_value > max_download_speed then
                    max_download_speed = raw_value
                end
                value = math.min(100, math.max(0, math.floor((raw_value / max_download_speed) * 100)))
            end
        else
            str = string.format('${%s %s}', data['name'], data['arg'])
            str = conky_parse(str)
            value = tonumber(str) or 0
        end

        -- Select gauge style
        local style = data['gauge_style'] or 'ring'
        if style == 'binary' then
            draw_gauge_binary(cr, data, value, inner_value)
        elseif style == 'hexagon' then
            draw_gauge_hexagon(cr, data, value, inner_value)
        else
            draw_gauge_ring(cr, data, value, inner_value)
        end
    end

    for i in pairs(gauge) do
        load_gauge_rings(cr, gauge[i])
    end
end

-------------------------------------------------------------------------------
--                                                                         MAIN
-- Wrapped in pcall for error handling - prevents Conky crashes
function conky_main()
    if conky_window == nil then
        return
    end

    -- ADVANCE THE DRAW CYCLE FIRST. refresh_traffic_batch() re-reads only when this number
    -- has moved, so without this line the batch would be fetched once at startup and the
    -- traffic gauges would sit frozen on their first reading forever, which is worse than
    -- the cost the batch exists to remove.
    draw_cycle = draw_cycle + 1

    local cs = nil
    local cr = nil

    -- Use pcall to catch any errors and prevent Conky from crashing
    local success, err = pcall(function()
        cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable, conky_window.visual, conky_window.width, conky_window.height)
        if not cs then
            return
        end

        cr = cairo_create(cs)
        if not cr then
            cairo_surface_destroy(cs)
            return
        end

        local updates = conky_parse('${updates}')
        if not updates then
            return
        end

        local update_num = tonumber(updates)
        if not update_num or update_num < 0 then
            return
        end

        if update_num > 5 then
            draw_security_binary(cr)
            go_gauge_rings(cr)
        end
    end)

    -- Always cleanup Cairo resources
    if cr then
        cairo_destroy(cr)
    end
    if cs then
        cairo_surface_destroy(cs)
    end

    -- Log errors (optional - uncomment for debugging)
    -- if not success then
    --     print("[conky-gauges] Error: " .. tostring(err))
    -- end
end
