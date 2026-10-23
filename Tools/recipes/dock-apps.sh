#!/bin/sh
# Leaves only the apps in DOCK_APPS in the Dock (comma-separated names, like "Helium,Visual Studio Code"), with no recent apps.
# os: macOS
set -e
defaults write com.apple.dock persistent-apps -array
defaults write com.apple.dock recent-apps -array
defaults write com.apple.dock show-recents -bool false
echo "${DOCK_APPS:-}" | tr ',' '\n' | while read -r name; do
    [ -n "$name" ] || continue
    app=""
    for folder in /Applications /System/Applications /System/Applications/Utilities; do
        [ -d "$folder/$name.app" ] && app="$folder/$name.app" && break
    done
    [ -n "$app" ] || { echo "No app named $name." >&2; exit 1; }
    defaults write com.apple.dock persistent-apps -array-add \
        "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file://$app/</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>"
done
killall Dock
echo "The Dock has Finder$(echo "${DOCK_APPS:-}" | sed "s/^./, &/; s/,\([^ ]\)/, \1/g")."
