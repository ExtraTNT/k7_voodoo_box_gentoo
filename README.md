# tiger — Gentoo for the Tyan Tiger MPX S2466

You should never need this repo, it's just for setting up a old machine.

A lean 32-bit Gentoo for a retro workstation: 2× Athlon MP 2200+, 3 GB RAM,
PATA disk, Radeon 9000 Pro (X/i3) + Voodoo 3 (Glide), SB X-Fi, 3Com 3c920.

Everything is built on your PC (Linux or WSL); the Athlons compile (almost)
nothing. You need a CD-R and a git repo on any git host — no server of your own.

```
 your PC                        CD-R (stage 1)                 git host (stage 2)
 build/prebuild.sh ──┬────────▶ live CD + installer   ──────▶  master:  this repo
                     │          + prebuilt kernel               binpkgs: prebuilt X, i3, …
 iso/build-iso.sh ───┘          + stage-1 packages              (one commit, replaced)
 build/publish.sh ────────────────────────────────────────────▶
```

Everything is configured in **`install.conf`** (disk, user, keymap, git URL,
CFLAGS, USE, kernel, ISO). Edit it first.

**Where things run:** the build scripts (`build/`, `iso/`, `test/`) are Linux
scripts that need root (chroot, mounts, squashfs). On Windows they run in a
separate WSL distro, `s2466-build` — `wsl/run.sh` starts them there from Git
Bash. `bootstrap.sh` is *not* for your PC: it runs on the S2466 (stage 2).

---

## Quickstart (Windows: Git Bash + WSL)

**Once:** the build distro (Alpine, ~200 MB of tools; your other WSL distros
are not touched). In PowerShell, in the repo:
```powershell
powershell -ExecutionPolicy Bypass -File wsl\setup.ps1 -Location S:\wsl\s2466-build
```

**Then, in Git Bash, in the repo:**

1. Edit `install.conf` — at least `DISK`, `USERNAME`, keymaps, `REPO_URL`.
2. Push the repo to `REPO_URL` (empty repo on GitHub etc.):
   ```sh
   git add -A && git commit -m "my config"
   git push -u origin master
   ```
3. Prebuild packages + kernel (first time ~1 h, later minutes):
   ```sh
   ./wsl/run.sh build/prebuild.sh
   ```
4. Publish them to the `binpkgs` branch, push from here (your git credentials
   live in Git Bash):
   ```sh
   ./wsl/run.sh build/publish.sh
   git push -f origin binpkgs
   ```
5. Build the CD image → `iso/out/s2466-autoinstall.iso` (~405 MiB):
   ```sh
   ./wsl/run.sh iso/build-iso.sh
   ```
