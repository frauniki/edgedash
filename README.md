# EdgeDash

> iStat Menus-style dashboard for the Corsair XENEON EDGE, with real touch.

[![CI](https://github.com/frauniki/edgedash/actions/workflows/ci.yml/badge.svg)](https://github.com/frauniki/edgedash/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-MIT-blue)
![Swift](https://img.shields.io/badge/swift-6.0-F05138?logo=swift&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white)
![Localized](https://img.shields.io/badge/lang-EN%20%C2%B7%20%E6%97%A5%E6%9C%AC%E8%AA%9E-8A2BE2)

Native macOS dashboard for the Corsair XENEON EDGE (14.5″ 2560×720 touch
strip) — iStat Menus-style system monitoring with real touch support, no iCUE
required.

macOS sees the EDGE as a regular external display. EdgeDash renders a
borderless dashboard onto it and reads the touch controller directly over HID,
so tapping the panel never moves your cursor or steals focus from what you're
doing. Runs as a menu-bar app.

## Features

**Widgets** — each in multiple grid sizes (1×1 up to 4×2), with per-widget
options:

| Widget | Shows |
|---|---|
| CPU | usage, user/system histogram, per-core rings, load average, uptime, top processes |
| Memory | pressure ring, App/Wired/Compressed breakdown, swap, top processes |
| GPU | utilization history, GPU memory |
| Disk | capacity ring per volume, read/write rates |
| Network | mirrored up/down rate graph, interface / IPv4 / IPv6 / public IP, peak rates |
| Sensors | temperatures, core clocks, package power, fan RPM (Apple Silicon SMC/IOReport) |
| Fans | RPM bars |
| Power | system power draw history |
| Clock | time and date |
| Now Playing | Apple Music transport — artwork, seek bar, volume, shuffle/repeat |
| Weather | current conditions, 24 h temperature/precipitation graph, 7-day forecast ([Open-Meteo](https://open-meteo.com/), current location or a fixed city) |
| Claude Code | live session states across projects, plan limit gauges, today's tokens, 30-day cost estimate |

**Touch** — the EDGE's HID interfaces are captured exclusively (Input
Monitoring permission, no root): tap, long-press, pan and swipe work on the
panel itself. Swipe between dashboard pages, scroll lists, drag seek/volume
sliders — the macOS cursor never moves.

**Layout** — multiple pages, edited in Settings on a live to-scale miniature
with drag-and-drop placement. Per-widget card background toggle. All layout is
resolution-independent.

**Appearance** — themes (Graphite, Aurora) with glow-styled charts; optional
wallpaper show-through with adjustable opacity and blur.

**Localized** — English and 日本語 (follows the system language; per-app
override available in System Settings › Language & Region).

Configuration lives in
`~/Library/Application Support/EdgeDash/config.json` and hand-edits are
picked up live.

## Requirements

- Apple Silicon Mac, macOS 15+
- Corsair XENEON EDGE, connected as a display plus its USB cable (touch).
  Any other display can host the dashboard too via Settings › Display —
  touch capture is EDGE-specific.

## Install

```sh
brew install xcodegen
scripts/install.sh   # Release build → /Applications/EdgeDash.app, launches it
```

On first use EdgeDash asks for the permissions it needs, all optional except
the first:

| Permission | Used for |
|---|---|
| Input Monitoring | touch capture |
| Automation (Music) | Now Playing widget |
| Location Services | Weather widget's current-location mode (a fixed city works without it) |

## Development

All logic lives in the `EdgeDashKit` Swift package and is developed and
tested without Xcode:

```sh
swift test --package-path EdgeDashKit
```

| Module | Responsibility |
|---|---|
| EdgeCore | config store, themes, metric/device model types |
| EdgeMetrics | CPU / memory / disk / network / GPU readers |
| SMCBridge | temperatures, fans, power, core clocks (AppleSMC, IOHIDEventSystem, IOReport) |
| EdgeDisplay | display detection, hot-plug, dashboard window placement |
| EdgeTouch | HID seizure, gesture recognition, touch routing |
| WidgetEngine | widget registry, grid renderer, canvas components, service locator |
| BuiltinWidgets / MediaWidgets / AgentWidgets / WeatherWidgets | the widgets |
| SettingsUI | settings window |

The thin app shell (menu bar, app model) is in `EdgeDash/`; `xcodegen`
generates the Xcode project from `project.yml`.

Useful launch arguments for UI work: `--settings` opens the settings window
at launch, `--pane <Name>` selects a pane, `--select-widget <name>`
preselects a widget in the placement inspector — handy for scripted
screenshots. `swift run --package-path EdgeDashKit touch-spike` is a
standalone probe that validates HID touch seizure.

## Acknowledgements

- [exelban/stats](https://github.com/exelban/stats) — reference for many
  macOS metric-reading techniques
- [Open-Meteo](https://open-meteo.com/) — weather data
  ([CC BY 4.0](https://creativecommons.org/licenses/by/4.0/))
- Not affiliated with or endorsed by Corsair. XENEON is a trademark of
  Corsair Memory, Inc.

## License

[MIT](LICENSE)
