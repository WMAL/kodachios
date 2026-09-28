--==============================================================================
-- Gauge Styles - Alternative gauge visualizations for Kodachi Conky
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
-- 6 Alternative Gauge Styles for Kodachi Conky. Each provides a unique
-- visualization alternative to circular gauges. Functions accept the
-- same parameters: (cr, data, value, inner_value)
--==============================================================================

require 'cairo'

-------------------------------------------------------------------------------
--                                                            STYLE 1: SQUARE
--  Rectangular progress bar with rounded corners and glowing effect
--  Fills from bottom to top with gradient-like appearance
-------------------------------------------------------------------------------
function draw_gauge_square(cr, data, value, inner_value)
    local max_value = data['max_value']
    local x, y = data['x'], data['y']
    local size = data['graph_radius'] * 2.2  -- Square size based on radius
    local thickness = data['graph_thickness']

    -- Clamp value to valid range
    local val = math.min(math.max(0, value), max_value)
    local percent = val / max_value

    local graph_bg_colour = data['graph_bg_colour']
    local graph_bg_alpha = data['graph_bg_alpha']
    local graph_fg_colour = data['graph_fg_colour']
    local graph_fg_alpha = data['graph_fg_alpha']

    -- Background square (rounded corners)
    cairo_new_path(cr)
    local corner_radius = 3
    local sx, sy = x - size/2, y - size/2

    cairo_move_to(cr, sx + corner_radius, sy)
    cairo_line_to(cr, sx + size - corner_radius, sy)
    cairo_arc(cr, sx + size - corner_radius, sy + corner_radius, corner_radius, -math.pi/2, 0)
    cairo_line_to(cr, sx + size, sy + size - corner_radius)
    cairo_arc(cr, sx + size - corner_radius, sy + size - corner_radius, corner_radius, 0, math.pi/2)
    cairo_line_to(cr, sx + corner_radius, sy + size)
    cairo_arc(cr, sx + corner_radius, sy + size - corner_radius, corner_radius, math.pi/2, math.pi)
    cairo_line_to(cr, sx, sy + corner_radius)
    cairo_arc(cr, sx + corner_radius, sy + corner_radius, corner_radius, math.pi, 3*math.pi/2)
    cairo_close_path(cr)

    cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_bg_colour, graph_bg_alpha))
    cairo_set_line_width(cr, thickness)
    cairo_stroke(cr)

    -- Filled portion (bottom to top)
    if percent > 0 then
        local fill_height = size * percent
        cairo_rectangle(cr, sx + 2, sy + size - fill_height, size - 4, fill_height - 2)
        cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_fg_colour, graph_fg_alpha))
        cairo_fill(cr)

        -- Bright top edge
        cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_fg_colour, 1.0))
        cairo_set_line_width(cr, 2)
        cairo_move_to(cr, sx + 2, sy + size - fill_height)
        cairo_line_to(cr, sx + size - 2, sy + size - fill_height)
        cairo_stroke(cr)
    end

    -- Inner value indicator (if exists)
    if inner_value and inner_value > 0 then
        local inner_val = math.min(math.max(0, inner_value), max_value)
        local inner_percent = inner_val / max_value
        local inner_colour = data['inner_graph_fg_colour'] or 0x4ECDC4
        local inner_height = size * inner_percent

        cairo_rectangle(cr, sx + size/2 - 2, sy + size - inner_height, 4, inner_height - 2)
        cairo_set_source_rgba(cr, rgb_to_r_g_b(inner_colour, 0.6))
        cairo_fill(cr)
    end

    -- Caption and value text
    draw_gauge_text(cr, data, value, x, y + size/2 + 8)
end

