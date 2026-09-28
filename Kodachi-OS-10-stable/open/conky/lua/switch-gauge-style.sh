#!/bin/bash

# switch-gauge-style.sh
# ===========================================================
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

#==============================================================================
#  switch-gauge-style.sh
#
#  Quick switcher for Kodachi Conky gauge styles
#  Usage: ./switch-gauge-style.sh [style]
#  Styles: circle, square, triangle, binary, wave, hexagon, spiral, demo
#
#  License: GNU GPL v2 or later
#==============================================================================

CONKY_DIR="$HOME/.config/kodachi/conky"
CONKY_LUA_DIR="$CONKY_DIR/lua"
CONKY_CONFIG="$CONKY_DIR/configs/conkyrc-gauges.conf"
GAUGE_FILE="$CONKY_LUA_DIR/conky-gauges.lua"
BACKUP_FILE="$CONKY_LUA_DIR/conky-gauges.lua.backup"

# Color codes for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

#==============================================================================
# Functions
#==============================================================================

show_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           Kodachi Conky Gauge Style Switcher v1.0            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

show_usage() {
    echo -e "${YELLOW}Usage:${NC} $0 [style]"
    echo ""
    echo "Available styles:"
    echo -e "  ${GREEN}circle${NC}     - Classic circular arc gauge (original)"
    echo -e "  ${GREEN}square${NC}     - Rectangular progress bar"
    echo -e "  ${GREEN}triangle${NC}   - Pyramid-shaped gauge"
    echo -e "  ${GREEN}binary${NC}     - Digital matrix blocks"
    echo -e "  ${GREEN}wave${NC}       - Liquid wave fill (animated)"
    echo -e "  ${GREEN}hexagon${NC}    - Honeycomb segments"
    echo -e "  ${GREEN}spiral${NC}     - Archimedean spiral"
    echo -e "  ${GREEN}demo${NC}       - Show all styles (different per gauge)"
    echo ""
    echo "Examples:"
    echo "  $0 wave       # Switch to wave style"
    echo "  $0 demo       # Show all styles demo"
    echo "  $0 circle     # Revert to original circular"
    echo ""
}

create_backup() {
    if [ ! -f "$BACKUP_FILE" ]; then
        echo -e "${BLUE}Creating backup...${NC}"
        cp "$GAUGE_FILE" "$BACKUP_FILE"
        echo -e "${GREEN}✓ Backup created: $BACKUP_FILE${NC}"
    else
        echo -e "${BLUE}Backup already exists${NC}"
    fi
}

restore_backup() {
    if [ -f "$BACKUP_FILE" ]; then
        echo -e "${BLUE}Restoring from backup...${NC}"
        cp "$BACKUP_FILE" "$GAUGE_FILE"
        echo -e "${GREEN}✓ Restored original file${NC}"
    else
        echo -e "${RED}✗ No backup found${NC}"
        return 1
    fi
}

apply_style() {
    local style="$1"

    # Check if gauge-styles.lua exists
    if [ ! -f "$CONKY_LUA_DIR/gauge-styles.lua" ]; then
        echo -e "${RED}✗ Error: gauge-styles.lua not found${NC}"
        echo "Expected location: $CONKY_LUA_DIR/gauge-styles.lua"
        exit 1
    fi

    # Create backup first
    create_backup

    case "$style" in
        circle)
            echo -e "${BLUE}Switching to CIRCLE style (original)...${NC}"
            restore_backup
            ;;

        demo)
            echo -e "${BLUE}Switching to DEMO mode (all styles)...${NC}"
            sed -i "s|lua_load.*conky-gauges.*\.lua|lua_load $CONKY_LUA_DIR/conky-gauges-demo.lua|" "$CONKY_CONFIG"
            echo -e "${GREEN}✓ Demo mode enabled${NC}"
            echo -e "${YELLOW}Note: Each gauge row shows a different style${NC}"
            ;;

        square|triangle|binary|wave|hexagon|spiral)
            echo -e "${BLUE}Switching to ${style^^} style...${NC}"

            # Restore original first
            restore_backup

            # Check if gauge-styles.lua is already loaded
            if ! grep -q "gauge-styles.lua" "$GAUGE_FILE"; then
                # Add require line after the cairo requires
                sed -i "/require 'cairo_xlib'/a \\
