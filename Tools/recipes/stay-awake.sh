#!/bin/sh
# Keeps the machine, its screen and its screen saver from ever going to sleep.
# os: macOS
# admin: yes
set -e
pmset -a sleep 0 displaysleep 0 disksleep 0
sudo -H -u "$HYPERBOX_USER" defaults -currentHost write com.apple.screensaver idleTime -int 0
# No password prompt after the screen saver or sleep, should either ever come back.
sudo -H -u "$HYPERBOX_USER" defaults write com.apple.screensaver askForPassword -int 0
