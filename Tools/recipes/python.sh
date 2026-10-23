#!/bin/sh
# Installs uv and a current Python as python3 and python, without Apple's Command Line Tools.
# os: macOS
set -e
[ -x ~/.local/bin/uv ] || curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
~/.local/bin/uv python install 3.12 --default --preview-features python-install-default
grep -q '.local/bin' ~/.zprofile 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zprofile
echo "Installed $(~/.local/bin/python3 --version) and $(~/.local/bin/uv --version)."
