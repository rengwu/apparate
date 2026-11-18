#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
version="$(cat "$root/VERSION")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must contain a semantic version with three numbers." >&2
    exit 1
fi
swift build --package-path "$root" -c release --arch arm64 --product Apparate
bin="$(swift build --package-path "$root" -c release --arch arm64 --show-bin-path)"
bundle="$root/build/Apparate.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin/Apparate" "$bundle/Contents/MacOS/Apparate"
cp "$root/THIRD_PARTY_NOTICES.txt" "$bundle/Contents/Resources/"
cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Apparate</string>
<key>CFBundleIdentifier</key><string>local.apparate</string>
<key>CFBundleExecutable</key><string>Apparate</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --deep --sign - --requirements '=designated => identifier "local.apparate"' "$bundle"
codesign --verify --deep --strict "$bundle"
echo "Built build/Apparate.app ($version, arm64)"
