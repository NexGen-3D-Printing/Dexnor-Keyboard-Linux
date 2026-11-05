# Dexnor Bluetooth keyboard: dropped keystrokes fix

Permanent workaround for randomly dropped keys on a Dexnor HID-over-GATT
keyboard under Linux/BlueZ (tested on Fedora 44 KDE, kernel 7.2.x,
BlueZ 5.87, Surface Pro 9).

## The problem

The keyboard advertises these **PPCP** (Preferred Peripheral Connection
Parameters, GATT characteristic `0x2A04`):

| Parameter | Value | Meaning |
|---|---|---|
| Min connection interval | 6 | 7.5 ms |
| Max connection interval | 6 | 7.5 ms |
| Latency | 35 | may skip 35 of 36 events |
| Supervision timeout | 200 | 2000 ms |

BlueZ 5.76+ reads PPCP in `profiles/gap/gas.c:read_ppcp_cb()` and applies
it via `btd_device_set_conn_param()`. Latency 35 is legal, so it is
accepted. That gives the keyboard a ~270 ms window between chances to
deliver a HID report, so fast typing loses press/release events.

Windows ignores PPCP, which is why the same keyboard works perfectly
there. It is a Linux/BlueZ behaviour, not a hardware or firmware fault.

## The fix

Force **latency 0** on the live LE connection, keeping the keyboard's own
7.5 ms interval so the peripheral accepts the request:

```
min=6 (7.5 ms)  max=6 (7.5 ms)  latency=0  timeout=200 (2 s)
```

Installed components:

1. `/usr/local/sbin/bt-keyboard-latency.py`
   - `apply`  – override the current connection once
   - `status` – list LE connections and the keyboard handle
   - `watch`  – resident daemon; re-applies on every connect
2. `/etc/systemd/system/bt-keyboard-latency.service`
   - runs `watch`, enabled at boot, restarts on failure
3. `[ConnectionParameters]` in the BlueZ device info file
   - `MinInterval=6`, `MaxInterval=6`, `Latency=0`, `Timeout=200`
   - so the boot-time default is sane too
   - a backup is written next to it as `info.bak-dexnor-fix`

## Install

Pair the keyboard first, then from the repo root:

```bash
sudo ./keyboard/install.sh
```

The script auto-detects the controller, the keyboard address and the HCI
index. Re-running it is safe (idempotent) and is the intended way to
restore the fix after an OS reinstall.

If detection fails, pass the address explicitly:

```bash
sudo KB_ADDR=AA:BB:CC:DD:EE:FF ./keyboard/install.sh
```

Optional overrides (environment variables):

```bash
sudo BT_MAX_INTERVAL=12 ./keyboard/install.sh   # 15 ms polling, lower battery use
```

## Verify

```bash
systemctl status bt-keyboard-latency.service
sudo journalctl -u bt-keyboard-latency.service -f
sudo /usr/local/sbin/bt-keyboard-latency.py status
```

A successful apply logs:

```
OK: latency 0, worst-case poll 7.50 ms
```

You can also prove it on the wire:

```bash
sudo btmon | grep -A8 'LE Connection Update'
# Connection latency: 0 (0x0000)
```

## Uninstall

```bash
sudo ./keyboard/install.sh --uninstall
```

This removes the service and the daemon. The `[ConnectionParameters]`
entry in the BlueZ info file is left in place; delete that section
manually for a fully stock setup.

## Notes / troubleshooting

- **Pair before installing.** On a fresh OS install, pair the keyboard,
  then run the script so it can detect the address and write the info file.
- If the address changes after re-pairing, just re-run the script.
- If the controller rejects the parameters, `apply` prints the errno.
  Try `BT_MAX_INTERVAL=12 BT_SUPV_TIMEOUT=400`.
- Battery: latency 0 means the keyboard can no longer skip connection
  events, so power use rises slightly. The interval is unchanged
  (7.5 ms), which is what the keyboard itself requested.
- The script needs `python3`, `python3-dbus`, `python3-gobject` and
  `libbluetooth` (all present on a normal Fedora KDE install).
