#!/bin/bash
# Regenerates the app icon and the menu bar template images from their SVG sources:
#   Resources/AppIcon.svg     -> Resources/AppIcon.icns
#   Resources/MenuBarIcon.svg -> Resources/MenuBarIconTemplate.png and @2x
#
# Not run by build.sh: the outputs are committed, so a build needs no SVG renderer.
# Run this by hand when the artwork changes. The SVGs use filters and masks, so they are
# rendered by a Chromium-based browser in headless mode; sips and iconutil ship with macOS.
#   BROWSER=/path/to/browser/binary Resources/make-icon.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
res="$root/Resources"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

browser="${BROWSER:-}"
if [[ -z "$browser" ]]; then
  for candidate in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    "/Applications/Helium.app/Contents/MacOS/Helium" \
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
    [[ -x "$candidate" ]] && browser="$candidate" && break
  done
fi
[[ -x "$browser" ]] || { echo "need a Chromium-based browser; set BROWSER" >&2; exit 1; }

render() {  # render <svg> <size> <png>
  "$browser" --headless=new --user-data-dir="$work/profile" --disable-gpu --hide-scrollbars \
    --default-background-color=00000000 --force-device-scale-factor=1 --window-size="$2,$2" \
    --screenshot="$3" "file://$1" >/dev/null 2>&1
  [[ -s "$3" ]] || { echo "rendering failed: $1" >&2; exit 1; }
}

render "$res/AppIcon.svg" 1024 "$work/master.png"
set="$work/AppIcon.iconset"
mkdir "$set"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$work/master.png" --out "$set/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$work/master.png" --out "$set/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o "$res/AppIcon.icns"

# Menu bar: an 18 pt template image (black on transparent; macOS tints it).
render "$res/MenuBarIcon.svg" 360 "$work/glyph.png"
sips -z 18 18 "$work/glyph.png" --out "$res/MenuBarIconTemplate.png" >/dev/null
sips -z 36 36 "$work/glyph.png" --out "$res/MenuBarIconTemplate@2x.png" >/dev/null
echo "wrote: AppIcon.icns, MenuBarIconTemplate.png, MenuBarIconTemplate@2x.png"