6. Optional — try it all in a VM window first (see [3](#3-live-test-vm)):
   ```sh
   ./wsl/run.sh test/live-test.sh
   ```
7. Burn the ISO to a CD-R. On the S2466: BIOS → onboard USB **off** (AMD-768
   erratum), PS/2 keyboard, primary VGA = AGP, boot CD → HDD. Boot the CD; it
   asks for the disk confirmation and passwords, installs, reboots. First boot
   shows its progress on VT 8, fetches the repo + packages, and reboots into
   i3. The box needs internet during the install.

Do 3–5 shortly before installing: the mirrors keep old portage trees and
stage3s only for a few weeks — after that the box compiles what no longer
matches. Changed `install.conf`? Commit + push it and redo step 5 (the CD
carries a copy).

On a Linux PC: same steps, run the scripts with `sudo bash SCRIPT` instead of
`./wsl/run.sh SCRIPT`.

---

## 1. Build the ISO

```sh
./wsl/run.sh build/prebuild.sh   # packages + kernel, ~1 h first time, minutes later
./wsl/run.sh iso/build-iso.sh    # -> iso/out/s2466-autoinstall.iso (fits an 80-min CD-R)
```

* `prebuild.sh` starts a **fresh i686 stage3 chroot** and does what the
  installer and `bootstrap.sh` would do, with `-march=athlon-mp`, keeping every
  binary package. Output (inside WSL): `/var/tmp/s2466-prebuilt` (stage-1
  packages, all packages, kernel, tree snapshot date). Downloads and packages
  are cached in `/var/tmp/s2466-cache`.
* `build-iso.sh` takes the official Gentoo x86 minimal ISO (verified), adds
  the installer, `install.conf`, the prebuilt kernel and stage-1 packages,
  drops live-CD firmware this board does not need, and adds a default boot
  entry *Auto-install* (the stock live-CD entries stay).

## 2. Build the git repo

```sh
git push -u origin master          # the repo itself
./wsl/run.sh build/publish.sh      # prebuilt packages -> local branch 'binpkgs'
git push -f origin binpkgs
```

* **`master`** — this repo: config, `bootstrap.sh`, dotfiles, portage config.
  Cloned to `~/system` on the box.
* **`binpkgs`** — output of `prebuild.sh`: one commit without history,
  replaced on every publish, so old packages never pile up. Stage 2 installs
  from it and syncs the portage tree to the same snapshot, so the packages
  match. Only what does not match is compiled on the Athlons.

**Later updates:** change things here → `prebuild.sh` → `publish.sh` → push
both branches. On the box:
```sh
cd ~/system && git pull && doas bash bootstrap.sh     # alias: up
```

## 3. Live test (VM)

```sh
./wsl/run.sh test/live-test.sh             # prepare + run
./wsl/run.sh test/live-test.sh run         # boot again with a fresh disk
./wsl/run.sh REBUILD=1 test/live-test.sh   # also redo the test prebuild
```

Builds a test variant of everything below `/var/tmp/s2466-test` (inside WSL)
and runs the whole flow in QEMU (KVM, 3 GB RAM, IDE): CD install → first boot
→ i3, unattended, ~20 min. The window shows up on the Windows desktop through
**WSLg** — leave it open; closing it ends the VM. Progress also goes to
`/var/tmp/s2466-test/serial.log`.

* Your `install.conf` + overrides: unattended wipe, serial console, and the
  repo served by a local `git daemon` instead of the git host.
* Login in the VM: your `USERNAME` / `test` (root: `test`). First boot shows
  its progress on VT 8 (Alt+F1: login); autologin + i3 come after its reboot.
* In the window: **CapsLock is Meta** (Windows keeps the Win key for itself),
  the mouse is a USB tablet (no drift), **Ctrl+Alt+G** grabs the keyboard so
  other combos reach the VM.
* Kernel = `kernel/s2466.config` + `kernel/qemu-test.config`: modern CPUs
  have no 3DNow! (a K7 kernel uses it), and QEMU needs its own disk, NIC and
  VGA drivers. The packages are the real ones (`-march=athlon-mp`).

---

## Build environment

`wsl/setup.ps1` creates the distro (Alpine minirootfs, checksum verified,
`wsl --import`) and installs: bash, coreutils, util-linux, GNU tar, xz,
wget/curl, git + git-daemon, xorriso, squashfs-tools, QEMU with GTK window.
Running it again only reinstalls the packages. `wsl/run.sh` maps the repo
path (`A:\…` → `/mnt/a/…`) and runs the script there as root; set
`S2466_WSL` for another distro name. Everything lives in the distro's disk
(`/var/tmp/s2466-*`, ~15 GB after a live test).

Remove it all: `wsl --unregister s2466-build`.

## Files

| Path | What |
|---|---|
| `install.conf` | **the** config |
| `build/prebuild.sh`, `build/publish.sh` | prebuild packages + kernel; put them into `binpkgs` |
| `iso/build-iso.sh` | builds the installer ISO |
| `test/live-test.sh` | the VM test |
| `wsl/setup.ps1`, `wsl/run.sh` | create the WSL build distro; run a script in it from Git Bash |
| `installer/` | stage 1 (live CD + chroot) and the first-boot launcher |
| `bootstrap.sh` | stage 2, idempotent — re-run after every change |
| `lib/` | shared code: config, make.conf, kernel, GRUB, tree sync |
| `kernel/` | kernel fragment for this board + the VM layer |
| `portage/` | copied over `/etc/portage`: USE, keywords, sets `@s2466` / `@dev` |
| `post/` | the boot screen (`s2466-post` + its OpenRC service) |
| `rootfs/` | files copied to `/` (sysctl, BFQ udev rule) |
| `dotfiles/` | symlinked into `$HOME` — edit here, it is live |

## The system

**Boots fast:** no initramfs (everything for `/` built in, `root=PARTUUID=`),
GRUB without menu (hold Shift), OpenRC in parallel, DHCP in the background,
no logger/cron/netmount, root on the fast outer tracks, tty1 autologin →
`startx` → i3, `urxvtd`, core X fonts, BFQ.

**Boot screen** (`SPLASH="yes"`, `post/`): no boot chatter. The kernel is
quiet, OpenRC's normal output goes to `/var/log/rc.log` (its warnings and
errors still show), and early in the boot `s2466-post` clears the screen and
lists, POST-style, what was found — every CPU with its data, RAM, disks,
CD drives, both graphics cards, sound, network — plus the kernel's warnings
(yellow) and errors (red). With autologin it stays until X starts, and you
see it again after leaving X. Run `s2466-post` any time.

**The rice:** i3 with 1 px borders, no title bars, i3bar + i3status on top,
urxvt, rofi (launcher + window switcher), tmux, vim. Charcoal `#121212`, one
amber accent `#d7a65f`, Terminus 16 everywhere.

| Keys | |
|---|---|
| `Meta+Enter` / `Meta+Shift+q` | terminal / close |
| `Meta+d` / `Meta+Tab` | rofi: apps + commands / windows (`Shift+←→` switches) |
| `Meta+h j k l` / `+Shift` | focus / move |
| `Alt+h j k l` (or arrows) | resize |
| `Meta+b` `v` `w` `e` `f` | split h / split v / tabbed / toggle split / fullscreen |
| `Meta+1…5` / `+Shift` | workspace / move to workspace |
| `Meta+Shift+r` / `Meta+Shift+e` | restart i3 / leave X |

**Meta is CapsLock** (`X_KEYOPTIONS="caps:super"`): the IBM 6323 has no Win
key, and right Alt is AltGr on the Swiss layout. On a keyboard with Win keys,
empty `X_KEYOPTIONS` and Win works as Meta. `touch ~/.nox` to stay on the console.

**Glide:** the kernel leaves `/dev/mem` and `iopl()` unrestricted and has no
`tdfxfb`, so the Voodoo 3 is free; X runs only on the Radeon (PCI address
pinned in `/etc/X11/xorg.conf.d/20-radeon.conf`). Next: `doas emerge @dev`,
build glide3x for `h3`, e.g. <https://github.com/Danaozhong/3dfx-Glide-API>,
run fullscreen as root.

## Limits of this CPU (no SSE2)

* **Rust** on 32-bit x86 needs SSE2 → `USE=-rust`; anything that *requires*
  Rust (librsvg, Firefox, …) is out. Git 3.0 plans to require Rust.
* No 3D on the Radeon 9000 in current Mesa (r200 left with Mesa 22); 2D is fine.
* `app-admin/doas` is only `~x86` (see `portage/package.accept_keywords`).

## Notes

* The ISO contains `install.conf` — incl. password hashes if you set any.
  Keep it private, or leave them empty (the installer asks).
* A private repo needs credentials in `REPO_URL` (`https://user:token@…`);
  they end up on the CD and the box.
* Boot options: `ai.conf=http://…/install.conf` overrides the baked-in
  config; `ai.serial` mirrors installer and first boot to COM1.
* Re-running `autoinstall` after a failure resumes; finished steps are skipped.
