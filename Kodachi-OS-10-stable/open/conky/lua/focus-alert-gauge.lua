--==============================================================================
-- focus-alert-gauge.lua
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
-- Description:
-- Cairo circular gauge for the top-center Focus Alert panel.
-- It visualizes changed monitored items / total monitored items.
--==============================================================================

require 'cairo'
-- Optional: older conky (e.g. Ubuntu 22.04's 1.12.2) lacks the split-out
-- cairo_xlib module; a hard require aborts the gauge script there. The needed
-- cairo_xlib_surface_create is still a global from require 'cairo', so guard it.
pcall(function() require 'cairo_xlib' end)

local HOME = os.getenv("HOME") or ""
local STATE_FILE = HOME .. "/.config/kodachi/conky/data/.focus-alert-state"
local RENDER_CACHE = HOME .. "/.config/kodachi/conky/data/.focus-alert-render-cache"
local CHANGE_HISTORY_FILE = HOME .. "/.config/kodachi/conky/data/.focus-alert-change-history"
local MONITORED_TOTAL = 0
local CHANGE_WINDOW_SECONDS = tonumber(os.getenv("FOCUS_ALERT_CHANGE_WINDOW")) or 300
local ALWAYS_VISIBLE = tonumber(os.getenv("FOCUS_ALERT_ALWAYS_VISIBLE")) or 1
local COLOR_SAFE = 0x8BB158
local COLOR_WARN = 0xFFD93D
local COLOR_DANGER = 0xFF6B6B

if CHANGE_WINDOW_SECONDS < 60 then
    CHANGE_WINDOW_SECONDS = 60
end

local WINDOW_LABEL
if CHANGE_WINDOW_SECONDS % 60 == 0 then
    WINDOW_LABEL = tostring(math.floor(CHANGE_WINDOW_SECONDS / 60)) .. "M"
else
    WINDOW_LABEL = tostring(CHANGE_WINDOW_SECONDS) .. "S"
end

local MONITORED_KEYS = {
    "ip",
    "country",
    "mac",
    "hostname",
    "vpn",
    "protocol",
    "dnscrypt",
    "firewall",
    "auth_status",
    "timezone"
}
local MONITORED_SET = {}
for _, key in ipairs(MONITORED_KEYS) do
    MONITORED_SET[key] = true
end
MONITORED_TOTAL = #MONITORED_KEYS

local function rgb_to_r_g_b(colour, alpha)
    return ((colour / 0x10000) % 0x100) / 255.0, ((colour / 0x100) % 0x100) / 255.0, (colour % 0x100) / 255.0, alpha
end

local function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function blend_colour(c1, c2, t)
    t = clamp(t, 0.0, 1.0)

    local r1 = math.floor((c1 / 0x10000) % 0x100)
    local g1 = math.floor((c1 / 0x100) % 0x100)
    local b1 = math.floor(c1 % 0x100)
    local r2 = math.floor((c2 / 0x10000) % 0x100)
    local g2 = math.floor((c2 / 0x100) % 0x100)
    local b2 = math.floor(c2 % 0x100)

    local r = math.floor(r1 + ((r2 - r1) * t) + 0.5)
    local g = math.floor(g1 + ((g2 - g1) * t) + 0.5)
    local b = math.floor(b1 + ((b2 - b1) * t) + 0.5)

    return (r * 0x10000) + (g * 0x100) + b
end

-- Progress palette:
-- safe -> warning -> danger.
-- danger_when_high=true  : higher percent is riskier (monitor changed ratio).
-- danger_when_high=false : lower percent is riskier (countdown remaining).
local function progress_colour(percent, danger_when_high)
    percent = clamp(percent or 0, 0, 100)
    local risk = percent
    if not danger_when_high then
        risk = 100 - percent
    end

    if risk <= 50 then
        return blend_colour(COLOR_SAFE, COLOR_WARN, risk / 50.0)
    end
    return blend_colour(COLOR_WARN, COLOR_DANGER, (risk - 50) / 50.0)
end

local function trim(s)
    if not s then
        return ""
    end
    return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function render_cache_exists()
    local f = io.open(RENDER_CACHE, "r")
    if not f then
        return false
    end
    local size = f:seek("end")
    f:close()
    return size and size > 0
end

local function read_state()
    local state = {
        visible_until = 0
    }

    local handle = io.open(STATE_FILE, "r")
    if not handle then
        return state
    end

    for line in handle:lines() do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key == "visible_until" then
            state.visible_until = tonumber(value) or 0
        end
    end

    handle:close()
    return state
end

local function count_recent_unique_changes(now_ts)
    local seen = {}
    local changed_count = 0
    local handle = io.open(CHANGE_HISTORY_FILE, "r")

    if not handle then
        return 0
    end

    for line in handle:lines() do
        local ts_str, key = line:match("^(%d+)|([^|]+)|")
        if ts_str and key and MONITORED_SET[key] then
            local ts = tonumber(ts_str) or 0
            local age = now_ts - ts
            if age >= 0 and age <= CHANGE_WINDOW_SECONDS then
                seen[key] = true
            end
        end
    end
    handle:close()

    for _ in pairs(seen) do
        changed_count = changed_count + 1
    end
    return changed_count
end

local function angle_to_position(start_angle, current_angle)
    local pos = current_angle + start_angle
    return ((pos * (2 * math.pi / 360.0)) - (math.pi / 2))
end

local function draw_monitor_ring(cr, x, y, percent, changed_count)
    local max_value = 100
    local graph_radius = 18
    local graph_thickness = 5
    local graph_unit_angle = 2.7
    local graph_unit_thickness = 2.7
    local graph_start_angle = 180
    local graph_end_angle = (max_value * graph_unit_angle) % 360

    local gauge_colour = progress_colour(percent, true)

    cairo_arc(
        cr,
        x,
        y,
        graph_radius,
        angle_to_position(graph_start_angle, 0),
        angle_to_position(graph_start_angle, graph_end_angle)
    )
    cairo_set_source_rgba(cr, rgb_to_r_g_b(0xFFFFFF, 0.10))
    cairo_set_line_width(cr, graph_thickness)
    cairo_stroke(cr)

    local value = math.min(math.max(0, percent), max_value)
    local start_arc = 0
    local stop_arc = 0
    local i = 1
    while i <= value do
        start_arc = (graph_unit_angle * i) - graph_unit_thickness
        stop_arc = graph_unit_angle * i
        cairo_arc(
            cr,
            x,
            y,
            graph_radius,
            angle_to_position(graph_start_angle, start_arc),
            angle_to_position(graph_start_angle, stop_arc)
        )
        cairo_set_source_rgba(cr, rgb_to_r_g_b(gauge_colour, 0.45))
        cairo_set_line_width(cr, graph_thickness)
        cairo_stroke(cr)
        i = i + 1
    end

    start_arc = (graph_unit_angle * value) - (graph_unit_thickness * 2)
    stop_arc = graph_unit_angle * value
    cairo_arc(
        cr,
        x,
        y,
        graph_radius,
        angle_to_position(graph_start_angle, start_arc),
        angle_to_position(graph_start_angle, stop_arc)
    )
    cairo_set_source_rgba(cr, rgb_to_r_g_b(gauge_colour, 1.0))
    cairo_set_line_width(cr, graph_thickness)
    cairo_stroke(cr)

    local center_text = tostring(changed_count) .. "/" .. tostring(MONITORED_TOTAL)
    cairo_select_font_face(cr, "DejaVu Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    cairo_set_font_size(cr, 7.0)
    cairo_set_source_rgba(cr, rgb_to_r_g_b(gauge_colour, 1.0))
    local text_shift = (#center_text * 2.2) + 2.0
    cairo_move_to(cr, x - text_shift, y + 3)
    cairo_show_text(cr, center_text)
    cairo_stroke(cr)

    cairo_select_font_face(cr, "DejaVu Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, 6.2)
    cairo_set_source_rgba(cr, rgb_to_r_g_b(gauge_colour, 0.78))
    cairo_move_to(cr, x - 9, y + 27)
    cairo_show_text(cr, WINDOW_LABEL)
    cairo_stroke(cr)
end

function conky_focus_alert_gauge()
    if conky_window == nil then
        return
    end

    local cs = nil
    local cr = nil

    local ok = pcall(function()
        local updates = tonumber(conky_parse('${updates}')) or 0
        if updates < 3 then
            return
        end

        cs = cairo_xlib_surface_create(
            conky_window.display,
            conky_window.drawable,
            conky_window.visual,
            conky_window.width,
            conky_window.height
        )
        if not cs then
            return
        end

        cr = cairo_create(cs)
        if not cr then
            return
        end

        local state = read_state()
        local now = os.time()

        -- Don't draw gauges unless the shell render is also active.
        if not render_cache_exists() then
            return
        end

        local changed = count_recent_unique_changes(now)
        if changed < 0 then
            changed = 0
        end
        if changed > MONITORED_TOTAL then
            changed = MONITORED_TOTAL
        end

        local percent = 0
        if MONITORED_TOTAL > 0 then
            percent = math.floor((changed * 100) / MONITORED_TOTAL)
        end

        -- Legacy behavior: hide rings only when alert window is inactive.
        if ALWAYS_VISIBLE ~= 1 and now > (state.visible_until or 0) then
            return
        end

        -- Align the gauge with the Value column start (goto 430).
        draw_monitor_ring(cr, 430, 44, percent, changed)
    end)

    if cr then
        cairo_destroy(cr)
    end
    if cs then
        cairo_surface_destroy(cs)
    end

    if not ok then
        return
    end
end
