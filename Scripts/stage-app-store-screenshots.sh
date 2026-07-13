#!/usr/bin/env bash
#
# stage-app-store-screenshots.sh — Unzip exported App Store screenshot bundles,
# drop the ASC-required sizes into a stable folder tree, then stage them into
# fastlane/screenshots/<locale>/ via `fastlane stage_screenshots`.
#
# The zip layout this script understands is what the Cursor / Figma / editor
# App Store screenshot exports produce:
#
#   <zip>
#   └── ios/                    (or "apple/" for older bundles)
#       ├── iphone/1320x2868/en/*.png
#       └── ipad/2064x2752/en/*.png
#
# Adjust IPHONE_SIZE / IPAD_SIZE / LOCALE_DIR if your export uses different
# pixel dimensions or a different locale folder name.
#
# Usage:
#   ./Scripts/stage-app-store-screenshots.sh                            # auto-find newest zips in ~/Downloads
#   ./Scripts/stage-app-store-screenshots.sh /path/to/iphone.zip
#   ./Scripts/stage-app-store-screenshots.sh IPHONE_ZIP IPAD_ZIP
#
# Environment overrides:
#   IPHONE_SIZE   default 1320x2868 (6.9" iPhone)
#   IPAD_SIZE     default 2064x2752 (13" iPad)
#   LOCALE_DIR    default "en" (folder inside the zip, NOT the ASC locale)
#   ZIP_GLOB      default "$HOME/Downloads/*iphone*.zip"
#                 e.g. IPHONE_ZIP_GLOB="$HOME/Downloads/myapp-iphone-*.zip"
#
# After staging, review fastlane/screenshots/<locale>/ then upload:
#   fastlane ios upload_screenshots

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

IPHONE_SIZE="${IPHONE_SIZE:-1320x2868}"
IPAD_SIZE="${IPAD_SIZE:-2064x2752}"
LOCALE_DIR="${LOCALE_DIR:-en}"

# Where extracted PNGs land inside the repo. These paths line up with the
# defaults in Templates/Fastfile (IPHONE_SCREENSHOTS / IPAD_SCREENSHOTS).
IPHONE_EXPORT="${IPHONE_EXPORT:-$ROOT/screenshots-src/iphone}"
IPAD_EXPORT="${IPAD_EXPORT:-$ROOT/screenshots-src/ipad}"

mkdir -p "$IPHONE_EXPORT" "$IPAD_EXPORT"

latest_zip() {
  local files=()
  for pattern in "$@"; do
    for f in $pattern; do
      [[ -f "$f" ]] && files+=("$f")
    done
  done
  [[ ${#files[@]} -eq 0 ]] && return 0
  ls -t "${files[@]}" 2>/dev/null | head -1
}

unzip_device() {
  local zip="$1"
  local device="$2"
  local size="$3"
  local dest="$4"

  if [[ ! -f "$zip" ]]; then
    echo "Skip $device: zip not found -> $zip"
    return 0
  fi

  local tmp prefix count
  tmp="$(mktemp -d)"

  # Modern exports use "ios/…"; older bundles use "apple/…". Try both.
  prefix=""
  for candidate in ios apple; do
    if unzip -l "$zip" "$candidate/$device/$size/$LOCALE_DIR/"*.png >/dev/null 2>&1; then
      prefix="$candidate"
      break
    fi
  done

  if [[ -z "$prefix" ]]; then
    echo "Skip $device: no PNGs at ios/$device/$size/$LOCALE_DIR/ (or apple/…) in $zip"
    rm -rf "$tmp"
    return 0
  fi

  unzip -qo "$zip" "$prefix/$device/$size/$LOCALE_DIR/*.png" -d "$tmp"
  count="$(find "$tmp/$prefix/$device/$size/$LOCALE_DIR" -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$count" == "0" ]]; then
    echo "Skip $device: no PNGs at $prefix/$device/$size/$LOCALE_DIR/ in $zip"
    rm -rf "$tmp"
    return 0
  fi

  cp "$tmp/$prefix/$device/$size/$LOCALE_DIR/"*.png "$dest/"
  rm -rf "$tmp"
  echo "Copied $count $device screenshot(s) from $(basename "$zip")"
}

# CLI args win; otherwise fall back to a Downloads glob.
IPHONE_ZIP_GLOB="${IPHONE_ZIP_GLOB:-$HOME/Downloads/*iphone*.zip}"
IPAD_ZIP_GLOB="${IPAD_ZIP_GLOB:-$HOME/Downloads/*ipad*.zip}"

IPHONE_ZIP="${1:-$(latest_zip $IPHONE_ZIP_GLOB)}"
IPAD_ZIP="${2:-$(latest_zip $IPAD_ZIP_GLOB)}"

unzip_device "$IPHONE_ZIP" "iphone" "$IPHONE_SIZE" "$IPHONE_EXPORT"
unzip_device "$IPAD_ZIP"   "ipad"   "$IPAD_SIZE"   "$IPAD_EXPORT"

# Try to run the fastlane stage_screenshots lane if fastlane is available and
# a Fastfile is present. This produces fastlane/screenshots/<locale>/ ready
# for upload_screenshots.
if command -v fastlane >/dev/null && [ -f "$ROOT/fastlane/Fastfile" ]; then
  ( cd "$ROOT" && fastlane ios stage_screenshots ) || true
else
  echo ""
  echo "fastlane not run (no fastlane binary or no fastlane/Fastfile)."
  echo "Screenshots are staged at:"
  echo "  $IPHONE_EXPORT"
  echo "  $IPAD_EXPORT"
  echo "Point the Fastfile at these via IPHONE_SCREENSHOTS / IPAD_SCREENSHOTS."
fi

LOCALE="${SCREENSHOT_LOCALE:-en-US}"
echo ""
echo "Review: $ROOT/fastlane/screenshots/$LOCALE/"
echo "Upload: cd $ROOT && fastlane ios upload_screenshots"
echo ""
echo "Note: keep backups outside fastlane/screenshots/ (e.g. fastlane/screenshot-backups/)"
echo "      — deliver rejects any folder name that is not a valid ASC locale."