-------------------------------------------------------------------------------
--                                                         STYLE 2: TRIANGLE
--  Triangular gauge filling from bottom apex to top
--  Creates pyramid effect with gradient shading
-------------------------------------------------------------------------------
function draw_gauge_triangle(cr, data, value, inner_value)
    local max_value = data['max_value']
    local x, y = data['x'], data['y']
    local size = data['graph_radius'] * 2.4
    local val = math.min(math.max(0, value), max_value)
    local percent = val / max_value

    local graph_bg_colour = data['graph_bg_colour']
    local graph_bg_alpha = data['graph_bg_alpha']
    local graph_fg_colour = data['graph_fg_colour']
    local graph_fg_alpha = data['graph_fg_alpha']

    -- Triangle points (pointing up)
    local top_x, top_y = x, y - size/2
    local left_x, left_y = x - size/2, y + size/2
    local right_x, right_y = x + size/2, y + size/2

    -- Background triangle outline
    cairo_move_to(cr, top_x, top_y)
    cairo_line_to(cr, right_x, right_y)
    cairo_line_to(cr, left_x, left_y)
    cairo_close_path(cr)
    cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_bg_colour, graph_bg_alpha))
    cairo_set_line_width(cr, data['graph_thickness'])
    cairo_stroke(cr)

    -- Filled portion (bottom to percentage height)
    if percent > 0 then
        local fill_y = left_y - (size * percent)
        local fill_width = (size/2) * (1 - percent)

        cairo_move_to(cr, x - fill_width, fill_y)
        cairo_line_to(cr, x + fill_width, fill_y)
        cairo_line_to(cr, right_x, right_y)
        cairo_line_to(cr, left_x, left_y)
        cairo_close_path(cr)
        cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_fg_colour, graph_fg_alpha))
        cairo_fill(cr)

        -- Bright fill line
        cairo_move_to(cr, x - fill_width, fill_y)
        cairo_line_to(cr, x + fill_width, fill_y)
        cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_fg_colour, 1.0))
        cairo_set_line_width(cr, 2)
        cairo_stroke(cr)
    end

    -- Inner triangle indicator
    if inner_value and inner_value > 0 then
        local inner_val = math.min(math.max(0, inner_value), max_value)
        local inner_percent = inner_val / max_value
        local inner_colour = data['inner_graph_fg_colour'] or 0x4ECDC4
        local inner_size = size * 0.6

        local inner_top_y = y - inner_size/2
        local inner_bottom_y = y + inner_size/2
        local inner_fill_y = inner_bottom_y - (inner_size * inner_percent)
        local inner_fill_width = (inner_size/2) * (1 - inner_percent) * 0.6

        cairo_move_to(cr, x - inner_fill_width, inner_fill_y)
        cairo_line_to(cr, x + inner_fill_width, inner_fill_y)
        cairo_line_to(cr, x + inner_size/3, inner_bottom_y)
        cairo_line_to(cr, x - inner_size/3, inner_bottom_y)
        cairo_close_path(cr)
        cairo_set_source_rgba(cr, rgb_to_r_g_b(inner_colour, 0.5))
        cairo_fill(cr)
    end

    draw_gauge_text(cr, data, value, x, y + size/2 + 8)
end

-------------------------------------------------------------------------------
--                                                          STYLE 3: BINARY
--  Binary/digital representation using dots or blocks
--  Creates matrix-like effect with lit segments
-------------------------------------------------------------------------------
function draw_gauge_binary(cr, data, value, inner_value)
    local max_value = data['max_value']
    local x, y = data['x'], data['y']
    local radius = data['graph_radius']
    local val = math.min(math.max(0, value), max_value)
    local percent = val / max_value

    local graph_bg_colour = data['graph_bg_colour']
    local graph_bg_alpha = data['graph_bg_alpha']
    local graph_fg_colour = data['graph_fg_colour']
    local graph_fg_alpha = data['graph_fg_alpha']

    -- 16 binary blocks arranged in 4x4 grid
    local blocks_total = 16
    local blocks_lit = math.floor(blocks_total * percent)
    local block_size = 6
    local spacing = 2
    local grid_size = (block_size + spacing) * 4 - spacing
    local start_x = x - grid_size/2
    local start_y = y - grid_size/2

    -- Draw blocks from bottom-left, spiraling up
    local positions = {
        {0,3}, {1,3}, {2,3}, {3,3},  -- Bottom row
        {3,2}, {3,1}, {3,0},          -- Right column
        {2,0}, {1,0}, {0,0},          -- Top row
        {0,1}, {0,2},                 -- Left column
        {1,2}, {2,2}, {1,1}, {2,1}   -- Inner blocks
    }

    for i = 1, blocks_total do
        local pos = positions[i]
        local bx = start_x + pos[1] * (block_size + spacing)
        local by = start_y + pos[2] * (block_size + spacing)

        if i <= blocks_lit then
            -- Lit block
            cairo_rectangle(cr, bx, by, block_size, block_size)
            cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_fg_colour, graph_fg_alpha + 0.4))
            cairo_fill(cr)

            -- Bright core
            cairo_rectangle(cr, bx + 1, by + 1, block_size - 2, block_size - 2)
            cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_fg_colour, 1.0))
            cairo_fill(cr)
        else
            -- Unlit block
            cairo_rectangle(cr, bx, by, block_size, block_size)
            cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_bg_colour, graph_bg_alpha * 2))
            cairo_fill(cr)
        end
    end

    -- Inner value indicator (center dot pattern)
    if inner_value and inner_value > 0 then
        local inner_val = math.min(math.max(0, inner_value), max_value)
        local inner_percent = inner_val / max_value
        local inner_colour = data['inner_graph_fg_colour'] or 0x4ECDC4
        local inner_blocks = math.floor(4 * inner_percent)

        local inner_positions = {{1.5,1.5}, {2.5,1.5}, {1.5,2.5}, {2.5,2.5}}
        for i = 1, math.min(inner_blocks, 4) do
            local pos = inner_positions[i]
            local bx = start_x + pos[1] * (block_size + spacing) - block_size/2
            local by = start_y + pos[2] * (block_size + spacing) - block_size/2
            cairo_arc(cr, bx + block_size/2, by + block_size/2, 2, 0, 2*math.pi)
            cairo_set_source_rgba(cr, rgb_to_r_g_b(inner_colour, 0.8))
            cairo_fill(cr)
        end
    end

    draw_gauge_text(cr, data, value, x, y + grid_size/2 + 8)
