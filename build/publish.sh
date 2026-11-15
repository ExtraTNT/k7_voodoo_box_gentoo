#!/usr/bin/env bash
# Put the output of build/prebuild.sh into the BINPKGS_BRANCH of this repo, as
# ONE commit without parents (an orphan branch that is replaced every time):
# the box always gets exactly one set of packages, and old sets do not pile
# up in the history.  Your working tree and other branches are not touched.
#
#   bash build/publish.sh                # then: git push -f origin binpkgs
set -Eeuo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$REPO/lib/common.sh"
load_config "${CONF:-$REPO/install.conf}"
PREBUILT=${PREBUILT:-/var/tmp/s2466-prebuilt}
BRANCH=${BINPKGS_BRANCH:-binpkgs}

# in WSL the repo on /mnt/<drive> belongs to your Windows user, not root:
# trust it for these calls (no global git config is changed)
g() { git -c safe.directory="$REPO" -C "$REPO" "$@"; }

g rev-parse --git-dir >/dev/null 2>&1 || die "$REPO is not a git repository (git init first)"
[[ -s $PREBUILT/SNAPSHOT && -d $PREBUILT/binpkgs ]] || die "nothing in $PREBUILT — run build/prebuild.sh first"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_INDEX_FILE=$tmp/index       # must not exist yet: git rejects an empty file
# only what stage 2 needs (stage 1's packages are on the CD)
g --work-tree="$PREBUILT" add -f -- binpkgs kernel SNAPSHOT STAGE3
tree=$(g write-tree)
commit=$(g -c user.name="${GIT_AUTHOR_NAME:-prebuild}" -c user.email="${GIT_AUTHOR_EMAIL:-prebuild@localhost}" \
  commit-tree "$tree" -m "prebuilt packages + kernel, tree $(cat "$PREBUILT/SNAPSHOT")")
g update-ref "refs/heads/$BRANCH" "$commit"
log "$BRANCH -> ${commit:0:12} ($(du -sh "$PREBUILT/binpkgs" | cut -f1) packages)"
log "upload with:  git push -f origin $BRANCH   (from Git Bash: your credentials live there)"
