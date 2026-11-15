#!/usr/bin/env bash
# Stage 1, part B — runs INSIDE the chroot (/mnt/gentoo).
# Base system only: portage config, kernel, GRUB, users, network, git, and the
# first-boot hook that hands over to bootstrap.sh from the system repo.
set -Eeuo pipefail

PAYLOAD=/root/autoinstall
# shellcheck source=../lib/common.sh
source "$PAYLOAD/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$PAYLOAD/lib/system.sh"
trap 'warn "chroot step failed at line $LINENO: $BASH_COMMAND"; exit 1' ERR

set +u; source /etc/profile; set -u
load_config /etc/system.conf
STATE=/var/lib/autoinstall

# build in RAM during the install too
if [[ -n $PORTAGE_TMPFS ]] && ! mountpoint -q /var/tmp/portage; then
  mkdir -p /var/tmp/portage
  mount -t tmpfs -o "size=$PORTAGE_TMPFS,uid=portage,gid=portage,mode=775" tmpfs /var/tmp/portage
fi

CD=/var/cache/s2466-cd                # prebuilt kernel + stage-1 packages from the CD
step_sync()    { sync_tree_to "$CD/SNAPSHOT"; }
step_profile() { eselect profile set "$PROFILE"; }

step_locale() {
  [[ -e /usr/share/zoneinfo/$TIMEZONE ]] || die "TIMEZONE unknown: $TIMEZONE"
  ln -sf "../usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  printf '%s %s\n' "$LOCALE" "${LOCALE##*.}" > /etc/locale.gen
  locale-gen
  eselect locale set "$LOCALE" 2>/dev/null || eselect locale set "${LOCALE%%.*}.utf8"
  env-update
}

# keep this list in sync with build/prebuild-chroot.sh
step_base_pkgs() {
  # busybox: ntpd for the one-shot clock sync (50-ntp.start)
  local pkgs=(sys-boot/grub dev-vcs/git net-misc/dhcpcd app-admin/doas sys-apps/pciutils sys-apps/busybox)
  [[ -n $SSH_AUTHORIZED_KEY ]] && pkgs+=(net-misc/openssh)
  if [[ -d $CD/binpkgs ]]; then
    PKGDIR=$CD/binpkgs emerge --usepkg --noreplace "${pkgs[@]}"
  else
    emerge --noreplace "${pkgs[@]}"
  fi
}

step_system() {
  echo "hostname=\"$HOSTNAME\"" > /etc/conf.d/hostname
  echo "$HOSTNAME" > /etc/hostname
  grep -qw "$HOSTNAME" /etc/hosts || echo "127.0.1.1  $HOSTNAME" >> /etc/hosts
  sed -i "s/^keymap=.*/keymap=\"$KEYMAP\"/" /etc/conf.d/keymaps

  # boot speed: start services in parallel, never wait for DHCP / NFS
  sed -i 's/^#\?rc_parallel=.*/rc_parallel="YES"/' /etc/rc.conf
  grep -q '^background' /etc/dhcpcd.conf \
    || printf '\n# S2466: do not block boot on DHCP\nbackground\nnoarp\n' >> /etc/dhcpcd.conf
  rc-update add dhcpcd default
  rc-update del netmount default 2>/dev/null || true

  # clock: set once per boot in the background, no daemon
  cat > /etc/local.d/50-ntp.start <<EOF
#!/bin/sh
# GENERATED: set the clock once per boot (busybox ntpd, no daemon)
( busybox ntpd -n -q -p "$NTP_SERVER" >/dev/null 2>&1 && hwclock -wu ) &
EOF
  chmod 755 /etc/local.d/50-ntp.start

  echo "permit :wheel" > /etc/doas.conf
  chmod 400 /etc/doas.conf
}

step_users() {
  local groups=() g
  for g in wheel audio video input; do getent group "$g" >/dev/null && groups+=("$g"); done
  id "$USERNAME" &>/dev/null \
    || useradd -m -s /bin/bash -G "$(IFS=,; echo "${groups[*]}")" "$USERNAME"
  [[ -s $PAYLOAD/pw-hash  ]] && chpasswd -e < "$PAYLOAD/pw-hash"
  [[ -s $PAYLOAD/pw-plain ]] && chpasswd    < "$PAYLOAD/pw-plain"
  if ! grep -qs '^root:' "$PAYLOAD/pw-plain" "$PAYLOAD/pw-hash"; then
    passwd -l root >/dev/null
    log "root locked — use doas"
  fi
}

step_ssh() {
  local home=/home/$USERNAME
  install -d -m 700 -o "$USERNAME" -g "$(id -gn "$USERNAME")" "$home/.ssh"
  printf '%s\n' "$SSH_AUTHORIZED_KEY" > "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
  chown "$USERNAME:" "$home/.ssh/authorized_keys"
  mkdir -p /etc/ssh/sshd_config.d
  printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' \
    > /etc/ssh/sshd_config.d/10-s2466.conf
  rc-update add sshd default
}

step_firstboot() {
  install -m 755 "$PAYLOAD/installer/firstboot" /usr/local/sbin/firstboot
  if is_yes "$FIRSTBOOT_BOOTSTRAP"; then
    install -m 755 "$PAYLOAD/installer/90-firstboot.start" /etc/local.d/90-firstboot.start
  fi
}

step_repo() {
  local dest=/home/$USERNAME/$REPO_NAME
  [[ -n $REPO_URL ]] || { warn "REPO_URL empty — no stage 2"; return 0; }
  [[ -d $dest/.git ]] && return 0
  if ! runuser -u "$USERNAME" -- env HOME="/home/$USERNAME" \
         git clone -q --branch "$REPO_BRANCH" -- "$REPO_URL" "$dest"; then
    warn "clone of $REPO_URL failed — firstboot will retry"
  fi
}

# not a step: cheap and idempotent, so fixes to portage/ apply on resume too
log "portage config"
apply_portage_config "$PAYLOAD/portage"
run_step sync      step_sync
run_step profile   step_profile
run_step locale    step_locale
run_step base-pkgs step_base_pkgs
mapfile -t FRAGMENTS < <(kernel_fragments "$PAYLOAD")
run_step kernel    kernel_install_or_build "$CD/kernel" "${FRAGMENTS[@]}"
run_step fstab     write_fstab
run_step grub      install_grub
run_step system    step_system
run_step splash    setup_splash "$PAYLOAD/post"
run_step users     step_users
[[ -n $SSH_AUTHORIZED_KEY ]] && run_step ssh step_ssh
run_step firstboot step_firstboot
run_step repo      step_repo

mountpoint -q /var/tmp/portage && umount /var/tmp/portage
rm -rf "$CD"                          # copied from the CD, no longer needed
log "chroot part done"
