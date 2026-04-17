#!/bin/bash
# publish.sh — Generate Sparkle appcast and upload release artifacts to Cloudflare R2.
#
# Usage:
#   ./scripts/publish.sh                    # Publishes everything in dist/*.dmg
#   DRY_RUN=1 ./scripts/publish.sh          # Generates appcast locally, skips upload
#   SKIP_APPCAST=1 ./scripts/publish.sh     # Uploads existing artifacts, no appcast regen
#
# Env:
#   R2_BUCKET         Cloudflare R2 bucket name (default: gridex-downloads)
#   R2_PREFIX         Path prefix in bucket (default: macos)
#   FEED_BASE_URL     Public URL where the DMGs are served (default: https://cdn.gridex.app/macos)
#   DRY_RUN           1 = generate appcast locally, skip R2 upload
#   SKIP_APPCAST      1 = skip appcast regeneration (re-upload only)
#
# Requirements:
#   • generate_appcast from Sparkle (found automatically under .build/artifacts)
#   • wrangler CLI (npm i -g wrangler) with `wrangler login` completed
#   • EdDSA private key previously generated via `generate_keys` (stored in Keychain)
#
# Flow:
#   1. Find generate_appcast in SPM artifacts
#   2. Run generate_appcast against dist/ → signs each DMG with EdDSA, emits appcast.xml
#   3. Upload every .dmg + appcast.xml to R2 under $R2_BUCKET/$R2_PREFIX/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"

R2_BUCKET="${R2_BUCKET:-gridex}"
R2_PREFIX="${R2_PREFIX:-macos}"
FEED_BASE_URL="${FEED_BASE_URL:-https://cdn.gridex.app/macos}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_APPCAST="${SKIP_APPCAST:-0}"

echo "═══════════════════════════════════════════"
echo "  Publish to Cloudflare R2"
echo "  Bucket:   $R2_BUCKET"
echo "  Prefix:   $R2_PREFIX"
echo "  Feed:     $FEED_BASE_URL"
[ "$DRY_RUN" = "1" ] && echo "  Mode:     DRY RUN (no upload)"
echo "═══════════════════════════════════════════"

if [ ! -d "$DIST_DIR" ] || [ -z "$(ls -A "$DIST_DIR"/*.dmg 2>/dev/null)" ]; then
    echo "✗ No .dmg files in $DIST_DIR"
    echo "  Run ./scripts/release.sh or ./scripts/release-all.sh first."
    exit 1
fi

# 1. Locate generate_appcast
if [ "$SKIP_APPCAST" != "1" ]; then
    GENERATE_APPCAST=$(find "$PROJECT_DIR/.build/artifacts" -type f -name "generate_appcast" 2>/dev/null | head -1)
    if [ -z "$GENERATE_APPCAST" ]; then
        echo "✗ generate_appcast not found. Run 'swift build' at least once to fetch Sparkle artifacts."
        exit 1
    fi

    echo "→ Generating appcast.xml via $GENERATE_APPCAST..."
    # --download-url-prefix tells Sparkle where to fetch DMGs from at update time.
    "$GENERATE_APPCAST" \
        --download-url-prefix "$FEED_BASE_URL/" \
        "$DIST_DIR"
    echo "✓ Appcast generated: $DIST_DIR/appcast.xml"
fi

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "Dry run complete. Artifacts ready in $DIST_DIR:"
    ls -lh "$DIST_DIR"/*.dmg "$DIST_DIR"/appcast.xml 2>/dev/null || true
    exit 0
fi

# 2. Check for wrangler
if ! command -v wrangler >/dev/null 2>&1; then
    echo "✗ wrangler not found. Install with: npm i -g wrangler"
    exit 1
fi

# 3. Upload DMGs
echo "→ Uploading DMGs to R2..."
for dmg in "$DIST_DIR"/*.dmg; do
    [ -f "$dmg" ] || continue
    name=$(basename "$dmg")
    echo "  ↑ $name"
    wrangler r2 object put "$R2_BUCKET/$R2_PREFIX/$name" \
        --file "$dmg" \
        --content-type "application/x-apple-diskimage" \
        --remote
done

# 4. Upload appcast.xml (cache-control short so updates propagate fast)
if [ -f "$DIST_DIR/appcast.xml" ]; then
    echo "  ↑ appcast.xml"
    wrangler r2 object put "$R2_BUCKET/$R2_PREFIX/appcast.xml" \
        --file "$DIST_DIR/appcast.xml" \
        --content-type "application/xml" \
        --cache-control "public, max-age=300" \
        --remote
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  ✓ Published to R2"
echo "  Appcast: $FEED_BASE_URL/appcast.xml"
echo "═══════════════════════════════════════════"
