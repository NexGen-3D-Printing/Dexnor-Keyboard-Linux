# Dexnor touchpad: physical click fix

Fix the physical touchpad click on a Dexnor Bluetooth keyboard/touchpad
combo under Linux (tested on Fedora 44 KDE, kernel 7.2.x, Surface Pro 9).

## The problem

Pressing the touchpad until it clicks does nothing until the finger is
moved slightly. Tap-to-click works normally.

## Root cause

The touchpad reports its physical button as **bit 0 of the last byte of HID
report 6** (the Digitizer/TouchPad report). The kernel maps that bit to
`BTN_LEFT`.

The firmware sets the bit when the button is pressed, but **never clears it
when the button is released**. The bit stays `1` until the first report of
the *next* touch. Captured on the wire:

```
913.572686  count=1  btn=1   finger lifting
913.579631  count=0  btn=1   contact ended, button STILL 1
913.587630  count=0  btn=1   last report, button STILL 1
   ... 7.2 seconds of silence ...
920.757830  count=1  btn=0   next touch finally clears it
920.787562  count=1  btn=1   then presses again
```

Most toolkits act on button **release**. Because the release never arrives,
the click only completes when the next touch clears the latched bit — which
is why moving the finger makes it work.

Windows is unaffected because its HID stack does not rely on this bit the
same way.

## The fix

A small daemon:

1. Finds the real touchpad (`Dexnor Keyboard Touchpad`, sysfs path under
   `/sys/devices/virtual/misc/uhid/`).
2. Grabs it and forwards every event unchanged to a **uinput clone** with
   the same name, IDs and `INPUT_PROP_BUTTONPAD` property.
3. When the last contact ends (`BTN_TOUCH=0`), if `BTN_LEFT` is still held,
   it synthesises the missing `BTN_LEFT=0`.

The result: press → button down, lift → button up. Drag, two-finger
right-click and scrolling are unaffected. Tap-to-click is untouched because
libinput generates it from touch events and never uses `BTN_LEFT`.

Installed components:

| Path | Purpose |
|---|---|
| `/usr/local/sbin/dexnor-touchpad-click.py` | the daemon |
| `/etc/systemd/system/dexnor-touchpad-click.service` | starts it at boot, restarts on reconnect |

## Install

From the repo root:

```bash
mkdir -p ~/.local/Dexnor-Keyboard-Fix && curl -fsS https://raw.githubusercontent.com/NexGen-3D-Printing/Dexnor-Keyboard-Linux/main/touchpad/install.sh -o ~/.local/Dexnor-Keyboard-Fix/touchpad/install.sh -L && chmod +x ~/.local/Dexnor-Keyboard-Fix/touchpad/install.sh && ~/.local/Dexnor-Keyboard-Fix/touchpad/install.sh
```

Re-running is safe and idempotent. It also works on a second machine with
the same keyboard.

If the evdev name differs, override it:

```bash
TOUCHPAD_NAME="Some Other Touchpad" ~/.local/Dexnor-Keyboard-Fix/touchpad/install.sh
```

## Verify

```bash
systemctl status dexnor-touchpad-click.service
sudo journalctl -u dexnor-touchpad-click.service -f
```

A successful start logs:

```
virtual device: /dev/input/eventXX
grabbed /dev/input/eventYY (Dexnor Keyboard Touchpad)
```

KWin should then show the virtual node in its log, e.g.:

```
kwin_wayland: Libinput: eventXX - Dexnor Keyboard Touchpad: ...
```

Test:

1. Press the pad until it clicks, release without moving — the click should
   fire immediately.
2. Tap-to-click still works.
3. Two-finger right-click still works.
4. Two-finger scroll still works.

## Uninstall

```bash
sudo ./touchpad/install.sh --uninstall
```

The original touchpad is ungrabbed as soon as the service stops, so the
previous behaviour returns immediately.

## Notes

- While the service runs, two "Dexnor Keyboard Touchpad" entries can appear
  in input listings. The original is grabbed and silent; the virtual clone
  is the one the desktop uses. They have the same name/IDs, so KDE applies
  the same settings to the clone.
- Device nodes change on reconnect. The daemon re-scans by name and sysfs
  path, and systemd restarts it if it exits.
- Debug in the foreground with:
  ```bash
  sudo systemctl stop dexnor-touchpad-click.service
  sudo /usr/local/sbin/dexnor-touchpad-click.py --verbose
  ```
- If a future kernel or BlueZ update changes the report layout, the daemon
  still works as long as the touchpad exposes `BTN_LEFT` and `BTN_TOUCH` on
  its evdev node.
