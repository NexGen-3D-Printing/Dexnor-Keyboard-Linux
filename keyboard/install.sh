#!/usr/bin/env bash
#
# keyboard/install.sh
#
# Permanent fix for dropped keystrokes on the Dexnor Bluetooth keyboard
# (HID-over-GATT) under Linux/BlueZ.
#
# Root cause
# ----------
# The keyboard's GAP PPCP characteristic (0x2A04) advertises:
#     min interval 6 (7.5 ms), max interval 6 (7.5 ms),
#     latency 35, supervision timeout 2000 ms
# BlueZ 5.76+ reads PPCP and applies it verbatim. Latency 35 allows the
# peripheral to skip 35 of every 36 connection events (~270 ms between
# chances to send a HID report). Windows ignores PPCP, which is why the
# same keyboard is fine there.
#
# What this installs
# ------------------
#   1. /usr/local/sbin/bt-keyboard-latency.py
#      A small daemon that forces latency 0 on the live LE connection.
#   2. bt-keyboard-latency.service
#      Re-applies the override on every connect, after BlueZ has read PPCP.
#   3. Sane [ConnectionParameters] in the BlueZ device info file
#      (Latency=0), so the boot-time default is also correct.
#
# Usage
# -----
#   sudo ./keyboard/install.sh              # install / repair / re-run
#   sudo ./keyboard/install.sh --uninstall  # remove everything
#
# Optional environment overrides:
#   KB_ADDR          keyboard Bluetooth address (auto-detected if unset)
#   BT_MIN_INTERVAL  default 6   (x1.25 ms)
#   BT_MAX_INTERVAL  default 6   (x1.25 ms)
#   BT_LATENCY       default 0
#   BT_SUPV_TIMEOUT  default 200 (x10 ms)
#
# Re-running is safe and idempotent.

set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "Run this with sudo:  sudo $0 $*" >&2
    exit 1
fi

PY=/usr/local/sbin/bt-keyboard-latency.py
UNIT=/etc/systemd/system/bt-keyboard-latency.service
SERVICE=bt-keyboard-latency.service

BT_MIN_INTERVAL=${BT_MIN_INTERVAL:-6}
BT_MAX_INTERVAL=${BT_MAX_INTERVAL:-6}
BT_LATENCY=${BT_LATENCY:-0}
BT_SUPV_TIMEOUT=${BT_SUPV_TIMEOUT:-200}

# ---------------------------------------------------------------- uninstall
if [[ ${1:-} == "--uninstall" ]]; then
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "$UNIT" "$PY"
    systemctl daemon-reload
    echo "Removed $SERVICE and $PY."
    echo "Note: the [ConnectionParameters] entry in the BlueZ info file was left"
    echo "alone. Delete that section manually if you want a fully stock setup."
    exit 0
fi

# ------------------------------------------------------------ dependencies
if ! python3 - <<'PY' >/dev/null 2>&1
import ctypes.util
import sys
if not ctypes.util.find_library("bluetooth"):
    sys.exit(1)
import dbus  # noqa: F401
import gi    # noqa: F401
PY
then
    echo "Missing Python dependencies for the keyboard fix." >&2
    echo "On Fedora: sudo dnf install python3-dbus python3-gobject bluez-libs" >&2
    exit 1
fi

