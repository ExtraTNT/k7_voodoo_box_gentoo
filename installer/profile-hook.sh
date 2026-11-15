# shellcheck shell=sh
# /etc/profile.d/zz-autoinstall.sh on the live CD.
# The live CD auto-logs root in on every tty; start the installer once, on
# tty1, and only when the boot entry passed 'autoinstall'.
if [ "$(tty)" = /dev/tty1 ] && [ "$(id -u)" = 0 ] && [ ! -e /run/autoinstall.started ] \
   && grep -qw autoinstall /proc/cmdline; then
  : > /run/autoinstall.started
  /usr/local/sbin/autoinstall
fi
