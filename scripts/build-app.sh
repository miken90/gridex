#!/bin/bash
# build-app.sh — Build Gridex.app bundle from SPM executable.
#
# Usage:
#   ./scripts/build-app.sh            # Debug build (ad-hoc sign, quick local run)
#   ./scripts/build-app.sh release    # Release: build + sign + notarize + staple + verify
#   NOTARIZE=0 ./scripts/build-app.sh release   # Release, skip notarization
#   ARCH=x86_64 ./scripts/build-app.sh release  # Cross-compile for Intel
#
# Env (release mode):
#   SIGN_IDENTITY    SHA-1 or name of Developer ID cert (default pinned to 16/4/26 cert)
#   NOTARY_PROFILE   notarytool keychain profile (default: gridex-notarize)
#   NOTARIZE         0 to skip notarization (useful while iterating locally)
#   ARCH             arm64 | x86_64 (default: host uname -m)

set -euo pipefail

MODE="${1:-debug}"
APP_NAME="Gridex"
BUNDLE_ID="com.gridex.app"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCES_DIR="$PROJECT_DIR/macos/Resources"
INFO_PLIST="$RESOURCES_DIR/Info.plist"
ICON="$RESOURCES_DIR/AppIcon.icns"
XCASSETS="$RESOURCES_DIR/Assets.xcassets"
NOTARIZE="${NOTARIZE:-1}"
ARCH="${ARCH:-$(uname -m)}"
SKIP_SIGN="${SKIP_SIGN:-0}"

# 1. Build
echo "→ Building ($MODE, $ARCH)..."
ARCH_FLAGS=(--arch "$ARCH")
if [ "$MODE" = "release" ]; then
    swift build -c release --package-path "$PROJECT_DIR" "${ARCH_FLAGS[@]}" 2>&1 | tail -3
    BUILD_DIR="$PROJECT_DIR/.build/release"
else
    swift build --package-path "$PROJECT_DIR" "${ARCH_FLAGS[@]}" 2>&1 | tail -3
    BUILD_DIR="$PROJECT_DIR/.build/debug"
fi

EXECUTABLE="$BUILD_DIR/$APP_NAME"
if [ ! -f "$EXECUTABLE" ]; then
    echo "✗ Build failed — executable not found at $EXECUTABLE"
    exit 1
fi

# 2. Create .app bundle structure
OUTPUT_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES"

# 3. Copy executable
cp "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"

# 4. Copy Info.plist
cp "$INFO_PLIST" "$CONTENTS/Info.plist"

# 5. Copy icon
if [ -f "$ICON" ]; then
    cp "$ICON" "$RESOURCES/AppIcon.icns"
fi

# 6. Compile Asset Catalog → Assets.car + AppIcon.icns
if [ -d "$XCASSETS" ]; then
    echo "→ Compiling assets..."
    actool "$XCASSETS" \
        --compile "$RESOURCES" \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$OUTPUT_DIR/assetcatalog_generated_info.plist" \
        2>/dev/null || echo "⚠ actool failed, assets may be missing"
    rm -f "$OUTPUT_DIR/assetcatalog_generated_info.plist"
fi

# 7. Copy SPM resource bundle and compile xcassets.
#    SPM Bundle.module looks at: Bundle.main.bundlePath + "/Gridex_Gridex.bundle"
#    For .app bundles, bundlePath = "Gridex.app" (the root), so we place it there.
BUNDLE_RESOURCE="$BUILD_DIR/Gridex_Gridex.bundle"
if [ -d "$BUNDLE_RESOURCE" ]; then
    DEST="$CONTENTS/Resources/Gridex_Gridex.bundle"
    cp -R "$BUNDLE_RESOURCE" "$DEST"
    SPM_XCASSETS="$DEST/Assets.xcassets"
    if [ -d "$SPM_XCASSETS" ]; then
        actool "$SPM_XCASSETS" \
            --compile "$DEST" \
            --platform macosx \
            --minimum-deployment-target 14.0 \
            --output-partial-info-plist /dev/null \
            2>/dev/null || true
        rm -rf "$SPM_XCASSETS"
    fi
fi

