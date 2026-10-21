#!/bin/sh
# Installs Hyperbox Tools in this Mac, so Hyperbox on the host can run commands in it, share the
# clipboard, and drop files on its desktop. Double-click it in Finder; run it again to update.
#
#     Install Hyperbox Tools.command              asks whether to allow administrator commands
#     Install Hyperbox Tools.command --admin      allows them (asks for your password)
#     Install Hyperbox Tools.command --no-admin   doesn't
#     Install Hyperbox Tools.command --uninstall  removes everything
set -e

here="$(cd "$(dirname "$0")" && pwd)"
label=dev.alexis.hyperbox-tools
dir="$HOME/Library/Application Support/Hyperbox Tools"
agent="$HOME/Library/LaunchAgents/$label.plist"
daemon="/Library/LaunchDaemons/$label.daemon.plist"
admin_binary=/usr/local/libexec/hyperbox-tools
uid=$(id -u)

if [ "$1" = "--uninstall" ]; then
    launchctl bootout "gui/$uid/$label" 2>/dev/null || true
    rm -rf "$agent" "$dir"
    if [ -e "$daemon" ]; then
        sudo ${SUDO_ASKPASS:+-A} sh -c "launchctl bootout system/$label.daemon 2>/dev/null; rm -f '$daemon' '$admin_binary'"
    fi
    echo "Hyperbox Tools is gone."
    exit 0
fi

# The agent runs as you, from your Library, so installing it needs no password.
mkdir -p "$dir" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp -f "$here/hyperbox-tools" "$dir/hyperbox-tools.new"
mv -f "$dir/hyperbox-tools.new" "$dir/hyperbox-tools"
cat > "$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array><string>$dir/hyperbox-tools</string><string>agent</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/hyperbox-tools.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$uid/$label" 2>/dev/null || true
launchctl bootstrap "gui/$uid" "$agent"
echo "Hyperbox Tools is running: Hyperbox can now run commands, share the clipboard and drop files here."

admin="$1"
if [ -z "$admin" ]; then
    printf "Also let Hyperbox run commands as administrator? You'll be asked for your password. [y/N] "
    read -r answer
    case "$answer" in [yY]*) admin=--admin ;; *) admin=--no-admin ;; esac
fi
[ "$admin" = "--admin" ] || exit 0

# The administrator helper runs as root, so its binary lives where only root can change it.
# (Hyperbox sets SUDO_ASKPASS when it installs this itself, on a machine it set up.)
sudo ${SUDO_ASKPASS:+-A} sh -c "
    set -e
    mkdir -p /usr/local/libexec
    cp -f '$here/hyperbox-tools' '$admin_binary'
    chown root:wheel '$admin_binary'
    chmod 755 '$admin_binary'
    cat > '$daemon' <<EOF
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key><string>$label.daemon</string>
    <key>ProgramArguments</key>
    <array><string>$admin_binary</string><string>daemon</string><string>--owner</string><string>$uid</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardErrorPath</key><string>/var/log/hyperbox-tools.log</string>
</dict>
</plist>
EOF
    chown root:wheel '$daemon'
    chmod 644 '$daemon'
    launchctl bootout system/$label.daemon 2>/dev/null || true
    launchctl bootstrap system '$daemon'
"
echo "Hyperbox can run administrator commands too."
