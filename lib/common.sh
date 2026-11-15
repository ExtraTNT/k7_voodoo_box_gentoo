# shellcheck shell=bash
# Shared helpers: logging, config, resumable steps, downloads.
# Sourced by the stage-1 installer (live ISO + chroot) and by bootstrap.sh.

log()  { printf '\033[1;32m>>>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }

# ── config ─────────────────────────────────────────────────────────────────
conf_defaults() {
  : "${DISK:=/dev/sda}" "${SWAP_SIZE:=2GiB}" "${ROOT_MKFS_OPTS:=}"
  : "${ROOT_MOUNT_OPTS:=noatime}" "${PORTAGE_TMPFS=}"
  : "${HOSTNAME:=gentoo}" "${TIMEZONE:=UTC}" "${LOCALE:=en_US.UTF-8}"
  : "${KEYMAP:=us}" "${X_KEYMAP:=us}" "${X_KEYVARIANT:=}" "${X_KEYOPTIONS:=}"
  : "${USERNAME:=user}" "${USER_PASSWORD_HASH:=}" "${ROOT_PASSWORD_HASH:=}"
  : "${SSH_AUTHORIZED_KEY:=}" "${AUTOLOGIN:=yes}" "${NTP_SERVER:=pool.ntp.org}"
  : "${GENTOO_MIRROR:=https://distfiles.gentoo.org}" "${STAGE3_FLAVOR:=i686-openrc}"
  : "${STAGE3_URL:=}" "${PROFILE:=default/linux/x86/23.0/i686}"
  : "${OFFICIAL_BINHOST:=yes}" "${BINPKGS_BRANCH=binpkgs}" "${ISO_FIRMWARE_KEEP=radeon}"
  : "${REPO_URL:=}" "${REPO_BRANCH:=master}" "${REPO_NAME:=system}"
  : "${FIRSTBOOT_BOOTSTRAP:=yes}" "${FIRSTBOOT_REBOOT:=yes}"
  : "${COMMON_FLAGS:=-O2 -pipe -march=i686}" "${MAKEOPTS:=-j2}"
  : "${CPU_FLAGS_X86:=}" "${USE_FLAGS:=-rust}" "${VIDEO_CARDS:=}"
  : "${INPUT_DEVICES:=libinput}" "${L10N:=en}"
  : "${ACCEPT_LICENSE:=-* @FREE @BINARY-REDISTRIBUTABLE}"
  : "${KERNEL_PKG:=sys-kernel/gentoo-sources}" "${KERNEL_FRAGMENT:=kernel/s2466.config}"
  : "${KERNEL_CMDLINE:=quiet}" "${GRUB_TIMEOUT:=0}"
  : "${SPLASH:=yes}"
  : "${AUTO_CONFIRM:=no}"
}

conf_validate() {
  [[ $HOSTNAME =~ ^[a-zA-Z0-9-]{1,63}$ ]]  || die "HOSTNAME invalid: $HOSTNAME"
  [[ $USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "USERNAME invalid: $USERNAME"
  [[ $REPO_NAME =~ ^[A-Za-z0-9._-]+$ ]]    || die "REPO_NAME invalid: $REPO_NAME"
  [[ -z $BINPKGS_BRANCH || $BINPKGS_BRANCH =~ ^[A-Za-z0-9._/-]+$ ]] || die "BINPKGS_BRANCH invalid"
  [[ $GRUB_TIMEOUT =~ ^[0-9]+$ ]]          || die "GRUB_TIMEOUT must be a number"
  [[ $SWAP_SIZE == 0 || $SWAP_SIZE =~ ^[0-9]+(KiB|MiB|GiB)$ ]] \
    || die "SWAP_SIZE must be 0 or like 2GiB / 512MiB"
  [[ $TIMEZONE =~ ^[A-Za-z0-9_+/-]+$ ]] || die "TIMEZONE invalid: $TIMEZONE"
  # whether the zone exists is checked on the target (the live CD has no full tzdata)
}

load_config() {
  local f=$1
  [[ -r $f ]] || die "config not found: $f"
  # shellcheck source=/dev/null
  source "$f"
  conf_defaults
  conf_validate
}

is_yes() { [[ ${1,,} == y || ${1,,} == yes || ${1,,} == true || $1 == 1 ]]; }

# /dev/sda + 1 -> /dev/sda1 ; /dev/nvme0n1 + 1 -> /dev/nvme0n1p1
part() { if [[ $DISK =~ [0-9]$ ]]; then echo "${DISK}p$1"; else echo "${DISK}$1"; fi; }

# ── resumable steps ────────────────────────────────────────────────────────
# A step that finished leaves $STATE/<name>.done; re-running skips it.
run_step() {
  local name=$1; shift
  if [[ -e $STATE/$name.done ]]; then log "skip: $name (already done)"; return 0; fi
  log "step: $name"
  "$@"
  mkdir -p "$STATE"
  : > "$STATE/$name.done"
}

# ── downloads ──────────────────────────────────────────────────────────────
fetch() { # URL DEST
  if command -v wget >/dev/null; then wget -q -O "$2" "$1"
  else curl -fsSL -o "$2" "$1"; fi
}
fetch_stdout() { # URL
  if command -v wget >/dev/null; then wget -q -O - "$1"
  else curl -fsSL "$1"; fi
}

# Resolve the newest file from a Gentoo latest-*.txt index (PGP-signed text).
gentoo_latest() { # INDEX_URL -> prints the full URL of the newest artifact
  local index=$1 rel
  rel=$(fetch_stdout "$index" | awk '!/^#/ && $1 ~ /\.(tar\.xz|iso)$/ {print $1; exit}') \
    || die "cannot read $index"
  [[ -n $rel ]] || die "no entry in $index"
  echo "${index%/*}/$rel"
}

# Check FILE against a Gentoo .DIGESTS file (contains SHA512 + BLAKE2B lines).
verify_digests() { # FILE DIGESTS
  local h
  h=$(sha512sum "$1" | cut -d' ' -f1)
  grep -qi "^$h " "$2" || die "SHA512 mismatch for $1"
  log "SHA512 ok: ${1##*/}"
}
