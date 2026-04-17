#!/bin/bash
# release-all.sh — Build a universal (arm64 + x86_64) Gridex release via lipo.
#
# Usage:
#   ./scripts/release-all.sh
#
# Produces:
#   dist/Gridex-<version>-universal.dmg
#
# Flow:
#   1. Build arm64 .app bundle (unsigned, frameworks embedded)
#   2. Swift cross-compile x86_64 executable
#   3. lipo both executables → universal binary inside the .app
#   4. Sign + notarize the universal .app
#   5. Package + sign + notarize DMG

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_DIR/macos/Resources/Info.plist")
APP_BUNDLE="$PROJECT_DIR/dist/Gridex.app"

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║      Gridex — Universal Release           ║"
echo "╚═══════════════════════════════════════════╝"
echo "  Version: $VERSION"
echo ""

# 1. Build arm64 .app bundle (no sign yet — we lipo first)
echo "━━━ Step 1: Build arm64 .app (unsigned) ━━━"
echo ""
ARCH=arm64 SKIP_SIGN=1 "$SCRIPT_DIR/build-app.sh" release

ARM64_BIN="$PROJECT_DIR/.build/arm64-apple-macosx/release/Gridex"
if [ ! -f "$ARM64_BIN" ]; then
    echo "✗ arm64 executable not found: $ARM64_BIN"
    exit 1
fi

# 2. Cross-compile x86_64 executable
echo ""
echo "━━━ Step 2: Cross-compile x86_64 executable ━━━"
echo ""
swift build -c release --arch x86_64 --package-path "$PROJECT_DIR" 2>&1 | tail -3

X86_BIN="$PROJECT_DIR/.build/x86_64-apple-macosx/release/Gridex"
if [ ! -f "$X86_BIN" ]; then
    echo "✗ x86_64 executable not found: $X86_BIN"
    exit 1
fi

# 3. Merge into universal binary
echo ""
echo "━━━ Step 3: lipo → universal binary ━━━"
echo ""
lipo -create \
    "$ARM64_BIN" \
    "$X86_BIN" \
    -output "$APP_BUNDLE/Contents/MacOS/Gridex"
echo "✓ Universal binary:"
lipo -info "$APP_BUNDLE/Contents/MacOS/Gridex"

# 4. Sign + notarize the universal .app
echo ""
echo "━━━ Step 4: Sign + Notarize .app ━━━"
echo ""
# runtime.entitlements was left in dist/ by build-app.sh (SKIP_SIGN=1)
"$SCRIPT_DIR/sign-notarize.sh" "$APP_BUNDLE"

# 5. Package + sign + notarize DMG (named -universal)
echo ""
echo "━━━ Step 5: Package universal DMG ━━━"
echo ""
ARCH=universal "$SCRIPT_DIR/make-dmg.sh"

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║  ✓ Universal release complete             ║"
echo "╚═══════════════════════════════════════════╝"
echo ""
echo "Artifacts:"
ls -lh "$PROJECT_DIR/dist/"*.dmg 2>/dev/null || true

echo ""
echo "Next: generate Sparkle appcast and upload to R2"
echo "  ./scripts/publish.sh"
