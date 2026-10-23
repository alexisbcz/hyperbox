#!/bin/sh
# Mutes the guest's sound, which otherwise plays on this Mac.
# os: macOS
osascript -e 'set volume output muted true'
