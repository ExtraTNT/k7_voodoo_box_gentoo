#!/usr/bin/env bash
# Entry point INSIDE the build distro, used by wsl/run.cmd (PowerShell/cmd)
# and wsl/run.sh (Git Bash).  The working directory is the repo.
#   inside.sh [VAR=value ...] SCRIPT [ARGS ...]
# SCRIPT may be written Windows-style (.\build\publish.sh).
set -euo pipefail

envs=()
while [[ $# -gt 0 && $1 =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do envs+=("$1"); shift; done
[[ $# -gt 0 ]] || { echo "usage: run [VAR=value ...] SCRIPT [ARGS ...]   e.g. run build/prebuild.sh" >&2; exit 2; }
script=${1//\\//}
script=${script#./}
shift
[[ -f $script ]] || { echo "no such script: $script (path relative to the repo)" >&2; exit 2; }
exec env "${envs[@]}" bash "$script" "$@"