end

-------------------------------------------------------------------------------
--                                                            STYLE 4: WAVE
--  Liquid wave gauge with sine wave animation effect
--  Creates fluid-fill appearance with wave at top
-------------------------------------------------------------------------------
function draw_gauge_wave(cr, data, value, inner_value)
    local max_value = data['max_value']
    local x, y = data['x'], data['y']
    local radius = data['graph_radius']
    local val = math.min(math.max(0, value), max_value)
    local percent = val / max_value

    local graph_bg_colour = data['graph_bg_colour']
    local graph_bg_alpha = data['graph_bg_alpha']
    local graph_fg_colour = data['graph_fg_colour']
    local graph_fg_alpha = data['graph_fg_alpha']

    -- Container circle
    cairo_arc(cr, x, y, radius, 0, 2*math.pi)
    cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_bg_colour, graph_bg_alpha))
    cairo_set_line_width(cr, data['graph_thickness'])
    cairo_stroke(cr)

    -- Calculate wave fill level
    if percent > 0 then
        local fill_y = y + radius - (2 * radius * percent)
        local wave_amplitude = 3
        local wave_frequency = 2
        local updates = tonumber(conky_parse('${updates}')) or 0
        local phase = (updates * 0.3) % (2 * math.pi)

        -- Create wave path
        cairo_move_to(cr, x - radius, fill_y)

        -- Draw sine wave across the top
        for i = 0, 40 do
            local wx = x - radius + (i * 2 * radius / 40)
            local wave_offset = wave_amplitude * math.sin(wave_frequency * (i / 40) * 2 * math.pi + phase)
            local wy = fill_y + wave_offset
            cairo_line_to(cr, wx, wy)
        end

        -- Close path at bottom
        cairo_line_to(cr, x + radius, y + radius)
        cairo_line_to(cr, x - radius, y + radius)
        cairo_close_path(cr)

        -- Clip to circle
        cairo_save(cr)
        cairo_arc(cr, x, y, radius - 2, 0, 2*math.pi)
        cairo_clip(cr)

        -- Fill wave
        cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_fg_colour, graph_fg_alpha))
        cairo_fill_preserve(cr)

        -- Brighter wave edge
        cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_fg_colour, 1.0))
        cairo_set_line_width(cr, 2)
        cairo_stroke(cr)

        cairo_restore(cr)
    end

    -- Inner wave indicator (smaller inner circle)
    if inner_value and inner_value > 0 then
        local inner_val = math.min(math.max(0, inner_value), max_value)
        local inner_percent = inner_val / max_value
        local inner_colour = data['inner_graph_fg_colour'] or 0x4ECDC4
        local inner_radius = radius * 0.6
        local inner_fill_y = y + inner_radius - (2 * inner_radius * inner_percent)

        cairo_arc(cr, x, y, inner_radius, 0, 2*math.pi)
        cairo_clip(cr)
        cairo_rectangle(cr, x - inner_radius, inner_fill_y, 2*inner_radius, 2*inner_radius)
        cairo_set_source_rgba(cr, rgb_to_r_g_b(inner_colour, 0.4))
        cairo_fill(cr)
    end

    draw_gauge_text(cr, data, value, x, y + radius + 8)
end