# 7b. Embed Sparkle.framework (for in-app auto-update).
#     Located in SPM binary artifacts: .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/
SPARKLE_FRAMEWORK=$(find "$PROJECT_DIR/.build/artifacts" -type d -name "Sparkle.framework" 2>/dev/null | grep "macos-" | head -1 || true)
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    # Fallback to per-arch build output (symlinked from xcframework)
    SPARKLE_FRAMEWORK="$BUILD_DIR/Sparkle.framework"
fi
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    echo "→ Embedding Sparkle.framework..."
    FRAMEWORKS_DIR="$CONTENTS/Frameworks"
    mkdir -p "$FRAMEWORKS_DIR"
    # Copy preserving symlinks (Sparkle uses Versions/B + Current symlink)
    rm -rf "$FRAMEWORKS_DIR/Sparkle.framework"
    cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"
    # SPM sets rpath to @executable_path — add ../Frameworks so dyld finds the framework
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$APP_NAME" 2>/dev/null || true
else
    echo "⚠ Sparkle.framework not found — auto-update will be disabled in this build."
fi

# 8. Generate runtime entitlements (strip Xcode-only macros)
RUNTIME_ENT="$OUTPUT_DIR/runtime.entitlements"
/usr/libexec/PlistBuddy -c "Clear dict" "$RUNTIME_ENT" 2>/dev/null || plutil -create xml1 "$RUNTIME_ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool false" "$RUNTIME_ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.network.client bool true" "$RUNTIME_ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.network.server bool true" "$RUNTIME_ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.files.user-selected.read-write bool true" "$RUNTIME_ENT"

# 9. Sign
# - Debug: ad-hoc signature so the app runs locally without a network round-trip.
# - Release: full sign + notarize + staple + verify via sign-notarize.sh (which also
#   handles inside-out signing when Sparkle.framework is embedded in the future).
# - SKIP_SIGN=1: skip signing entirely (used by release-all.sh before lipo merge).

if [ "$MODE" = "release" ] && [ "$SKIP_SIGN" != "1" ]; then
    echo "→ Release sign + notarize pipeline..."
    # Keep runtime.entitlements alongside the .app so sign-notarize.sh can pick it up
    # (it sits at $(dirname .app)/runtime.entitlements).
    # (already at $RUNTIME_ENT, no move needed)

    if [ "$NOTARIZE" = "1" ]; then
        "$SCRIPT_DIR/sign-notarize.sh" "$APP_BUNDLE"
    else
        # Sign only, skip notarize (useful during iteration).
        # Delegate to sign-notarize.sh with SKIP_NOTARIZE=1 so Sparkle inside-out
        # signing stays consistent across the NOTARIZE=1 and NOTARIZE=0 paths.
        echo "→ Signing only (NOTARIZE=0)..."
        SKIP_NOTARIZE=1 "$SCRIPT_DIR/sign-notarize.sh" "$APP_BUNDLE"
    fi
    rm -f "$RUNTIME_ENT"
elif [ "$MODE" = "release" ] && [ "$SKIP_SIGN" = "1" ]; then
    echo "→ Skipping sign (SKIP_SIGN=1) — entitlements kept at $RUNTIME_ENT"
else
    echo "→ Ad-hoc signing (debug)..."
    cs_out=$(codesign --force --deep --sign - \
        --entitlements "$RUNTIME_ENT" \
        --generate-entitlement-der \
        "$APP_BUNDLE" 2>&1) || echo "⚠ Signing skipped"
    echo "$cs_out" | grep -v "unsealed contents" || true
    rm -f "$RUNTIME_ENT"
    xattr -cr "$APP_BUNDLE" 2>/dev/null || true
fi

# 10. Done
APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CONTENTS/Info.plist")
echo ""
echo "✓ $APP_NAME.app v$VERSION ($MODE, $APP_SIZE)"
echo "  $APP_BUNDLE"
echo ""
if [ "$MODE" = "release" ]; then
    echo "Next: package into DMG"
    echo "  ./scripts/make-dmg.sh"
else
    echo "To install: drag to /Applications or run:"
    echo "  open $APP_BUNDLE"
fi
