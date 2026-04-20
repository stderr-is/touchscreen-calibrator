# Touchscreen Calibrator for Linux Mint / X11

A simple, interactive tool to calibrate USB touchscreens (like the iggual 82") on Linux Mint machines with projectors. Designed for environments with multiple similar computers (e.g., classrooms, academies).

## Quick Start

```bash
# On the machine you want to calibrate:
./calibrate.sh
```

That's it. The script will:
1. Auto-detect the touchscreen device
2. Auto-detect the display output
3. Launch `xinput_calibrator` — tap the 4 crosshairs
4. Let you test the result
5. Make it permanent (survives reboots)

## Requirements

- Linux Mint (or any X11-based distro with Cinnamon/MATE/XFCE)
- `xinput_calibrator` — install with: `sudo apt install xinput-calibrator`
- `xinput` — usually pre-installed
- `bc` — usually pre-installed

## Usage

```bash
./calibrate.sh          # Interactive calibration + install
./calibrate.sh --apply  # Re-apply saved calibration (no recalibration)
./calibrate.sh --remove # Remove all calibration config
./calibrate.sh --help   # Show help
```

## How It Works

1. **Detection** — finds touchscreen via `xinput` and display via `xrandr`
2. **Calibration** — runs `xinput_calibrator` to get raw min/max values
3. **Conversion** — converts the evdev-style values into a libinput CalibrationMatrix (most touchscreens on modern distros use the libinput driver)
4. **Persistence** — installs the calibration in two ways:
   - `~/.config/autostart/` entry (no root needed, applies on login)
   - `/etc/X11/xorg.conf.d/99-touchscreen-calibration.conf` (root needed, applies at X startup)

## Multi-Machine Setup

Each machine's calibration is saved in `calibrations/<hostname>.conf`. You can:

1. Calibrate each machine individually
2. Copy this project folder to each machine (USB stick, network share, etc.)
3. Or keep it in a shared location and run from there

If all machines have identical hardware/projectors and the same screen alignment, you can copy one machine's `.conf` file to another and run `./calibrate.sh --apply`.

## Troubleshooting

### Touch is still wrong after calibration
- Make sure you're tapping precisely on the crosshairs
- Run `./calibrate.sh` again — it will overwrite the previous calibration

### "No touchscreen devices found"
- Check USB cable connection
- Run `xinput list` to see all input devices
- Some touchscreens need drivers — check `dmesg | grep -i touch`

### Calibration works now but resets after reboot
- Run `./calibrate.sh` again and authenticate when prompted (for the xorg.conf.d install)
- Or manually: `sudo cp calibrations/$(hostname).conf.xorg /etc/X11/xorg.conf.d/99-touchscreen-calibration.conf`

## Project Structure

```
touchscreen-calibrator/
├── calibrate.sh           # Main script — run this
├── apply-calibration.sh   # Auto-generated per-machine apply script
├── calibrations/          # Saved calibration data per hostname
│   └── <hostname>.conf
└── README.md
```

## Tested With

- Linux Mint 21/22 (Cinnamon)
- iggual 82" touchscreen (Touch p403, USB)
- VGA/HDMI projectors
- libinput driver

## License

MIT — use freely in your academy or anywhere else.