-------------------------------------------------------------------------------
--                                                         STYLE 5: HEXAGON
--  Hexagonal honeycomb gauge filling by segments
--  Creates geometric pattern with hex cells lighting up
-------------------------------------------------------------------------------
function draw_gauge_hexagon(cr, data, value, inner_value)
    local max_value = data['max_value']
    local x, y = data['x'], data['y']
    local radius = data['graph_radius']
    local val = math.min(math.max(0, value), max_value)
    local percent = val / max_value

    local graph_bg_colour = data['graph_bg_colour']
    local graph_bg_alpha = data['graph_bg_alpha']
    local graph_fg_colour = data['graph_fg_colour']
    local graph_fg_alpha = data['graph_fg_alpha']

    -- Draw hexagon outline
    local function draw_hexagon(cx, cy, r, filled)
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

    -- Main hexagon background
    cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_bg_colour, graph_bg_alpha))
    draw_hexagon(x, y, radius, false)

    -- 6 segment hexagons around center
    local segments_lit = math.floor(6 * percent)
    local seg_radius = radius * 0.35
    local seg_distance = radius * 0.6

    for i = 0, 5 do
        local angle = (i * math.pi / 3)
        local sx = x + seg_distance * math.cos(angle)
        local sy = y + seg_distance * math.sin(angle)

        if i < segments_lit then
            cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_fg_colour, graph_fg_alpha + 0.3))
            draw_hexagon(sx, sy, seg_radius, true)
            cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_fg_colour, 1.0))
            draw_hexagon(sx, sy, seg_radius, false)
        else
            cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_bg_colour, graph_bg_alpha * 2))
            draw_hexagon(sx, sy, seg_radius, false)
        end
    end

    -- Center hexagon (always shows percentage glow)
    if percent > 0 then
        cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_fg_colour, graph_fg_alpha * percent))
        draw_hexagon(x, y, seg_radius * 0.8, true)
    end

    -- Inner value indicator (center small hex)
    if inner_value and inner_value > 0 then
        local inner_val = math.min(math.max(0, inner_value), max_value)
        local inner_percent = inner_val / max_value
        local inner_colour = data['inner_graph_fg_colour'] or 0x4ECDC4

        cairo_set_source_rgba(cr, rgb_to_r_g_b(inner_colour, 0.6))
        draw_hexagon(x, y, seg_radius * 0.5 * inner_percent, true)
    end

    draw_gauge_text(cr, data, value, x, y + radius + 8)
end

-------------------------------------------------------------------------------
--                                                         STYLE 6: SPIRAL
--  Spiral gauge unwinding from center outward
--  Creates hypnotic effect with Archimedean spiral
-------------------------------------------------------------------------------
function draw_gauge_spiral(cr, data, value, inner_value)
    local max_value = data['max_value']
    local x, y = data['x'], data['y']
    local max_radius = data['graph_radius']
    local val = math.min(math.max(0, value), max_value)
    local percent = val / max_value

    local graph_bg_colour = data['graph_bg_colour']
    local graph_bg_alpha = data['graph_bg_alpha']
    local graph_fg_colour = data['graph_fg_colour']
    local graph_fg_alpha = data['graph_fg_alpha']

    -- Background circle
    cairo_arc(cr, x, y, max_radius, 0, 2*math.pi)
    cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_bg_colour, graph_bg_alpha))
    cairo_set_line_width(cr, 2)
    cairo_stroke(cr)

    -- Draw spiral (Archimedean spiral: r = a + b*theta)
    local spirals = 3  -- Number of complete spirals
    local total_angle = spirals * 2 * math.pi
    local angle_filled = total_angle * percent
    local segments = 100

    if percent > 0 then
        cairo_new_path(cr)
        local first = true

        for i = 0, segments do
            local t = (i / segments) * angle_filled
            local r = (max_radius - 3) * (t / total_angle)
            local sx = x + r * math.cos(t)
            local sy = y + r * math.sin(t)

            if first then
                cairo_move_to(cr, sx, sy)
                first = false
            else
                cairo_line_to(cr, sx, sy)
            end
        end

        cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_fg_colour, graph_fg_alpha + 0.3))
        cairo_set_line_width(cr, 3)
        cairo_stroke(cr)

        -- Glowing end point
        local end_angle = angle_filled
        local end_r = (max_radius - 3) * (end_angle / total_angle)
        local end_x = x + end_r * math.cos(end_angle)
        local end_y = y + end_r * math.sin(end_angle)

        cairo_arc(cr, end_x, end_y, 3, 0, 2*math.pi)
        cairo_set_source_rgba(cr, rgb_to_r_g_b(graph_fg_colour, 1.0))
        cairo_fill(cr)
    end

    -- Inner spiral indicator
    if inner_value and inner_value > 0 then
        local inner_val = math.min(math.max(0, inner_value), max_value)
        local inner_percent = inner_val / max_value
        local inner_colour = data['inner_graph_fg_colour'] or 0x4ECDC4
        local inner_angle = total_angle * inner_percent * 0.7

        cairo_new_path(cr)
        local first = true
        for i = 0, 50 do
            local t = (i / 50) * inner_angle
            local r = (max_radius - 8) * (t / total_angle) * 0.7
            local sx = x + r * math.cos(t + math.pi)
            local sy = y + r * math.sin(t + math.pi)

            if first then
                cairo_move_to(cr, sx, sy)
                first = false
            else
                cairo_line_to(cr, sx, sy)
            end
        end

        cairo_set_source_rgba(cr, rgb_to_r_g_b(inner_colour, 0.5))
        cairo_set_line_width(cr, 2)
        cairo_stroke(cr)
    end

    draw_gauge_text(cr, data, value, x, y + max_radius + 8)
