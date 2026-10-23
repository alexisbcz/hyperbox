#!/bin/sh
# Installs the latest Helium browser in /Applications.
# os: macOS
set -e
url=$(curl -fsSL https://api.github.com/repos/imputnet/helium-macos/releases/latest |
    sed -n 's/.*"browser_download_url": "\([^"]*arm64[^"]*\.dmg\)".*/\1/p' | head -1)
[ -n "$url" ] || { echo "Couldn't find Helium's latest release." >&2; exit 1; }
tmp=$(mktemp -d); trap 'hdiutil detach -quiet "$tmp/mnt" 2>/dev/null; rm -rf "$tmp"' EXIT
curl -fsSL "$url" -o "$tmp/helium.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$tmp/mnt" "$tmp/helium.dmg"
rm -rf /Applications/Helium.app
ditto "$tmp/mnt/Helium.app" /Applications/Helium.app
xattr -dr com.apple.quarantine /Applications/Helium.app 2>/dev/null || true
echo "Installed Helium $(defaults read /Applications/Helium.app/Contents/Info CFBundleShortVersionString)."
