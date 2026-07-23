# EdgeDash

Native macOS dashboard for the Corsair XENEON EDGE (14.5″ 2560×720 touchscreen) —
iStat Menus-style system monitoring with real touch support, no iCUE required.

macOS sees the EDGE as a regular external display; EdgeDash renders a
borderless dashboard onto it and reads the touch digitizer (VID 0x27C0 /
PID 0x0859) directly over HID, so tapping never moves your cursor or steals
focus. Apple Silicon, macOS 15+.

## Status

Early development. Milestones: see `docs/` (plan) — currently at **M0
(scaffold)** / **M0.5 (touch seize spike)**.

## Building

```sh
brew install xcodegen
xcodegen                       # generates EdgeDash.xcodeproj (gitignored)
xcodebuild -project EdgeDash.xcodeproj -scheme EdgeDash build
```

Package logic is developed and tested without Xcode:

```sh
swift test --package-path EdgeDashKit
```

## Touch seize spike (M0.5)

Validates that all three HID interfaces of the touch controller (digitizer,
boot mouse, vendor) can be seized with only the Input Monitoring permission:

```sh
swift run --package-path EdgeDashKit touch-spike
```

Grant Input Monitoring to your terminal when prompted, touch the EDGE panel,
and check for `PASS` on Ctrl+C.
