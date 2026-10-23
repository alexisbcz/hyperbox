#!/bin/sh
# Asks Cloudflare's and Quad9's DNS servers directly, for when this Mac's resolver doesn't answer the guest (VPN apps that block local DNS).
# os: macOS
# admin: yes
set -e
networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//' | while read -r service; do
    networksetup -setdnsservers "$service" 1.1.1.1 9.9.9.9
done
dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null || true
echo "DNS: $(scutil --dns | awk '/nameserver\[0\]/ {print $3; exit}')"
