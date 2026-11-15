#!/usr/bin/env bash
# Build the S2466 auto-installer ISO from the official Gentoo x86 minimal ISO.
#
# Run as root on any Linux box (needs xorriso, squashfs-tools, wget or curl):
#   sudo iso/build-iso.sh
#   sudo CONF=/path/other.conf iso/build-iso.sh
#   sudo ISO=/path/install-x86-minimal-XXXX.iso iso/build-iso.sh   # offline;
#        expects ISO.DIGESTS next to it
#
# Uses PREBUILT (default /var/tmp/s2466-prebuilt, from build/prebuild.sh) for
# the kernel + stage-1 packages on the CD.
#
# Output: iso/out/s2466-autoinstall.iso — boots like the stock CD, plus a
# first (default) menu entry "Auto-install ..." that starts the installer.
set -Eeuo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$REPO/lib/common.sh"

CONF=${CONF:-$REPO/install.conf}
# on a Linux filesystem: the live root has device nodes, owners, symlinks
# (not /mnt/<drive> in WSL)
WORK=${WORK:-/var/tmp/s2466-iso}
CACHE=${CACHE:-/var/tmp/s2466-cache}
OUT=${OUT:-$REPO/iso/out/s2466-autoinstall.iso}
CD_MAX=737280000                      # 80 min CD-R

[[ $EUID -eq 0 ]] || die "run as root (unsquashfs has to keep owners and device nodes)"
for t in xorriso unsquashfs mksquashfs sha512sum awk; do
  command -v "$t" >/dev/null || die "missing tool: $t"
done
load_config "$CONF"                   # fail early on a broken config
mkdir -p "$WORK" "$CACHE" "${OUT%/*}"

# ── 1. official ISO (cached) ────────────────────────────────────────────────
if [[ -z ${ISO:-} ]]; then
  url=$(gentoo_latest "$GENTOO_MIRROR/releases/x86/autobuilds/latest-install-x86-minimal.txt")
  ISO=$CACHE/${url##*/}
  if [[ ! -s $ISO ]]; then
    log "downloading $url"
    fetch "$url" "$ISO.part" && mv "$ISO.part" "$ISO"
  fi
  [[ -s $ISO.DIGESTS ]] || fetch "$url.DIGESTS" "$ISO.DIGESTS"
fi
[[ -s $ISO.DIGESTS ]] || die "missing $ISO.DIGESTS"
verify_digests "$ISO" "$ISO.DIGESTS"

# ── 2. unpack the CD tree and the live root ─────────────────────────────────
volid=$(xorriso -indev "$ISO" -report_el_torito as_mkisofs 2>/dev/null | sed -n "s/^-V '\(.*\)'\$/\1/p")
[[ -n $volid ]] || die "cannot read the volume label of $ISO"
sq=$(xorriso -indev "$ISO" -find / -type f -name '*.squashfs' 2>/dev/null | tr -d "'" | head -n1)
[[ -n $sq ]] || die "no squashfs in $ISO"
log "label $volid, live image $sq"

T=$WORK/tree
rm -rf "$T" "$WORK/rootfs" "$WORK/new.squashfs" "$WORK/grub.cfg.new"
xorriso -osirrox on -indev "$ISO" -extract / "$T" 2>/dev/null
chmod -R u+w "$T"

info=$(unsquashfs -s "$T$sq")
comp=$(awk '/^Compression/ {print $2}' <<<"$info")
bs=$(awk '/^Block size/ {print $3}' <<<"$info")
sqopts=(-comp "$comp" -b "$bs")
grep -q 'Filters selected: x86' <<<"$info" && sqopts+=(-Xbcj x86)
grep -qi 'xattrs.*not' <<<"$info" && sqopts+=(-no-xattrs)
log "squashfs: $comp, block $bs"
unsquashfs -no-progress -d "$WORK/rootfs" "$T$sq" >/dev/null

# ── 3. inject installer + repo payload ──────────────────────────────────────
R=$WORK/rootfs
S=$R/usr/local/share/autoinstall
rm -rf "$S"; mkdir -p "$S"
cp -r "$REPO/lib" "$REPO/kernel" "$REPO/portage" "$REPO/installer" "$REPO/post" "$S/"
install -m 600 "$CONF" "$S/install.conf"
install -D -m 755 "$REPO/installer/autoinstall" "$R/usr/local/sbin/autoinstall"
install -m 644 "$REPO/installer/profile-hook.sh" "$R/etc/profile.d/zz-autoinstall.sh"

# live firmware: keep only ISO_FIRMWARE_KEEP (the S2466 needs radeon/) -> room
# for the prebuilt payload.  The initramfs is untouched.
fw=$R/usr/lib/firmware
if [[ -d $fw ]]; then
  before=$(du -sm "$fw" | cut -f1)
  for e in "$fw"/* "$fw"/.[!.]*; do
    [[ -e $e || -L $e ]] || continue
    [[ " $ISO_FIRMWARE_KEEP " == *" ${e##*/} "* ]] || rm -rf "$e"
  done
  log "live firmware: ${before} MiB -> $(du -sm "$fw" | cut -f1) MiB (kept: ${ISO_FIRMWARE_KEEP:-nothing})"
