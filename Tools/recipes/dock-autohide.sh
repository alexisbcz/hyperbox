#!/bin/sh
# Hides the Dock until the pointer reaches the bottom of the screen.
# os: macOS
set -e
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 0
killall Dock