end

-------------------------------------------------------------------------------
--                                                      Helper: Draw Text
--  Shared text rendering for all gauge styles
-------------------------------------------------------------------------------
function draw_gauge_text(cr, data, value, x, y)
    local caption = data['caption']
    local caption_weight = data['caption_weight']
    local caption_size = data['caption_size']
    local caption_fg_colour = data['caption_fg_colour']
    local caption_fg_alpha = data['caption_fg_alpha']
    local txt_size = data['txt_size']
    local txt_fg_colour = data['txt_fg_colour']
    local txt_fg_alpha = data['txt_fg_alpha']

    -- Value text (centered above caption)
    cairo_select_font_face(cr, "DejaVu Sans", CAIRO_FONT_SLANT_NORMAL, 0)
    cairo_set_font_size(cr, txt_size)
    cairo_set_source_rgba(cr, rgb_to_r_g_b(txt_fg_colour, txt_fg_alpha))

    local text_extents = cairo_text_extents_t:create()
    tolua.takeownership(text_extents)
    cairo_text_extents(cr, tostring(value), text_extents)
    cairo_move_to(cr, x - text_extents.width/2, y - 3)
    cairo_show_text(cr, tostring(value))
    cairo_stroke(cr)

    -- Caption text
    cairo_select_font_face(cr, "DejaVu Sans", CAIRO_FONT_SLANT_NORMAL, caption_weight)
    cairo_set_font_size(cr, caption_size)
    cairo_set_source_rgba(cr, rgb_to_r_g_b(caption_fg_colour, caption_fg_alpha))

    cairo_text_extents(cr, caption, text_extents)
    cairo_move_to(cr, x - text_extents.width/2, y + caption_size + 2)
    cairo_show_text(cr, caption)
    cairo_stroke(cr)
end

--==============================================================================
--                                   USAGE EXAMPLES
--
--  To use any of these styles, replace the draw_gauge_ring call with:
--
--  draw_gauge_square(cr, data, value, inner_value)    -- Rectangular progress
--  draw_gauge_triangle(cr, data, value, inner_value)  -- Pyramid fill
--  draw_gauge_binary(cr, data, value, inner_value)    -- Digital matrix dots
--  draw_gauge_wave(cr, data, value, inner_value)      -- Liquid wave fill
--  draw_gauge_hexagon(cr, data, value, inner_value)   -- Honeycomb segments
--  draw_gauge_spiral(cr, data, value, inner_value)    -- Archimedean spiral
--
--  In the load_gauge_rings function (line 532 in conky-gauges.lua):
--      Change: draw_gauge_ring(cr, data, value, inner_value)
--      To:     draw_gauge_STYLE(cr, data, value, inner_value)
--
--  Or create a style selector in the gauge data structure:
--      gauge_style = 'square'  -- Add to each gauge definition
--
--  Then dispatch based on style:
--      if data['gauge_style'] == 'square' then
--          draw_gauge_square(cr, data, value, inner_value)
--      elseif data['gauge_style'] == 'triangle' then
--          draw_gauge_triangle(cr, data, value, inner_value)
--      -- etc...
--      else
--          draw_gauge_ring(cr, data, value, inner_value)  -- Default circular
--      end
--==============================================================================
