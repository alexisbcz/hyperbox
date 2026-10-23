#!/bin/sh
# Installs Visual Studio Code in /Applications, with its `code` command in ~/.local/bin.
# os: macOS
set -e
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://update.code.visualstudio.com/latest/darwin-arm64/stable" -o "$tmp/vscode.zip"
ditto -x -k "$tmp/vscode.zip" "$tmp"
rm -rf "/Applications/Visual Studio Code.app"
mv "$tmp/Visual Studio Code.app" /Applications/
xattr -dr com.apple.quarantine "/Applications/Visual Studio Code.app" 2>/dev/null || true
mkdir -p ~/.local/bin
ln -sf "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ~/.local/bin/code
grep -q '.local/bin' ~/.zprofile 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zprofile
echo "Installed Visual Studio Code $("$HOME/.local/bin/code" --version | head -1)."
