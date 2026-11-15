#!/usr/bin/env bash
# Stage 2 — turns the base system into the i3 workstation.
#
# Idempotent: change something in this repo (or /etc/system.conf), then
#   doas ~/system/bootstrap.sh            # full run
#   doas ~/system/bootstrap.sh --no-sync  # skip the portage tree sync
#   doas ~/system/bootstrap.sh --kernel   # force compiling the kernel here
#
# With BINPKGS_BRANCH set, packages and kernel come prebuilt from that branch
# (build/prebuild.sh + build/publish.sh on your PC); the tree is synced to the
# snapshot they were built against.  When kernel/*.config changed, the
# matching prebuilt kernel is installed (or, if there is none, compiled).
set -Eeuo pipefail

REPO=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
# shellcheck source=lib/system.sh
source "$REPO/lib/system.sh"
trap 'warn "bootstrap failed at line $LINENO: $BASH_COMMAND"; exit 1' ERR

[[ $EUID -eq 0 ]] || die "run as root: doas $0"
load_config "${CONF:-/etc/system.conf}"
HOME_DIR=/home/$USERNAME

SYNC=1 KERNEL=0
for a in "$@"; do
  case $a in
    --no-sync) SYNC=0 ;;
    --kernel)  KERNEL=1 ;;
    *) die "unknown option: $a" ;;
  esac
done

# ── prebuilt packages + kernel (BINPKGS_BRANCH, from build/publish.sh) ──────
PREBUILT=/var/cache/s2466-prebuilt
HAVE_PREBUILT=0

fetch_prebuilt() {
  [[ -n $BINPKGS_BRANCH && -n $REPO_URL ]] || return 0
  log "fetching prebuilt packages (branch $BINPKGS_BRANCH)"
  if [[ -d $PREBUILT/.git ]] \
     && git -C "$PREBUILT" fetch -q --depth 1 origin "$BINPKGS_BRANCH" \
     && git -C "$PREBUILT" reset -q --hard FETCH_HEAD; then
    git -C "$PREBUILT" clean -qfdx
  else
    rm -rf "$PREBUILT"
    git clone -q --depth 1 --single-branch --branch "$BINPKGS_BRANCH" -- "$REPO_URL" "$PREBUILT" \
      || { warn "no branch $BINPKGS_BRANCH at $REPO_URL — compiling everything here"; return 0; }
  fi
  HAVE_PREBUILT=1
  log "prebuilt set: tree $(cat "$PREBUILT/SNAPSHOT" 2>/dev/null || echo '?'), $(du -sh "$PREBUILT/binpkgs" | cut -f1)"
}

# ── portage ─────────────────────────────────────────────────────────────────
portage_world() {
  apply_portage_config "$REPO/portage"
  if [[ -n $PORTAGE_TMPFS ]] && ! mountpoint -q /var/tmp/portage; then
    mount /var/tmp/portage
  fi
  fetch_prebuilt
  if ((SYNC)); then
    if ((HAVE_PREBUILT)); then
      sync_tree_to "$PREBUILT/SNAPSHOT"      # same tree as the packages -> they match
    elif ! emerge --sync --quiet; then
      warn "portage sync failed — continuing with the existing tree"
    fi
  fi
  if ((HAVE_PREBUILT)); then
    log "emerge @world @s2466 from the prebuilt packages"
    PKGDIR=$PREBUILT/binpkgs emerge --usepkg --update --deep --changed-use --noreplace @world @s2466
  else
    log "emerge @world @s2466 — compiles X + i3 here (many hours on the Athlons)"
    emerge --update --deep --changed-use --noreplace @world @s2466
  fi
  emerge --depclean --quiet || true
}

# ── kernel ──────────────────────────────────────────────────────────────────
kernel() {
  local frags
  mapfile -t frags < <(kernel_fragments "$REPO")
  if ((KERNEL)) || kernel_fragment_changed "${frags[@]}"; then
    if ((KERNEL)); then
      emerge --noreplace "$KERNEL_PKG"
      build_kernel "${frags[@]}"
    else
      kernel_install_or_build "$PREBUILT/kernel" "${frags[@]}"
    fi
    grub_config
  else
    log "kernel fragment unchanged — no rebuild (use --kernel to force)"
  fi
}

