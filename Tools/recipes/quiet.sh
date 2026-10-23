#!/bin/sh
# Stops what posts banners on a fresh Mac (Tips, Software Update checks), and clears any showing, for recordings and demos.
# os: macOS
# admin: yes
set -e
uid=$(id -u "$HYPERBOX_USER")
launchctl disable "gui/$uid/com.apple.tipsd"
launchctl bootout "gui/$uid/com.apple.tipsd" 2>/dev/null || true
softwareupdate --schedule off >/dev/null 2>&1 || true
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
# NotificationCenter comes straight back, without the banners it was showing.
killall -u "$HYPERBOX_USER" NotificationCenter 2>/dev/null || true
echo "Quiet."
