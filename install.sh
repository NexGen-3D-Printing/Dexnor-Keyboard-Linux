#!/usr/bin/env bash
#
# Install both Dexnor fixes.
#
#   sudo ./install.sh
#
# Pair the keyboard before running this on a fresh OS install.
# Install one fix only:
#   sudo ./keyboard/install.sh
#   sudo ./touchpad/install.sh

set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "Run this with sudo:  sudo $0" >&2
    exit 1
fi

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

for f in "$HERE/keyboard/install.sh" "$HERE/touchpad/install.sh"; do
    [[ -x $f ]] || { echo "missing or not executable: $f" >&2; exit 1; }
done

echo "=============================================================="
echo " 1/2  Bluetooth keyboard latency fix"
echo "=============================================================="
"$HERE/keyboard/install.sh"

echo
echo "=============================================================="
echo " 2/2  Touchpad physical-click fix"
echo "=============================================================="
"$HERE/touchpad/install.sh"

echo
echo "Both fixes installed. Test the keyboard and the physical"
echo "touchpad click now."
