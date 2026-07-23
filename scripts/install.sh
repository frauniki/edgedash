#!/bin/bash
# Build Release and install to /Applications (the only copy that should ever
# be launched outside development — stale DerivedData builds otherwise get
# reopened by macOS login-window restoration).
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen
# Build must hard-fail before install — never ship a stale bundle.
BUILD_LOG=$(mktemp)
if ! xcodebuild -project EdgeDash.xcodeproj -scheme EdgeDash -configuration Release \
    -destination 'platform=macOS' build > "$BUILD_LOG" 2>&1; then
    grep -E "error:" "$BUILD_LOG" || tail -20 "$BUILD_LOG"
    echo "BUILD FAILED — not installing." >&2
    exit 1
fi
grep -E "BUILD" "$BUILD_LOG" | tail -1

DERIVED=$(xcodebuild -project EdgeDash.xcodeproj -scheme EdgeDash -configuration Release \
    -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3; exit}')

pkill -x EdgeDash || true
rm -rf /Applications/EdgeDash.app
cp -R "$DERIVED/EdgeDash.app" /Applications/EdgeDash.app
open /Applications/EdgeDash.app
echo "Installed and launched /Applications/EdgeDash.app"
