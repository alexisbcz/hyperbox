#!/bin/sh
# Installs Oh My Zsh for the desktop user, with its update prompt off so it never asks in the middle of something.
# os: macOS
set -e
if [ ! -d ~/.oh-my-zsh ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc=no >/dev/null 2>&1
fi
grep -q "^zstyle ':omz:update' mode" ~/.zshrc || sed -i '' "1i\\
zstyle ':omz:update' mode disabled
" ~/.zshrc
# Its installer starts from a fresh .zshrc: bring back what the other recipes put on the PATH.
grep -q '^export PATH=.*\.local/bin' ~/.zshrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
echo "Installed Oh My Zsh, theme $(sed -n 's/^ZSH_THEME="\(.*\)"/\1/p' ~/.zshrc)."