# ── system ──────────────────────────────────────────────────────────────────
# PCI address of the Radeon (vendor 1002, VGA class) as Xorg wants it.
radeon_busid() {
  local addr bus dev fn
  addr=$(lspci -Dmn | awk '$2 == "\"0300\"" && $3 == "\"1002\"" {print $1; exit}')
  [[ -n $addr ]] || return 1
  bus=${addr#*:}; bus=${bus%%:*}
  dev=${addr##*:}; dev=${dev%.*}
  fn=${addr##*.}
  printf 'PCI:%d:%d:%d\n' "0x$bus" "0x$dev" "0x$fn"
}

system_config() {
  cp -rT "$REPO/rootfs" /

  mkdir -p /etc/X11/xorg.conf.d
  cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
# GENERATED from install.conf (X_KEYMAP / X_KEYVARIANT / X_KEYOPTIONS)
Section "InputClass"
    Identifier      "keyboard"
    MatchIsKeyboard "on"
    Option          "XkbLayout"  "$X_KEYMAP"
    Option          "XkbVariant" "$X_KEYVARIANT"
    Option          "XkbOptions" "$X_KEYOPTIONS"
EndSection
EOF

  local busid
  if busid=$(radeon_busid); then
    cat > /etc/X11/xorg.conf.d/20-radeon.conf <<EOF
# GENERATED: X runs on the Radeon only; the Voodoo 3 is left alone for Glide.
Section "Device"
    Identifier "radeon"
    Driver     "radeon"
    BusID      "$busid"
    Option     "AccelMethod" "EXA"
EndSection
EOF
    log "Radeon at $busid"
  else
    log "no Radeon — X uses the Voodoo 3 via vesa"
    rm -f /etc/X11/xorg.conf.d/20-radeon.conf
  fi

  # bitmap fonts (Terminus) must not be filtered out by fontconfig
  eselect fontconfig disable 70-no-bitmaps.conf >/dev/null 2>&1 || true
  eselect fontconfig disable 70-no-bitmaps-except-emoji.conf >/dev/null 2>&1 || true
  eselect fontconfig enable 70-yes-bitmaps.conf >/dev/null 2>&1 || true

  rc-update add alsasound boot >/dev/null 2>&1 || true
  rc-update add acpid default >/dev/null 2>&1 || true    # power button = clean shutdown

  # boot screen (SPLASH) + kernel cmdline changes from install.conf
  setup_splash "$REPO/post"
  grub_config

  # tty1: autologin; with the boot screen also silent (no issue/prompt text),
  # so the screen stays until X starts
  local c1="c1:12345:respawn:/sbin/agetty --noclear 38400 tty1 linux"
  if is_yes "$AUTOLOGIN"; then
    local quiet=""
    is_yes "$SPLASH" && quiet="--skip-login --nonewline --noissue "
    c1="c1:12345:respawn:/sbin/agetty --autologin $USERNAME ${quiet}--noclear 38400 tty1 linux"
  fi
  sed -i -E "s|^c1:.*|$c1|" /etc/inittab
}

# ── dotfiles: symlinked, so editing the repo is editing the live config ─────
dotfiles() {
  local src rel dst
  while IFS= read -r -d '' src; do
    rel=${src#"$REPO/dotfiles/"}
    dst=$HOME_DIR/$rel
    mkdir -p "${dst%/*}"
    if [[ -e $dst && ! -L $dst ]]; then
      mv "$dst" "$dst.pre-bootstrap"
      warn "moved existing $dst -> $dst.pre-bootstrap"
    fi
    ln -sfn "$src" "$dst"
  done < <(find "$REPO/dotfiles" -type f -print0)

  mkdir -p "$HOME_DIR/.local/share/xorg"
  chown -hR "$USERNAME:" "$HOME_DIR/.config" "$HOME_DIR/.local"
  find "$HOME_DIR" -maxdepth 1 -type l -exec chown -h "$USERNAME:" {} +
}

run() { log "== $1"; "$1"; }
run portage_world
run kernel
run system_config
run dotfiles
log "stage 2 done. Reboot (or log out on tty1) to land in i3."
