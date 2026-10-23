#!/bin/sh
# Installs Homebrew in /opt/homebrew, owned by the desktop user, without asking anything.
# os: macOS
# admin: yes
set -e
if [ -x /opt/homebrew/bin/brew ]; then echo "Homebrew is already installed."; exit 0; fi
xcode-select -p >/dev/null 2>&1 || {
    echo "Homebrew needs the Command Line Tools: run the command-line-tools recipe first." >&2; exit 1
}
mkdir -p /opt/homebrew
chown -R "$HYPERBOX_USER":admin /opt/homebrew
sudo -H -u "$HYPERBOX_USER" env HOME="/Users/$HYPERBOX_USER" sh -c 'curl -fsSL https://github.com/Homebrew/brew/tarball/main | tar xz --strip-components 1 -C /opt/homebrew && /opt/homebrew/bin/brew update --force --quiet'
grep -q 'brew shellenv' "/Users/$HYPERBOX_USER/.zprofile" 2>/dev/null ||
    sudo -H -u "$HYPERBOX_USER" env HOME="/Users/$HYPERBOX_USER" sh -c 'echo "eval \"\$(/opt/homebrew/bin/brew shellenv)\"" >> ~/.zprofile'
echo "Installed $(sudo -H -u "$HYPERBOX_USER" env HOME="/Users/$HYPERBOX_USER" /opt/homebrew/bin/brew --version | head -1)."
