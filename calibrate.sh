#!/bin/bash
#
# touchscreen-calibrator — Interactive touchscreen calibration for Linux Mint / X11
# Detects touchscreen, runs calibration, converts to libinput matrix, applies & persists.
#
# Usage:
#   ./calibrate.sh          # Interactive: detect, calibrate, install
#   ./calibrate.sh --apply  # Re-apply saved calibration without recalibrating
#   ./calibrate.sh --remove # Remove calibration config
#

set -euo pipefail

CONF_DIR="/etc/X11/xorg.conf.d"
CONF_FILE="99-touchscreen-calibration.conf"
AUTOSTART_DIR="$HOME/.config/autostart"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Detect touchscreen devices ───────────────────────────────────────────────

detect_touchscreens() {
    local devices=()
    local ids=()

    while IFS= read -r line; do
        if echo "$line" | grep -qi "touch"; then
            local name id
            name=$(echo "$line" | sed -n 's/.*↳ \(.*\)\tid=.*/\1/p' | sed 's/[[:space:]]*$//')
            id=$(echo "$line" | sed -n 's/.*id=\([0-9]*\).*/\1/p')
            if [ -n "$name" ] && [ -n "$id" ]; then
                # Check if it's a pointer/touchscreen (not keyboard)
                if echo "$line" | grep -qi "slave  pointer"; then
                    # Skip "Mouse" sub-devices — they mirror the main touch device
                    if ! echo "$name" | grep -qi "mouse"; then
                        devices+=("$name")
                        ids+=("$id")
                    fi
                fi
            fi
        fi
    done <<< "$(xinput list)"

    if [ ${#devices[@]} -eq 0 ]; then
        error "No touchscreen devices found!"
        echo "Connected input devices:"
        xinput list
        exit 1
    fi

    echo "${#devices[@]}" > /tmp/.ts_count
    for i in "${!devices[@]}"; do
        echo "${devices[$i]}" > "/tmp/.ts_device_$i"
        echo "${ids[$i]}" > "/tmp/.ts_id_$i"
    done
}

select_touchscreen() {
    detect_touchscreens
    local count
    count=$(cat /tmp/.ts_count)

    if [ "$count" -eq 1 ]; then
        TOUCH_DEVICE=$(cat /tmp/.ts_device_0)
        TOUCH_ID=$(cat /tmp/.ts_id_0)
        info "Detected touchscreen: $TOUCH_DEVICE (id=$TOUCH_ID)"
    else
        info "Multiple touchscreen devices found:"
        for ((i=0; i<count; i++)); do
            echo "  $((i+1))) $(cat /tmp/.ts_device_$i) (id=$(cat /tmp/.ts_id_$i))"
        done
        echo ""
        read -rp "Select device [1-$count]: " choice
        choice=$((choice - 1))
        TOUCH_DEVICE=$(cat "/tmp/.ts_device_$choice")
        TOUCH_ID=$(cat "/tmp/.ts_id_$choice")
    fi

    # Clean up temp files
    rm -f /tmp/.ts_count /tmp/.ts_device_* /tmp/.ts_id_*
}

# ─── Detect displays ─────────────────────────────────────────────────────────

detect_displays() {
    local displays=()
    while IFS= read -r line; do
        local name
        name=$(echo "$line" | awk '{print $1}')
        displays+=("$name")
    done <<< "$(xrandr --current | grep " connected")"

    if [ ${#displays[@]} -eq 0 ]; then
        error "No connected displays found!"
        exit 1
    fi

    if [ ${#displays[@]} -eq 1 ]; then
        DISPLAY_OUTPUT="${displays[0]}"
        info "Single display detected: $DISPLAY_OUTPUT"
    else
        info "Multiple displays detected:"
        for i in "${!displays[@]}"; do
            local res
            res=$(xrandr --current | grep -A1 "^${displays[$i]} " | tail -1 | awk '{print $1}')
            echo "  $((i+1))) ${displays[$i]} ($res)"
        done
        echo ""
        read -rp "Which display is the touchscreen projecting on? [1-${#displays[@]}]: " choice
        choice=$((choice - 1))
        DISPLAY_OUTPUT="${displays[$choice]}"
    fi
}

# ─── Check driver ────────────────────────────────────────────────────────────

check_driver() {
    local driver
    driver=$(grep "Using input driver" /var/log/Xorg.0.log 2>/dev/null | grep "$TOUCH_DEVICE" | grep -oP "driver '\K[^']+'" | tr -d "'" | head -1)

    if [ -z "$driver" ]; then
        # Fallback: check if libinput props exist
        if xinput list-props "$TOUCH_ID" 2>/dev/null | grep -q "libinput Calibration Matrix"; then
            driver="libinput"
        else
            driver="evdev"
        fi
    fi

    DRIVER="$driver"
    info "Input driver: $DRIVER"
}

# ─── Run calibration ────────────────────────────────────────────────────────

run_calibration() {
    if ! command -v xinput_calibrator &>/dev/null; then
        error "xinput_calibrator not found. Install it:"
        echo "  sudo apt install xinput-calibrator"
        exit 1
    fi

    info "Starting calibration for: $TOUCH_DEVICE"
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  TAP THE 4 CROSSHAIRS as they appear on the screen!     ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Map to correct output first
    xinput map-to-output "$TOUCH_ID" "$DISPLAY_OUTPUT" 2>/dev/null || true

    # Run calibrator and capture output
    local output
    output=$(xinput_calibrator --device "$TOUCH_DEVICE" 2>&1) || {
        error "Calibration failed or was cancelled."
        exit 1
    }

    # Parse MinX, MaxX, MinY, MaxY from output
    MIN_X=$(echo "$output" | grep -oP '"MinX"\s+"\K[^"]+')
    MAX_X=$(echo "$output" | grep -oP '"MaxX"\s+"\K[^"]+')
    MIN_Y=$(echo "$output" | grep -oP '"MinY"\s+"\K[^"]+')
    MAX_Y=$(echo "$output" | grep -oP '"MaxY"\s+"\K[^"]+')

    if [ -z "$MIN_X" ] || [ -z "$MAX_X" ] || [ -z "$MIN_Y" ] || [ -z "$MAX_Y" ]; then
        error "Could not parse calibration values from xinput_calibrator output."
        echo "Raw output:"
        echo "$output"
        exit 1
    fi

    ok "Calibration values: MinX=$MIN_X MaxX=$MAX_X MinY=$MIN_Y MaxY=$MAX_Y"
}

# ─── Convert to libinput matrix ──────────────────────────────────────────────

compute_libinput_matrix() {
    # Convert evdev-style min/max calibration to a 3x3 libinput matrix
    # Matrix: [a 0 c; 0 e f; 0 0 1]
    # a = 65535 / (MaxX - MinX)
    # c = -MinX / (MaxX - MinX)
    # e = 65535 / (MaxY - MinY)
    # f = -MinY / (MaxY - MinY)

    MATRIX_A=$(echo "scale=6; 65535 / ($MAX_X - ($MIN_X))" | bc)
    MATRIX_C=$(echo "scale=6; -1 * ($MIN_X) / ($MAX_X - ($MIN_X))" | bc)
    MATRIX_E=$(echo "scale=6; 65535 / ($MAX_Y - ($MIN_Y))" | bc)
    MATRIX_F=$(echo "scale=6; -1 * ($MIN_Y) / ($MAX_Y - ($MIN_Y))" | bc)

    CALIB_MATRIX="$MATRIX_A 0 $MATRIX_C 0 $MATRIX_E $MATRIX_F 0 0 1"
    info "Libinput calibration matrix: $CALIB_MATRIX"
}

# ─── Apply calibration ───────────────────────────────────────────────────────

apply_calibration() {
    # Map to display
    xinput map-to-output "$TOUCH_ID" "$DISPLAY_OUTPUT" 2>/dev/null || true

    if [ "$DRIVER" = "libinput" ]; then
        xinput set-prop "$TOUCH_DEVICE" "libinput Calibration Matrix" $CALIB_MATRIX
    else
        xinput set-prop "$TOUCH_DEVICE" "Coordinate Transformation Matrix" $CALIB_MATRIX
    fi
    ok "Calibration applied to current session."
}

# ─── Save calibration data ───────────────────────────────────────────────────

save_calibration_data() {
    local data_file="$SCRIPT_DIR/calibrations/$(hostname).conf"
    mkdir -p "$SCRIPT_DIR/calibrations"

    cat > "$data_file" << EOF
# Touchscreen calibration for $(hostname)
# Generated: $(date -Iseconds)
TOUCH_DEVICE="$TOUCH_DEVICE"
DISPLAY_OUTPUT="$DISPLAY_OUTPUT"
DRIVER="$DRIVER"
CALIB_MATRIX="$CALIB_MATRIX"
MIN_X="$MIN_X"
MAX_X="$MAX_X"
MIN_Y="$MIN_Y"
MAX_Y="$MAX_Y"
EOF
    ok "Calibration data saved to: $data_file"
}

# ─── Install persistent config ───────────────────────────────────────────────

install_persistent() {
    echo ""
    info "Installing persistent calibration..."

    # 1. Create the apply script
    local apply_script="$SCRIPT_DIR/apply-calibration.sh"
    cat > "$apply_script" << EOF
#!/bin/bash
# Auto-generated: apply touchscreen calibration for $(hostname)
# Device: $TOUCH_DEVICE → $DISPLAY_OUTPUT
sleep 2
DEVICE="$TOUCH_DEVICE"
xinput map-to-output "\$DEVICE" "$DISPLAY_OUTPUT" 2>/dev/null || true
xinput set-prop "\$DEVICE" "libinput Calibration Matrix" $CALIB_MATRIX 2>/dev/null || \\
xinput set-prop "\$DEVICE" "Coordinate Transformation Matrix" $CALIB_MATRIX 2>/dev/null || true
EOF
    chmod +x "$apply_script"

    # 2. Autostart entry (works without root)
    mkdir -p "$AUTOSTART_DIR"
    cat > "$AUTOSTART_DIR/touchscreen-calibration.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Touchscreen Calibration
Comment=Apply touchscreen calibration on login
Exec=$apply_script
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-MATE-Autostart-enabled=true
X-Cinnamon-Autostart-enabled=true
EOF
    ok "Autostart entry installed (works on next login)."

    # 3. xorg.conf.d (needs root, most reliable)
    local xorg_conf="/tmp/$CONF_FILE"
    if [ "$DRIVER" = "libinput" ]; then
        cat > "$xorg_conf" << EOF
Section "InputClass"
	Identifier	"touchscreen calibration ($(hostname))"
	MatchProduct	"$TOUCH_DEVICE"
	Driver		"libinput"
	Option		"CalibrationMatrix"	"$CALIB_MATRIX"
EndSection
EOF
    else
        cat > "$xorg_conf" << EOF
Section "InputClass"
	Identifier	"touchscreen calibration ($(hostname))"
	MatchProduct	"$TOUCH_DEVICE"
	Option	"MinX"	"$MIN_X"
	Option	"MaxX"	"$MAX_X"
	Option	"MinY"	"$MIN_Y"
	Option	"MaxY"	"$MAX_Y"
	Option	"SwapXY"	"0"
	Option	"InvertX"	"0"
	Option	"InvertY"	"0"
EndSection
EOF
    fi

    echo ""
    info "Installing X11 config (requires authentication)..."
    if sudo -n true 2>/dev/null; then
        sudo mkdir -p "$CONF_DIR"
        sudo cp "$xorg_conf" "$CONF_DIR/$CONF_FILE"
        sudo chmod 644 "$CONF_DIR/$CONF_FILE"
        ok "Installed: $CONF_DIR/$CONF_FILE"
    elif command -v pkexec &>/dev/null; then
        pkexec bash -c "mkdir -p '$CONF_DIR' && cp '$xorg_conf' '$CONF_DIR/$CONF_FILE' && chmod 644 '$CONF_DIR/$CONF_FILE'" && \
            ok "Installed: $CONF_DIR/$CONF_FILE" || \
            warn "Could not install xorg.conf.d config. Run manually:\n  sudo cp $xorg_conf $CONF_DIR/$CONF_FILE"
    else
        warn "No root access. Install manually:"
        echo "  sudo mkdir -p $CONF_DIR"
        echo "  sudo cp $xorg_conf $CONF_DIR/$CONF_FILE"
    fi

    rm -f "$xorg_conf"
}

# ─── Re-apply saved calibration ──────────────────────────────────────────────

cmd_apply() {
    local data_file="$SCRIPT_DIR/calibrations/$(hostname).conf"
    if [ ! -f "$data_file" ]; then
        error "No saved calibration for $(hostname). Run calibrate.sh first."
        exit 1
    fi
    source "$data_file"
    TOUCH_ID=$(xinput list | grep "$TOUCH_DEVICE" | grep -v "Mouse\|Keyboard" | head -1 | sed -n 's/.*id=\([0-9]*\).*/\1/p')
    apply_calibration
}

# ─── Remove calibration ──────────────────────────────────────────────────────

cmd_remove() {
    info "Removing touchscreen calibration..."

    rm -f "$AUTOSTART_DIR/touchscreen-calibration.desktop" && \
        ok "Removed autostart entry."

    if [ -f "$CONF_DIR/$CONF_FILE" ]; then
        if sudo -n true 2>/dev/null; then
            sudo rm -f "$CONF_DIR/$CONF_FILE"
        elif command -v pkexec &>/dev/null; then
            pkexec rm -f "$CONF_DIR/$CONF_FILE"
        else
            warn "Remove manually: sudo rm $CONF_DIR/$CONF_FILE"
        fi
        ok "Removed xorg.conf.d config."
    fi

    ok "Calibration removed. Reboot to reset to defaults."
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       Touchscreen Calibrator for Linux Mint / X11       ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    case "${1:-}" in
        --apply)
            cmd_apply
            exit 0
            ;;
        --remove)
            cmd_remove
            exit 0
            ;;
        --help|-h)
            echo "Usage: $0 [--apply|--remove|--help]"
            echo ""
            echo "  (no args)  Run interactive calibration"
            echo "  --apply    Re-apply saved calibration for this machine"
            echo "  --remove   Remove all calibration config"
            echo "  --help     Show this help"
            exit 0
            ;;
    esac

    # Step 1: Detect hardware
    select_touchscreen
    detect_displays
    check_driver

    # Step 2: Calibrate
    echo ""
    run_calibration
    compute_libinput_matrix

    # Step 3: Apply now
    apply_calibration

    # Step 4: Test
    echo ""
    echo -e "${YELLOW}Test the calibration now — tap around the screen.${NC}"
    read -rp "Is the calibration correct? [Y/n]: " answer
    if [[ "${answer,,}" == "n" ]]; then
        warn "Calibration rejected. Run again to retry."
        # Reset to identity
        if [ "$DRIVER" = "libinput" ]; then
            xinput set-prop "$TOUCH_DEVICE" "libinput Calibration Matrix" 1 0 0 0 1 0 0 0 1
        fi
        exit 1
    fi

    # Step 5: Save & install permanently
    save_calibration_data
    install_persistent

    echo ""
    ok "All done! Calibration is active and will persist after reboot."
    echo ""
}

main "$@"
