#!/usr/bin/env bash
# Prebuild everything for the S2466 on this fast amd64 machine (Linux or WSL):
# all binary packages + the kernel, in a FRESH i686 stage3 chroot with exactly
# this repo's portage config and install.conf — i.e. a simulated install.
#
#   sudo bash build/prebuild.sh                  # uses ./install.conf
#   sudo CONF=other.conf bash build/prebuild.sh
#
# Output in $PREBUILT (default /var/tmp/s2466-prebuilt):
#   stage1/binpkgs/          what stage 1 installs     -> on the CD (iso/build-iso.sh)
#   binpkgs/                 everything                -> 'binpkgs' git branch (build/publish.sh)
#   kernel/linux-<hash>.tar.xz   hash = sha256 of the merged kernel fragments
#   SNAPSHOT                 portage tree date (YYYYMMDD) the packages match
#   STAGE3                   stage3 URL the packages were built on
#
# Kept between runs in $CACHE (default /var/tmp/s2466-cache): the stage3, the
# package cache and distfiles — so a re-run mostly re-merges binary packages.
set -Eeuo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$REPO/lib/common.sh"
CONF=${CONF:-$REPO/install.conf}
load_config "$CONF"

ROOT=${BUILD_ROOT:-/var/tmp/s2466-buildroot}
CACHE=${CACHE:-/var/tmp/s2466-cache}
PREBUILT=${PREBUILT:-/var/tmp/s2466-prebuilt}

[[ $EUID -eq 0 ]] || die "run as root"
command -v setarch >/dev/null || die "setarch (util-linux) missing"
tar --version 2>/dev/null | grep -q 'GNU tar' || die "GNU tar needed (stage3 xattrs)"
mkdir -p "$CACHE/binpkgs" "$CACHE/distfiles" "$PREBUILT"

mounts_below() { awk -v r="$1" '$2 == r || index($2, r "/") == 1 {print $2}' /proc/mounts; }
mounted_below() { mounts_below "$1" | grep -q .; }
cleanup() {
  local rc=$? m
  # deepest first
  mounts_below "$ROOT" | sort -r | while read -r m; do
    umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
  done
  mounted_below "$ROOT" && warn "still mounted below $ROOT — not touching it"
  exit "$rc"
}
trap cleanup EXIT

# ── fresh chroot from the (cached, verified) stage3 ────────────────────────
url=${STAGE3_URL:-$(gentoo_latest "$GENTOO_MIRROR/releases/x86/autobuilds/latest-stage3-$STAGE3_FLAVOR.txt")}
tarball=$CACHE/${url##*/}
if [[ ! -s $tarball ]]; then
  log "downloading $url"
  fetch "$url" "$tarball.part" && mv "$tarball.part" "$tarball"
  fetch "$url.DIGESTS" "$tarball.DIGESTS"
fi
verify_digests "$tarball" "$tarball.DIGESTS"

mounted_below "$ROOT" && die "something is still mounted below $ROOT — refusing to delete it"
rm -rf "$ROOT"
mkdir -p "$ROOT"
log "unpacking stage3 into $ROOT"
tar xpf "$tarball" --xattrs-include='*.*' --numeric-owner -C "$ROOT"

# --make-rslave: unmounting the chroot must never take the host's mounts along
mount -t proc /proc "$ROOT/proc"
for d in sys dev; do mount --rbind "/$d" "$ROOT/$d"; mount --make-rslave "$ROOT/$d"; done
mount --bind /run "$ROOT/run"; mount --make-slave "$ROOT/run"
mkdir -p "$ROOT/var/cache/binpkgs" "$ROOT/var/cache/distfiles" "$ROOT/var/cache/s2466-out"
mount --bind "$CACHE/binpkgs"   "$ROOT/var/cache/binpkgs"
mount --bind "$CACHE/distfiles" "$ROOT/var/cache/distfiles"
rm -rf "${PREBUILT:?}"/*
mount --bind "$PREBUILT" "$ROOT/var/cache/s2466-out"
cp --dereference /etc/resolv.conf "$ROOT/etc/"

mkdir -p "$ROOT/root/s2466"
cp -r "$REPO/lib" "$REPO/portage" "$REPO/kernel" "$REPO/build" "$ROOT/root/s2466/"
install -m 600 "$CONF" "$ROOT/etc/system.conf"

# setarch i686: uname -m says i686, so every build system sees a 32-bit box
setarch i686 chroot "$ROOT" /bin/bash /root/s2466/build/prebuild-chroot.sh "$(nproc)"

echo "$url" > "$PREBUILT/STAGE3"
log "prebuilt:"
du -sh "$PREBUILT"/* | sed 's|/var/tmp/||'
log "next: bash iso/build-iso.sh  and  bash build/publish.sh"
