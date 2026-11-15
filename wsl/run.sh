#!/usr/bin/env bash
# Run one of this repo's Linux scripts inside the WSL build distro, as root,
# straight from Git Bash on Windows:
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

envs=()
while [[ $# -gt 0 && $1 =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do envs+=("$1"); shift; done
[[ $# -gt 0 ]] || { echo "usage: $0 [VAR=value ...] SCRIPT [ARGS ...]" >&2; exit 2; }
script=$1
shift
[[ -f $script || -f "$(dirname "$0")/../$script" ]] || { echo "no such script: $script" >&2; exit 2; }

# --exec: no shell in between, arguments arrive as they are
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
  exec wsl.exe -d "$distro" -u root --cd "$repo" --exec env "${envs[@]}" bash "$repo/$script" "$@"
