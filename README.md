# Dexnor keyboard/touchpad — Linux fixes

Two small, self-contained fixes for the Dexnor Bluetooth keyboard/touchpad
combo (HID-over-GATT) under Linux:

| Fix | Symptom | Root cause |
|---|---|---|
| [Keyboard latency](keyboard/) | Randomly dropped keystrokes | BlueZ applies the keyboard's PPCP latency of 35, letting it skip 35 of 36 connection events (~270 ms gap) |
| [Touchpad click](touchpad/) | Physical click only registers after moving the finger | Firmware latches `BTN_LEFT` and never sends a release; the kernel clears it only on the next touch |

Both fixes are userspace, idempotent, and survive reboots. They do not patch
the kernel or BlueZ.

## The device

[![Dexnor Magic-Style Keyboard Case for Microsoft Surface Pro 9](docs/images/dexnor-surface-pro-9.jpg)][product]

The [Dexnor Magic-Style Keyboard Case for Microsoft Surface Pro 9][product] is
a Bluetooth HID-over-GATT keyboard with a multi-touch trackpad. It presents as
HID `05AC:0220`; these fixes target its keyboard and touchpad.

*Product image © Dexnor, used here to identify the hardware. It is not covered
by this repository's MIT license.*

## Tested on

- Fedora 44 KDE
- Bazzite 45
- BlueZ 5.87
- Surface Pro 9
- Dexnor Bluetooth keyboard/touchpad combo (HID `05AC:0220`)

The same device works perfectly on Windows 11; these are Linux-stack issues,
not hardware faults.

## Quick start

### Install with one command (recommended)

Pair the keyboard first, then run:

```bash
mkdir -p ~/.local/Dexnor-Keyboard-Fix && curl -fsS https://raw.githubusercontent.com/NexGen-3D-Printing/Dexnor-Keyboard-Linux/main/install.sh -o ~/.local/Dexnor-Keyboard-Fix/install.sh -L && chmod +x ~/.local/Dexnor-Keyboard-Fix/install.sh && ~/.local/Dexnor-Keyboard-Fix/install.sh
```

The installer will:

1. Prompt for your sudo password
2. Install both the keyboard and touchpad fixes
3. Disable Bluetooth runtime power management for improved connection stability
4. Configure a 4-second supervision timeout (increased from 2s)
5. Verify both services are running

### Install only one fix

```bash
~/.local/Dexnor-Keyboard-Fix/keyboard/install.sh
~/.local/Dexnor-Keyboard-Fix/touchpad/install.sh
```

### Install with Bluetooth power management disabled

To skip Bluetooth power management optimization:

```bash
DISABLE_BLUETOOTH_PM=1 ~/.local/Dexnor-Keyboard-Fix/install.sh
```

## Uninstall

Remove all fixes:

```bash
~/.local/Dexnor-Keyboard-Fix/keyboard/install.sh --uninstall
~/.local/Dexnor-Keyboard-Fix/touchpad/install.sh --uninstall
```

## Verify

```bash
systemctl status bt-keyboard-latency.service
systemctl status dexnor-touchpad-click.service
```

Expected:

```
bt-keyboard-latency.service        enabled/active
dexnor-touchpad-click.service      enabled/active
```

Keyboard on the wire:

```bash
sudo btmon | grep -A8 'LE Connection Update'
# Connection latency: 0 (0x0000)
```

Touchpad: press the pad until it clicks and release without moving — the
click should fire immediately.

## How it was diagnosed

See [docs/diagnosis.md](docs/diagnosis.md) for the HID report layout,
`btmon` captures, and the evdev timelines that led to each fix.

## Requirements

- Fedora/KDE (tested); should work on any Linux with systemd, BlueZ and
  libinput.
- `python3`
- Keyboard fix: `python3-dbus`, `python3-gobject`, `libbluetooth`
- Touchpad fix: `python3-evdev`, `/dev/uinput`

On Fedora:

```bash
sudo dnf install python3-dbus python3-gobject python3-evdev
```

## Bluetooth power management

For improved connection stability, the installer disables runtime power
management for the Bluetooth adapter:

- Sets `/sys/class/bluetooth/hci0/power/control` to `on`
- Increases supervision timeout from 2s to 4s

To skip this optimization:

```bash
DISABLE_BLUETOOTH_PM=1 ~/.local/Dexnor-Keyboard-Fix/install.sh
```

## Notes / caveats

- The touchpad fix creates a uinput clone. While it runs, input listings
  show two "Dexnor Keyboard Touchpad" devices; the original is grabbed and
  silent, the clone is active. KDE applies the same settings to both.
- The keyboard fix writes `Latency=0` into the BlueZ device info file and
  keeps a backup at `info.bak-dexnor-fix`.
- Uninstalling the keyboard fix leaves the `[ConnectionParameters]` section
  in place; remove it manually for a fully stock setup.
- Re-run `~/.local/Dexnor-Keyboard-Fix/install.sh` after an OS reinstall or
  a BlueZ/kernel update that changes behavior.

## License

MIT — see [LICENSE](LICENSE).

The product image in `docs/images/` is © Dexnor and is not covered by the MIT
license; it is included only to identify the hardware.

[product]: https://www.dexnorcase.com/products/dexnor-magic-style-keyboard-case-for-microsoft-surface-pro-9-with-detachable-magnetic-cover-floating-cantilever-stand-multi-touch-trackpad-backlit-stylus-holder
