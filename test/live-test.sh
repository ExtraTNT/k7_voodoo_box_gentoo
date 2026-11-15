#!/usr/bin/env bash
# Live test of the whole flow in a VM: CD install -> first boot -> i3.
#
#   sudo bash test/live-test.sh            # prepare + run
#   sudo bash test/live-test.sh prepare    # only build test prebuild/repo/ISO
#   sudo bash test/live-test.sh run        # only boot the VM (fresh disk)
#   REBUILD=1 ...                          # redo the test prebuild too
#
# What it does (everything below $WORK, default /var/tmp/s2466-test):
#   1. test.conf = install.conf + VM overrides (unattended wipe, QEMU kernel
#      layer, serial console, repo served from this machine)
#   2. build/prebuild.sh with test.conf (packages come from the cache of your
#      real prebuild, so mostly only the VM kernel is built)
#   3. a test copy of this repo: master + binpkgs branch, served by git daemon
#      (stands in for GitHub; git:// because shallow clones need a smart server)
#   4. iso/build-iso.sh with test.conf -> test.iso
#   5. QEMU with KVM, 3 GB RAM, IDE disk, PS/2, std VGA; window via WSLg/X11
#
# The VM kernel = kernel/s2466.config + kernel/qemu-test.config: modern CPUs
# have no 3DNow!, which a K7 kernel uses.  Follow along:  tail -f $WORK/serial.log
#
# Needs root, qemu-system-i386, qemu-img, git (+ git daemon), xorriso,
# squashfs-tools, GNU tar, xz.
set -Eeuo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$REPO/lib/common.sh"

WORK=${WORK:-/var/tmp/s2466-test}
SMP=${SMP:-4}
MEM=${MEM:-3072}
DISK_SIZE=${DISK_SIZE:-20G}
CONF=$WORK/test.conf
PREBUILT=$WORK/prebuilt

[[ $EUID -eq 0 ]] || die "run as root"

prepare() {
  mkdir -p "$WORK"
  for t in qemu-img git xorriso mksquashfs; do command -v "$t" >/dev/null || die "missing: $t"; done
  git daemon -h >/dev/null 2>&1 || [[ $? -eq 129 ]] || die "git daemon missing (Alpine: apk add git-daemon)"

  log "1/4 test config"
  {
    cat "$REPO/install.conf"
    cat <<'EOF'

# ---- live-test overrides (test/live-test.sh) ----
AUTO_CONFIRM="yes"
KERNEL_FRAGMENT="kernel/s2466.config kernel/qemu-test.config"
KERNEL_CMDLINE="quiet loglevel=3 console=ttyS0,115200 console=tty0 ai.serial"
MAKEOPTS="-j5"
REPO_URL="git://10.0.2.2/system.git"
FIRSTBOOT_BOOTSTRAP="yes"
FIRSTBOOT_REBOOT="yes"
# Windows/WSLg swallow the Win key: CapsLock is Meta in the VM
X_KEYOPTIONS="caps:super"
# unattended -> nobody types a password: user and root get "test"
USER_PASSWORD_HASH='$6$s2466test$1aXtM6LgteUOplHtnIjorD2kCtrWZZeHwQSm4LFleD/LBx6oENhUxYbxHWsnSIrwwhbQYWsTMtkn5fMy5Gdg8.'
ROOT_PASSWORD_HASH='$6$s2466test$1aXtM6LgteUOplHtnIjorD2kCtrWZZeHwQSm4LFleD/LBx6oENhUxYbxHWsnSIrwwhbQYWsTMtkn5fMy5Gdg8.'
EOF
  } > "$CONF"
  load_config "$CONF"

  if [[ -s $PREBUILT/SNAPSHOT && ${REBUILD:-0} != 1 ]]; then
    log "2/4 reusing the test prebuild in $PREBUILT (REBUILD=1 to redo it)"
  else
    log "2/4 prebuild with the VM kernel"
    CONF=$CONF PREBUILT=$PREBUILT BUILD_ROOT=$WORK/buildroot bash "$REPO/build/prebuild.sh"
  fi

  log "3/4 test repo (master + $BINPKGS_BRANCH)"
  rm -rf "$WORK/repo" "$WORK/srv"
  mkdir -p "$WORK/repo" "$WORK/srv"
  tar -C "$REPO" --exclude=./iso/work --exclude=./iso/out --exclude=./.git -cf - . | tar -C "$WORK/repo" -xf -
  git -C "$WORK/repo" init -q -b "$REPO_BRANCH"
  git -C "$WORK/repo" add -A
  git -C "$WORK/repo" -c user.name=live-test -c user.email=test@localhost commit -qm "live test"
  CONF=$CONF PREBUILT=$PREBUILT bash "$WORK/repo/build/publish.sh"
  git clone -q --bare "$WORK/repo" "$WORK/srv/system.git"

  log "4/4 test ISO"
  local iso_work=$WORK/iso iso_out=$WORK/test.iso
  CONF=$CONF PREBUILT=$PREBUILT WORK=$iso_work OUT=$iso_out AI_BOOT_ARGS=ai.serial \
    bash "$REPO/iso/build-iso.sh"
}

run() {
  [[ -s $WORK/test.iso && -d $WORK/srv/system.git ]] || die "nothing prepared — run: $0 prepare"
  command -v qemu-system-i386 >/dev/null || die "missing: qemu-system-i386"

  local accel=(-cpu max) display=(-display none)
  if [[ -w /dev/kvm ]]; then accel=(-enable-kvm -cpu host)
  else warn "no /dev/kvm — software emulation, this will be slow"; fi
  if [[ -S /mnt/wslg/runtime-dir/wayland-0 ]]; then          # WSLg
    export XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir WAYLAND_DISPLAY=wayland-0 GDK_BACKEND=wayland
    display=(-display gtk)
  elif [[ -n ${DISPLAY:-} || -n ${WAYLAND_DISPLAY:-} ]]; then
    display=(-display gtk)
  else
    warn "no display found — running headless (watch $WORK/serial.log)"
  fi

  git daemon --reuseaddr --base-path="$WORK/srv" --export-all --detach \
    --pid-file="$WORK/gitd.pid" "$WORK/srv"
  trap '[[ -r $WORK/gitd.pid ]] && kill "$(cat "$WORK/gitd.pid")" 2>/dev/null; rm -f "$WORK/gitd.pid"' EXIT

  rm -f "$WORK/disk.qcow2" "$WORK/serial.log"
  qemu-img create -q -f qcow2 "$WORK/disk.qcow2" "$DISK_SIZE"
  log "VM starts: CD install -> reboot -> first boot -> reboot -> i3"
  log "follow:  tail -f $WORK/serial.log"
  qemu-system-i386 -name "S2466 live test" "${accel[@]}" -smp "$SMP" -m "$MEM" \
    -vga std "${display[@]}" \
    -usb -device usb-tablet \
    -drive "file=$WORK/disk.qcow2,if=ide,format=qcow2" -cdrom "$WORK/test.iso" -boot once=d \
    -nic user,model=e1000 -serial "file:$WORK/serial.log" \
    -monitor "unix:$WORK/monitor.sock,server,nowait"
}

case ${1:-all} in
  prepare) prepare ;;
  run)     run ;;
  all)     prepare; run ;;
  *)       die "usage: $0 [prepare|run|all]" ;;
esac
