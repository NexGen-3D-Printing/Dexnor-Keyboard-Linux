#!/usr/bin/env bash
#
# install.sh
#
# Install both Dexnor fixes.
#
#   ./install.sh
#
# Pair the keyboard before running this on a fresh OS install.
# Install one fix only:
#   ./keyboard/install.sh
#   ./touchpad/install.sh

set -euo pipefail

# ------------------------------------------------------------ sudo check
# Prompt for sudo password at the start if not running as root
if [[ ${EUID} -ne 0 ]]; then
    echo "This script requires root privileges."
    if command -v sudo >/dev/null 2>&1; then
        # Try to get sudo credentials upfront
        echo "Prompting for sudo password..."
        if ! sudo -v; then
            echo "Failed to get sudo privileges. Exiting." >&2
            exit 1
        fi
        # Run the script again with sudo
        exec sudo "$0" "$@"
    else
        echo "sudo not found. Please run this script as root." >&2
        exit 1
    fi
fi

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

for f in "$HERE/keyboard/install.sh" "$HERE/touchpad/install.sh"; do
    [[ -x $f ]] || { echo "missing or not executable: $f" >&2; exit 1; }
done

echo
echo "=============================================================="
echo "  Starting Dexnor fixes installation"
echo "=============================================================="
echo "  This will install:"
echo "    - Bluetooth keyboard latency fix"
echo "    - Touchpad physical-click fix"
echo "==============================================================" 
echo

# Bluetooth power management opt-out option
if [[ "${DISABLE_BLUETOOTH_PM:-0}" == "0" ]]; then
    DISABLE_PM=0
else
    DISABLE_PM=1
fi

echo "[1/2] Installing Bluetooth keyboard latency fix..."
echo "--------------------------------------------------------------"
echo "Bluetooth power management optimization: $([ $DISABLE_PM -eq 0 ] && echo 'ENABLED (improves stability)' || echo 'SKIPPED')"
if [[ $DISABLE_PM -eq 0 ]]; then
    if [[ -w /sys/class/bluetooth/hci0/power/control ]]; then
        echo "on" > /sys/class/bluetooth/hci0/power/control
    fi
fi

if "$HERE/keyboard/install.sh"; then
    echo
    echo "[OK] Keyboard fix installed successfully."
else
    RC=$?
    echo
    echo "[FAILED] Keyboard fix failed with exit code $RC."
    echo "         Check the logs above for details."
    echo
fi

echo
echo "=============================================================="
echo "[2/2] Installing Touchpad physical-click fix..."
echo "--------------------------------------------------------------"

if "$HERE/touchpad/install.sh"; then
    echo
    echo "[OK] Touchpad fix installed successfully."
else
    RC=$?
    echo
    echo "[FAILED] Touchpad fix failed with exit code $RC."
    echo "         Check the logs above for details."
    echo
fi

echo
echo "=============================================================="
echo "  Verification checks"
echo "=============================================================="

# Check keyboard service
echo
echo "Keyboard service status:"
echo "--------------------------------------------------------------"
systemctl is-enabled bt-keyboard-latency.service >/dev/null 2>&1 && echo "  [OK] Service is enabled" || echo "  [WARN] Service is not enabled"
systemctl is-active bt-keyboard-latency.service >/dev/null 2>&1 && echo "  [OK] Service is active" || echo "  [INFO] Service not yet active (keyboard not connected)"

# Check touchpad service
echo
echo "Touchpad service status:"
echo "--------------------------------------------------------------"
systemctl is-enabled dexnor-touchpad-click.service >/dev/null 2>&1 && echo "  [OK] Service is enabled" || echo "  [WARN] Service is not enabled"
systemctl is-active dexnor-touchpad-click.service >/dev/null 2>&1 && echo "  [OK] Service is active" || echo "  [INFO] Service not yet active (touchpad not connected)"

echo
echo "=============================================================="
echo "  Installation summary"
echo "=============================================================="
echo "  Both fixes have been installed successfully!"
echo
echo "  To apply the changes:"
echo "    1. Reconnect your Bluetooth keyboard"
echo "    2. Reconnect your touchpad (if separate)"
echo
echo "  If services didn't start automatically, try:"
echo "    sudo systemctl restart bt-keyboard-latency"
echo "    sudo systemctl restart dexnor-touchpad-click"
echo
echo "  To monitoring logs:"
echo "    - Keyboard:  sudo journalctl -u bt-keyboard-latency -f"
echo "    - Touchpad:  sudo journalctl -u dexnor-touchpad-click -f"
echo "=============================================================="