\\
-- Load alternative gauge styles\\
dofile(os.getenv(\"HOME\") .. \"/.config/kodachi/conky/lua/gauge-styles.lua\")" "$GAUGE_FILE"
            fi

            # Replace draw_gauge_ring call with selected style
            sed -i "s|draw_gauge_ring(cr, data, value, inner_value)|draw_gauge_${style}(cr, data, value, inner_value)|" "$GAUGE_FILE"

            echo -e "${GREEN}✓ Style applied: ${style^^}${NC}"
            ;;

        *)
            echo -e "${RED}✗ Unknown style: $style${NC}"
            show_usage
            exit 1
            ;;
    esac
}

reload_conky() {
    echo -e "${BLUE}Reloading Conky...${NC}"

    # Kill existing conky processes running the gauge config
    pkill -f "conkyrc-gauges.conf"
    sleep 0.5

    # Restart conky with the gauge config
    if [ -f "$CONKY_CONFIG" ]; then
        conky -c "$CONKY_CONFIG" &
        echo -e "${GREEN}✓ Conky reloaded${NC}"
    else
        echo -e "${RED}✗ Config file not found: $CONKY_CONFIG${NC}"
        return 1
    fi
}

show_current_style() {
    echo -e "${BLUE}Detecting current style...${NC}"

    if grep -q "conky-gauges-demo.lua" "$CONKY_CONFIG"; then
        echo -e "Current style: ${GREEN}DEMO MODE${NC} (all styles)"
    elif grep -q "draw_gauge_square" "$GAUGE_FILE" 2>/dev/null; then
        echo -e "Current style: ${GREEN}SQUARE${NC}"
    elif grep -q "draw_gauge_triangle" "$GAUGE_FILE" 2>/dev/null; then
        echo -e "Current style: ${GREEN}TRIANGLE${NC}"
    elif grep -q "draw_gauge_binary" "$GAUGE_FILE" 2>/dev/null; then
        echo -e "Current style: ${GREEN}BINARY${NC}"
    elif grep -q "draw_gauge_wave" "$GAUGE_FILE" 2>/dev/null; then
        echo -e "Current style: ${GREEN}WAVE${NC}"
    elif grep -q "draw_gauge_hexagon" "$GAUGE_FILE" 2>/dev/null; then
        echo -e "Current style: ${GREEN}HEXAGON${NC}"
    elif grep -q "draw_gauge_spiral" "$GAUGE_FILE" 2>/dev/null; then
        echo -e "Current style: ${GREEN}SPIRAL${NC}"
    else
        echo -e "Current style: ${GREEN}CIRCLE${NC} (original)"
    fi
    echo ""
}

#==============================================================================
# Main
#==============================================================================

show_banner

# Check if files exist
if [ ! -f "$GAUGE_FILE" ]; then
    echo -e "${RED}✗ Error: conky-gauges.lua not found${NC}"
    echo "Expected location: $GAUGE_FILE"
    exit 1
fi

if [ ! -f "$CONKY_CONFIG" ]; then
    echo -e "${RED}✗ Error: conkyrc-gauges.conf not found${NC}"
    echo "Expected location: $CONKY_CONFIG"
    exit 1
fi

# Show current style
show_current_style

# If no arguments, show usage
if [ $# -eq 0 ]; then
    show_usage
    exit 0
fi

# Get requested style
STYLE="$1"

# Apply the style
apply_style "$STYLE"

# Reload Conky
reload_conky

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Style changed successfully! Check your desktop.          ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "To try another style: $0 [style]"
echo "To revert to original: $0 circle"
echo ""