fi

# prebuilt kernel + stage-1 packages (build/prebuild.sh)
PREBUILT=${PREBUILT:-/var/tmp/s2466-prebuilt}
if [[ -d $PREBUILT/stage1/binpkgs ]]; then
  mkdir -p "$S/prebuilt/kernel"
  cp -r "$PREBUILT/stage1/binpkgs" "$S/prebuilt/binpkgs"
  cp "$PREBUILT/SNAPSHOT" "$PREBUILT/STAGE3" "$S/prebuilt/"
  mapfile -t frags < <(for f in $KERNEL_FRAGMENT; do echo "$REPO/$f"; done)
  h=$(cat "${frags[@]}" | sha256sum | cut -d' ' -f1)
  if [[ -r $PREBUILT/kernel/linux-$h.tar.xz ]]; then
    cp "$PREBUILT/kernel/linux-$h.tar.xz" "$S/prebuilt/kernel/"
    log "prebuilt: kernel linux-${h:0:12}…, $(du -sh "$S/prebuilt/binpkgs" | cut -f1) stage-1 packages, tree $(cat "$PREBUILT/SNAPSHOT")"
  else
    warn "no prebuilt kernel for KERNEL_FRAGMENT=\"$KERNEL_FRAGMENT\" — the Athlons will compile it (run build/prebuild.sh with this config)"
  fi
else
  warn "no $PREBUILT — stage 1 compiles everything on the Athlons (run build/prebuild.sh first)"
fi

log "re-squashing (takes a few minutes)"
mksquashfs "$R" "$WORK/new.squashfs" "${sqopts[@]}" -noappend -no-progress >/dev/null

# ── 4. boot menu: auto-install entry first ──────────────────────────────────
G=$T/boot/grub/grub.cfg
search=$(grep -m1 -E '^[[:space:]]*search ' "$G" | sed 's/^[[:space:]]*//')
linux=$(grep -m1 -E '^[[:space:]]*linux ' "$G" | sed 's/^[[:space:]]*//')
initrd=$(grep -m1 -E '^[[:space:]]*initrd ' "$G" | sed 's/^[[:space:]]*//')
[[ -n $linux && -n $initrd ]] || die "unexpected grub.cfg layout"
# no interactive keymap prompt (the installer loads KEYMAP from install.conf);
# AI_BOOT_ARGS adds extra options, e.g. AI_BOOT_ARGS=ai.serial
linux="${linux//dokeymap /} autoinstall${AI_BOOT_ARGS:+ $AI_BOOT_ARGS}"
awk -v s="$search" -v l="$linux" -v i="$initrd" '
  /^set timeout=/ { print "set timeout=5"; next }
  /^menuentry/ && !done {
    print "menuentry '\''Auto-install Gentoo for the S2466 (asks before wiping)'\'' --class gnu-linux --class os {"
    if (s != "") print "\t" s
    print "\t" l
    print "\t" i
    print "}\n"
    done = 1
  }
  { print }' "$G" > "$WORK/grub.cfg.new"
mv "$WORK/grub.cfg.new" "$G"
mv "$WORK/new.squashfs" "$T$sq"

# ── 5. repack: BIOS El Torito + hybrid MBR (dd-able), same label ────────────
# The stock ISO also carries EFI + Mac (HFS+/APM) boot layers; the S2466 has
# no UEFI, so they are dropped. GRUB's MBR code comes from the original ISO.
rm -f "$OUT"
xorriso -as mkisofs -o "$OUT" -r -V "$volid" \
  --grub2-mbr "--interval:local_fs:0s-15s:zero_mbrpt,zero_gpt,zero_apm:$ISO" \
  --protective-msdos-label -partition_offset 0 --mbr-force-bootable \
  -c /boot.catalog \
  -b /boot/grub/i386-pc/eltorito.img -no-emul-boot -boot-load-size 4 \
  -boot-info-table --grub2-boot-info \
  "$T" 2>&1 | grep -Ei 'error|fail|sorry' || true
[[ -s $OUT ]] || die "xorriso produced no ISO"

size=$(stat -c %s "$OUT")
log "built $OUT ($((size / 1048576)) MiB)"
((size <= CD_MAX)) || warn "larger than a 700 MB CD-R — use a DVD-R (the board boots those too)"
warn "install.conf (incl. password hashes, if any) is readable on this ISO — keep it private"
