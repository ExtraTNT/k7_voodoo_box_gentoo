#!/usr/bin/env bash
# Runs INSIDE the fresh i686 chroot of build/prebuild.sh.  Mirrors what the
# installer (stage 1) and bootstrap.sh (stage 2) do, with FEATURES=buildpkg.
set -Eeuo pipefail
jobs=$1
P=/root/s2466
OUT=/var/cache/s2466-out
LOG=/var/log/emerge.log

set +u; source /etc/profile; set -u
# shellcheck source=../lib/common.sh
source "$P/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$P/lib/system.sh"
trap 'warn "prebuild failed at line $LINENO: $BASH_COMMAND"; exit 1' ERR
load_config /etc/system.conf
MAKEOPTS="-j$jobs -l$jobs"            # this machine's cores (also for build_kernel)

log_mark() { wc -l < "$LOG" 2>/dev/null || echo 0; }

# Packages merged (built or taken from the cache) since MARK -> cat/pf list.
merged_since() {
  tail -n +"$(($1 + 1))" "$LOG" \
    | sed -n 's/.*::: completed emerge ([0-9]* of [0-9]*) \([^ ]*\) to \/.*/\1/p' | sort -u
}

# newest binary package of exactly cat/pf (binpkg-multi-instance: pf-N.gpkg.tar)
newest_binpkg() { # CAT PF
  [[ -d /var/cache/binpkgs/$1 ]] || return 0
  find "/var/cache/binpkgs/$1" -name "$2-[0-9]*.gpkg.tar" -printf '%T@ %p\n' \
    | sort -rn | head -n1 | cut -d' ' -f2-
}

# Copy the newest binary package of each listed, still installed cat/pf into
# DEST (+ index).  Packages merged from Gentoo's binhost are not always kept in
# PKGDIR — quickpkg makes them from the installed files.
export_binpkgs() { # LISTFILE DEST
  local cpv cat pf f n=0
  mkdir -p "$2"
  while read -r cpv; do
    [[ -d /var/db/pkg/$cpv ]] || continue          # replaced later in the run
    cat=${cpv%%/*} pf=${cpv#*/}
    f=$(newest_binpkg "$cat" "$pf")
    if [[ -z $f ]]; then
      quickpkg --quiet "=$cpv" >/dev/null 2>&1 || true
      f=$(newest_binpkg "$cat" "$pf")
    fi
    [[ -n $f ]] || { warn "no binary package for $cpv"; continue; }
    install -D -m 644 "$f" "$2/${f#/var/cache/binpkgs/}"
    n=$((n + 1))
  done < "$1"
  PKGDIR=$2 emaint binhost --fix >/dev/null
  log "exported $n packages to ${2#"$OUT"/} ($(du -sh "$2" | cut -f1))"
}

apply_portage_config "$P/portage"
cat >> /etc/portage/make.conf <<EOF

# prebuild overrides (this machine, not the Athlons)
MAKEOPTS="$MAKEOPTS"
FEATURES="\${FEATURES} buildpkg"
EMERGE_DEFAULT_OPTS="\${EMERGE_DEFAULT_OPTS} --jobs=6 --load-average=$jobs"
EOF

log "portage tree"
emerge-webrsync -q
date -u -d "$(head -n1 /var/db/repos/gentoo/metadata/timestamp.chk)" +%Y%m%d > "$OUT/SNAPSHOT"
eselect profile set "$PROFILE"

start=$(log_mark)

# ── stage 1: same packages as installer/stage1-chroot.sh -> CD ──────────────
log "stage-1 packages"
emerge --usepkg --noreplace sys-boot/grub dev-vcs/git net-misc/dhcpcd app-admin/doas \
  sys-apps/pciutils sys-apps/busybox net-misc/openssh
merged_since "$start" > "$OUT/stage1.list"
export_binpkgs "$OUT/stage1.list" "$OUT/stage1/binpkgs"

# ── stage 2: same as bootstrap.sh -> binpkgs branch ─────────────────────────
log "stage-2 packages (@world @s2466)"
emerge --usepkg --update --deep --changed-use --noreplace @world @s2466
merged_since "$start" > "$OUT/all.list"
export_binpkgs "$OUT/all.list" "$OUT/binpkgs"

# ── kernel (its sources are not exported: the kernel ships prebuilt) ────────
log "kernel"
emerge --usepkg --noreplace "$KERNEL_PKG"
mapfile -t frags < <(kernel_fragments "$P")
build_kernel "${frags[@]}"
h=$(cat /var/lib/autoinstall/kernel-fragment.sha256)
ver=$(make -s -C /usr/src/linux kernelrelease)
mkdir -p "$OUT/kernel"
tar -C / -cJf "$OUT/kernel/linux-$h.tar.xz" \
  "boot/vmlinuz-$ver" "boot/System.map-$ver" "boot/config-$ver" "usr/lib/modules/$ver"
log "kernel $ver -> kernel/linux-$h.tar.xz ($(du -sh "$OUT/kernel/linux-$h.tar.xz" | cut -f1))"
