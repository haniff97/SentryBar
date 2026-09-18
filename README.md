# SentryBar

A lightweight macOS **menu-bar utility** for keeping an eye on your Mac and
controlling the things you reach for most — all from one icon in the menu bar.

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)

## What it does

**System tab**
- CPU usage (hottest core) + per-core load bars, and live history graphs
- GPU temperature
- Memory usage (used / total)
- Battery: charge %, charging state, health, cycle count
- Fan RPM and CPU temperature badges

**Display tab**
- Per-display brightness sliders
  - Apple displays → real hardware brightness
  - Other monitors → a software dimming overlay (works on any screen)
  - Levels are **remembered per display** and restored on launch
- **Lid Closed Mode** — keep the Mac running (not sleeping) with the lid shut

**Keyboard tab**
- **Keyboard Lock** — disable all keyboard input while you clean the Mac
  (mouse stays usable so you can unlock). Safety: auto-unlock timer, 5× Esc,
  and the lock releases if the app quits.

**Also**
- Menu-bar content options (icon only, CPU %, temp, temp + fan)
- Launch at login
- Built-in updater (Settings → Updates)

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon recommended (developed/tested on an M1 Pro). Intel Macs will
  work for monitoring, but some features differ.
- Admin password for **fan control** and **Lid Closed Mode** (one prompt per toggle)

## Install

### From the DMG (recommended)

1. Download **`SentryBar.dmg`** from the [Releases](../../releases) page.
2. Open the DMG and drag **SentryBar.app** onto the **Applications** shortcut.
3. Launch **SentryBar** from `/Applications`.

Because the app is **ad-hoc signed (not notarized)**, macOS may block the first
launch. If so, either:
- Right-click the app → **Open** → **Open**, or
- System Settings → **Privacy & Security** → scroll down → **Open Anyway**, or
- Run once in Terminal:
  ```bash
  xattr -cr /Applications/SentryBar.app
  ```

### With Homebrew

```bash
brew tap haniff97/sentrybar https://github.com/haniff97/SentryBar
brew install --cask sentrybar
```

(The cask lives in `Casks/sentrybar.rb`. If Homebrew complains the app is
damaged/unidentified, run the `xattr -cr` command above.)

### First-run notes

- **Fan control** needs a privileged helper. Open **Settings → Privileged
  Helper → Install / Launch Helper**; macOS will ask for your admin password
  **once** (this is what lets SentryBar write to the SMC). It's off until you do.
- **Lid Closed Mode** is **off by default** (it carries a thermal risk — see below).
- **Charge limit**: the battery card links to macOS's native charge setting
  (80% is a good default).
- **Advanced options** (per-core load, manual fan RPM, fan linking) are hidden
  until you enable **Settings → General → Show advanced options**, so the main
  view stays simple.

### Permissions (only needed for Keyboard Lock)

To block keys, SentryBar needs **both**:
- **Accessibility** → System Settings → Privacy & Security → Accessibility
- **Input Monitoring** → System Settings → Privacy & Security → Input Monitoring

Add `/Applications/SentryBar.app` to each and enable it, then **quit and reopen**
the app (macOS only applies these grants after a relaunch).

## Build from source

Requires the Swift toolchain / Xcode Command Line Tools.

```bash
git clone https://github.com/haniff97/SentryBar.git
cd SentryBar

# Run directly (development)
swift run SystemMonitor

# Print all sensor readings (CLI)
swift run SystemMonitor --test

# Build the packaged .app
./scripts/make-app.sh        # -> dist/SentryBar.app
open dist/SentryBar.app

# Build the DMG installer
./scripts/make-dmg.sh        # -> dist/SentryBar.dmg (+ prints SHA-256)
```

## How it works (short version)

- **Sensors** are read from the Apple **SMC** (fans, temperatures) and the Mach
  kernel (CPU, memory); battery via IOKit.
- **Fan writes require root**, so a small privileged helper (`FanHelper`) is
  launched once via an admin prompt and serves writes over a local socket.
- **Display brightness** uses the private `CoreDisplay` framework for Apple
  panels, and a black overlay window for everything else.
- **Keyboard Lock** uses a system-wide `CGEventTap` that swallows key events.

## Notes & limitations

- Fan control **overrides Apple's thermal management** — use it at your own risk;
  macOS may take control back.
- Software brightness is an overlay, so it appears in screen recordings and dims
  the menu bar too.
- Some features rely on **private/undocumented APIs** and may break on future
  macOS updates.
- The app is ad-hoc signed for local use; distribution builds would need a
  Developer ID + notarization.

## License

Personal project — see the repository for details.
