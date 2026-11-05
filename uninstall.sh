#!/usr/bin/env bash
#
# Remove both Dexnor fixes.
#
#   sudo ./uninstall.sh

set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "Run this with sudo:  sudo $0" >&2
    exit 1
fi

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

echo "=============================================================="
echo " 1/2  Bluetooth keyboard latency fix"
echo "=============================================================="
"$HERE/keyboard/install.sh" --uninstall

echo
echo "=============================================================="
echo " 2/2  Touchpad physical-click fix"
echo "=============================================================="
"$HERE/touchpad/install.sh" --uninstall

echo
echo "Both fixes removed."
