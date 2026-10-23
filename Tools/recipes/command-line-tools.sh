#!/bin/sh
# Installs Apple's Command Line Tools (git, clang, install_name_tool) from Software Update, without its dialog.
# os: macOS
# admin: yes
set -e
if xcode-select -p >/dev/null 2>&1 && [ -x "$(xcode-select -p)/usr/bin/git" ]; then echo "The Command Line Tools are already installed."; exit 0; fi
# This file makes Software Update list the tools, as the dialog would.
touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
trap 'rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress' EXIT
tools=$(softwareupdate -l 2>/dev/null | sed -n 's/^\* Label: \(Command Line Tools.*\)$/\1/p' | sort -V | tail -1)
[ -n "$tools" ] || { echo "Software Update doesn't offer the Command Line Tools." >&2; exit 1; }
softwareupdate -i "$tools" --agree-to-license
xcode-select -s /Library/Developer/CommandLineTools
echo "Installed $tools."
