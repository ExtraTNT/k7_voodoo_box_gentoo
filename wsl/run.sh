#!/usr/bin/env bash
# Git Bash: run one of this repo's Linux scripts inside the WSL build distro,
# as root.  (PowerShell / cmd: use wsl\run.cmd — a .sh does not run there.)
#
#   ./wsl/run.sh build/prebuild.sh
#   ./wsl/run.sh iso/build-iso.sh
#   ./wsl/run.sh build/publish.sh
#   ./wsl/run.sh test/live-test.sh run
#   ./wsl/run.sh REBUILD=1 test/live-test.sh      # VAR=value before the script is passed on
#
# Distro: $S2466_WSL (default s2466-build, made by wsl/setup.ps1).
set -euo pipefail

command -v wsl.exe >/dev/null || { echo "run this from Git Bash on Windows (on Linux: sudo bash SCRIPT)" >&2; exit 1; }
distro=${S2466_WSL:-s2466-build}

win=$(cd "$(dirname "$0")/.." && pwd -W)          # e.g. A:/src/debian-32
drive=${win%%:*}
repo="/mnt/${drive,,}${win#*:}"                    # -> /mnt/a/src/debian-32

# --exec: no shell in between, arguments arrive as they are
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
  exec wsl.exe -d "$distro" -u root --cd "$repo" --exec bash wsl/inside.sh "$@"