# ------------------------------------------------------------ detect device
# Keyboard address: explicit, else newest info file named "Dexnor Keyboard".
KB_INFO=""
if [[ -z ${KB_ADDR:-} ]]; then
    while IFS= read -r f; do
        [[ -n $f ]] || continue
        if grep -qE '^Name=Dexnor Keyboard[[:space:]]*$' "$f" 2>/dev/null; then
            KB_ADDR=$(basename "$(dirname "$f")")
            KB_INFO=$f
            break
        fi
    done < <(find /var/lib/bluetooth -mindepth 3 -maxdepth 3 -name info \
                 -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
fi

KB_ADDR=${KB_ADDR^^}
if [[ ! $KB_ADDR =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]; then
    echo "Could not detect the Dexnor keyboard." >&2
    echo "Pair the keyboard first, or set KB_ADDR=AA:BB:CC:DD:EE:FF." >&2
    exit 1
fi

# Find the info file for an explicitly supplied address too, so the
# controller can be derived from it.
if [[ -z $KB_INFO ]]; then
    KB_INFO=$(find /var/lib/bluetooth -mindepth 3 -maxdepth 3 -name info \
                  -path "*/${KB_ADDR}/info" 2>/dev/null | head -n1)
fi

# Controller address: prefer the controller that owns the keyboard entry,
# so multiple adapters do not pick the wrong hci index.
CTRL_ADDR=""
if [[ -n $KB_INFO ]]; then
    CTRL_ADDR=$(basename "$(dirname "$(dirname "$KB_INFO")")")
fi
if [[ -z $CTRL_ADDR ]]; then
    for d in /var/lib/bluetooth/*/; do
        [[ -d $d ]] || continue
        CTRL_ADDR=$(basename "$d")
        break
    done
fi

HCI_DEV=0
if [[ -n $CTRL_ADDR ]]; then
    for h in /sys/class/bluetooth/hci*; do
        [[ -e $h/address ]] || continue
        a=$(tr 'a-f' 'A-F' < "$h/address")
        if [[ $a == "$CTRL_ADDR" ]]; then
            HCI_DEV=${h##*hci}
            break
        fi
    done
fi

echo "controller : ${CTRL_ADDR:-unknown}  (hci${HCI_DEV})"
echo "keyboard   : ${KB_ADDR}"
echo "parameters : min=${BT_MIN_INTERVAL} max=${BT_MAX_INTERVAL} latency=${BT_LATENCY} timeout=${BT_SUPV_TIMEOUT}"
echo

# --------------------------------------------------------------- write daemon
cat > "$PY" <<'PYEOF'
#!/usr/bin/env python3
"""Force latency 0 on the Dexnor BLE keyboard connection.

BlueZ applies the keyboard's PPCP (latency 35), which lets it skip
35 of every 36 connection events and drop HID reports. This daemon
re-applies sane parameters (latency 0) on startup and on every connect.

Subcommands: apply | status | watch

KB_ADDR must be set (the installer writes it into the systemd unit).
"""
import ctypes
import ctypes.util
import os
import sys

KB_ADDR = os.environ.get("KB_ADDR", "")
HCI_DEV = int(os.environ.get("HCI_DEV", "0"))

MIN_INTERVAL = int(os.environ.get("BT_MIN_INTERVAL", "6"))
MAX_INTERVAL = int(os.environ.get("BT_MAX_INTERVAL", "6"))
LATENCY = int(os.environ.get("BT_LATENCY", "0"))
SUPV_TIMEOUT = int(os.environ.get("BT_SUPV_TIMEOUT", "200"))
HCI_TIMEOUT_MS = 10000

HCIGETCONNLIST = 0x800448D4  # _IOR('H', 212, int)


class BdAddr(ctypes.Structure):
    _fields_ = [("b", ctypes.c_uint8 * 6)]


class ConnInfo(ctypes.Structure):
    _fields_ = [
        ("handle", ctypes.c_uint16),
        ("bdaddr", BdAddr),
        ("type", ctypes.c_uint8),
        ("out", ctypes.c_uint8),
        ("state", ctypes.c_uint16),
        ("link_mode", ctypes.c_uint32),
    ]


def load_lib():
    path = ctypes.util.find_library("bluetooth") or "libbluetooth.so.3"
    lib = ctypes.CDLL(path)
    lib.hci_open_dev.argtypes = [ctypes.c_int]
    lib.hci_open_dev.restype = ctypes.c_int
    lib.hci_close_dev.argtypes = [ctypes.c_int]
    lib.hci_close_dev.restype = ctypes.c_int
    lib.str2ba.argtypes = [ctypes.c_char_p, ctypes.POINTER(BdAddr)]
    lib.str2ba.restype = None
    lib.hci_le_conn_update.argtypes = [
        ctypes.c_int, ctypes.c_uint16, ctypes.c_uint16, ctypes.c_uint16,
        ctypes.c_uint16, ctypes.c_uint16, ctypes.c_int,
    ]
    lib.hci_le_conn_update.restype = ctypes.c_int
    return lib


def fmt_addr(b):
    return ":".join("%02X" % x for x in reversed(list(b)))


def get_connections(lib, dd):
    n = 32
    size = 4 + n * ctypes.sizeof(ConnInfo)
    buf = ctypes.create_string_buffer(size)
    ctypes.c_uint16.from_buffer(buf, 0).value = HCI_DEV
    ctypes.c_uint16.from_buffer(buf, 2).value = n
    libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
    libc.ioctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_void_p]
    libc.ioctl.restype = ctypes.c_int
    if libc.ioctl(dd, HCIGETCONNLIST, ctypes.addressof(buf)) < 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))
    count = ctypes.c_uint16.from_buffer(buf, 2).value
    out = []
    for i in range(count):
        ci = ConnInfo.from_buffer(buf, 4 + i * ctypes.sizeof(ConnInfo))
        out.append((ci.handle, fmt_addr(ci.bdaddr.b), ci.type, ci.state))
    return out


def apply_once(verbose=True):
    lib = load_lib()
    dd = lib.hci_open_dev(HCI_DEV)
    if dd < 0:
        err = ctypes.get_errno()
        raise OSError(err, "hci_open_dev(%d): %s" % (HCI_DEV, os.strerror(err)))
    try:
        conns = get_connections(lib, dd)
        target = None
        for handle, addr, ctype, state in conns:
            if addr.upper() == KB_ADDR.upper():
                target = (handle, addr, ctype, state)
                break
        if target is None:
            if verbose:
                print("keyboard %s is not connected (conns: %s)"
                      % (KB_ADDR, ", ".join(a for _, a, _, _ in conns) or "none"))
            return 2
        handle, addr, ctype, state = target
        if verbose:
            print("connection handle for %s: 0x%04x (type=%d state=0x%04x)"
                  % (addr, handle, ctype, state))
            print("requesting min=%d max=%d latency=%d timeout=%d ..."
                  % (MIN_INTERVAL, MAX_INTERVAL, LATENCY, SUPV_TIMEOUT))
        rc = lib.hci_le_conn_update(
            dd, handle, MIN_INTERVAL, MAX_INTERVAL, LATENCY,
            SUPV_TIMEOUT, HCI_TIMEOUT_MS,
        )
        if rc < 0:
            err = ctypes.get_errno()
            print("hci_le_conn_update failed: %s (errno %d)"
                  % (os.strerror(err), err), file=sys.stderr)
            return 1
        if verbose:
            print("OK: latency %d, worst-case poll %.2f ms"
                  % (LATENCY, MAX_INTERVAL * 1.25 * (LATENCY + 1)))
        return 0
    finally:
        lib.hci_close_dev(dd)


def require_root():
    if os.geteuid() != 0:
        print("This needs root. Run with sudo.", file=sys.stderr)
        sys.exit(1)


def require_addr():
    if not KB_ADDR:
        print("KB_ADDR is not set. Run the installer, or export "
              "KB_ADDR=AA:BB:CC:DD:EE:FF.", file=sys.stderr)
        sys.exit(1)


def cmd_apply():
    require_root()
    require_addr()
    sys.exit(apply_once())


def cmd_status():
    require_root()
    require_addr()
    lib = load_lib()
    dd = lib.hci_open_dev(HCI_DEV)
    if dd < 0:
        err = ctypes.get_errno()
        print("hci_open_dev(%d): %s" % (HCI_DEV, os.strerror(err)), file=sys.stderr)
        sys.exit(1)
    try:
        for handle, addr, ctype, state in get_connections(lib, dd):
            mark = "  <-- keyboard" if addr.upper() == KB_ADDR.upper() else ""
            print("handle=0x%04x addr=%s type=%d state=0x%04x%s"
                  % (handle, addr, ctype, state, mark))
    finally:
        lib.hci_close_dev(dd)


def cmd_watch():
    require_root()
    require_addr()
    import dbus
    import dbus.mainloop.glib
    from gi.repository import GLib

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    target_path = "/org/bluez/hci%d/dev_" % HCI_DEV + KB_ADDR.replace(":", "_")
    pending = {"id": None}

    def schedule(delay_s, label):
        if pending["id"] is not None:
            return
        def fire():
            pending["id"] = None
            try:
                rc = apply_once(verbose=True)
                print("apply (%s) rc=%d" % (label, rc), flush=True)
            except Exception as e:
                print("apply (%s) failed: %s" % (label, e), flush=True)
            return False
        pending["id"] = GLib.timeout_add(int(delay_s * 1000), fire)

    def on_props(interface, changed, invalidated=None, path=None):
        if path != target_path or interface != "org.bluez.Device1":
            return
        if "Connected" in changed and bool(changed["Connected"]):
            print("keyboard connected, scheduling override", flush=True)
            schedule(4.0, "after-connect")
            GLib.timeout_add(12000, lambda: (schedule(0.1, "reassert"), False)[1])

    bus.add_signal_receiver(
        on_props,
        dbus_interface="org.freedesktop.DBus.Properties",
        signal_name="PropertiesChanged",
        arg0="org.bluez.Device1",
        path_keyword="path",
    )

    try:
        dev = bus.get_object("org.bluez", target_path)
        props = dbus.Interface(dev, "org.freedesktop.DBus.Properties")
        if bool(props.Get("org.bluez.Device1", "Connected")):
            print("keyboard already connected at startup", flush=True)
            schedule(1.0, "startup")
    except Exception as e:
        print("startup check: %s" % e, flush=True)

    print("watching for %s ..." % KB_ADDR, flush=True)
    GLib.MainLoop().run()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    {
        "apply": cmd_apply,
        "status": cmd_status,
        "watch": cmd_watch,
    }.get(sys.argv[1], lambda: (print(__doc__), sys.exit(1)))()
PYEOF

chmod 0755 "$PY"

# ------------------------------------------------------------- write service
cat > "$UNIT" <<EOF
[Unit]
Description=Force latency 0 on the Dexnor BLE keyboard connection
After=bluetooth.service
Wants=bluetooth.service

[Service]
Type=simple
ExecStart=$PY watch
Restart=always
RestartSec=3
Environment=KB_ADDR=$KB_ADDR
Environment=HCI_DEV=$HCI_DEV
Environment=BT_MIN_INTERVAL=$BT_MIN_INTERVAL
Environment=BT_MAX_INTERVAL=$BT_MAX_INTERVAL
Environment=BT_LATENCY=$BT_LATENCY
Environment=BT_SUPV_TIMEOUT=$BT_SUPV_TIMEOUT

[Install]
WantedBy=multi-user.target
EOF

# ------------------------------------------------- fix BlueZ stored parameters
KB_ADDR="$KB_ADDR" BT_MIN_INTERVAL="$BT_MIN_INTERVAL" \
BT_MAX_INTERVAL="$BT_MAX_INTERVAL" BT_LATENCY="$BT_LATENCY" \
BT_SUPV_TIMEOUT="$BT_SUPV_TIMEOUT" python3 - <<'PYEOF'
import os
import re
import shutil

addr = os.environ["KB_ADDR"]
want = {
    "MinInterval": os.environ["BT_MIN_INTERVAL"],
    "MaxInterval": os.environ["BT_MAX_INTERVAL"],
    "Latency": os.environ["BT_LATENCY"],
    "Timeout": os.environ["BT_SUPV_TIMEOUT"],
}

paths = []
for root, _dirs, files in os.walk("/var/lib/bluetooth"):
    if os.path.basename(root) == addr and "info" in files:
        paths.append(os.path.join(root, "info"))

for path in paths:
    text = open(path).read()
    bak = path + ".bak-dexnor-fix"
    if not os.path.exists(bak):
        shutil.copyfile(path, bak)
    lines = text.splitlines()
    out = []
    in_sec = False
    seen = False
    done = set()

    def flush():
        for k, v in want.items():
            if k not in done:
                out.append("%s=%s" % (k, v))
                done.add(k)

    for line in lines:
        if line.strip().startswith("["):
            if in_sec:
                flush()
            in_sec = line.strip() == "[ConnectionParameters]"
            seen = seen or in_sec
            out.append(line)
            continue
        if in_sec:
            m = re.match(r"^(\w+)=(.*)$", line)
            if m and m.group(1) in want:
                out.append("%s=%s" % (m.group(1), want[m.group(1)]))
                done.add(m.group(1))
                continue
        out.append(line)
    if in_sec:
        flush()
    if not seen:
        out.append("[ConnectionParameters]")
        for k, v in want.items():
            out.append("%s=%s" % (k, v))
    open(path, "w").write("\n".join(out) + "\n")
    print("updated %s" % path)
PYEOF

# ------------------------------------------------------------------- activate
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null
systemctl restart "$SERVICE"

# Apply once right now (service also does this, but make it immediate).
sleep 1
"$PY" apply || true

echo
echo "== service =="
systemctl is-enabled "$SERVICE"
systemctl is-active "$SERVICE"
echo
echo "== logs =="
journalctl -u "$SERVICE" -n 12 --no-pager
echo
echo "Done. Check status any time with:"
echo "  sudo journalctl -u $SERVICE -f"
echo "  sudo KB_ADDR=$KB_ADDR $PY status"
