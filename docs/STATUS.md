# Status

What's built and working, what's known-broken, what's still source-only.
Full docs live at arctic-docs.apiwow.net — this file is the terse engineering
log, not a tutorial.

Release label: **Arctic Linux - Alpha v.1** (`alpha-v1`). That exact string is
what the ISO filename, the volume id, `/etc/arctic-release`, the boot banner
and `arcticfetch` all show; nothing spells its own variation of it.

## Core system

- glibc 2.44, merged-`/usr`, built from source. No binary in the image needs
  a host library.
- busybox 1.38.0 + toybox 0.8.14 (statically linked), zsh, doas, libarchive,
  mandoc, bmake, byacc, netbsd-curses, libxcrypt, libmd, zlib, xz, zstd, curl.
- Kernel 7.1.3 (Gentoo dist-kernel config + Arctic delta: no BTF/DWARF, no
  module signing, storage/USB/squashfs/overlayfs in-tree). Flavors: base,
  libre, small (monolithic, no module loader), lts, rt, hardened.
- Arctic-minimal ISO, hybrid BIOS+UEFI, boot-tested in QEMU: Limine → kernel →
  initramfs → squashfs+tmpfs overlay → switch_root → busybox init → zsh.
- alpm: fetch, dependency resolution, ins/reins/del/del+deps with orphan
  cleanup, ins -nomod + commit for staged installs, verify, rollback
  (btrfs-snapshot and file-replace based), doctor, why, owns, search, stats.
  POSIX sh, and it stays that way.
- **Networking**: NetworkManager + nmtui, replacing iwd/iwctl entirely
  (`ports/main/networkmanager`, built without systemd/selinux/polkit -
  `doas nmtui` is how you reconfigure it as a regular user). wpa_supplicant
  is its wifi backend, not a competing option any more. `arctic-install`
  writes connection profiles straight into
  `/etc/NetworkManager/system-connections/*.nmconnection` for A_NET=wifi/
  static; A_NET=dhcp/offline leaves NetworkManager to auto-configure a wired
  link itself, same as the old rc.d/network default did. The live/installer
  image does **not** carry NetworkManager - too big a dependency tree to
  hand-build this early - it ships wpa_supplicant + a `wifi-connect <ssid>
  <psk>` wrapper instead, just enough to get an install-time link up.
  rc.d/network still exists but is live-image-only now (wired DHCP, no
  wifi/static branches); installed systems never enable it.

## Packages and repositories

Binaries and recipes are on separate hosts and never mix:

- **pkg-arctic.apiwow.net** serves `.alpmz` binaries only - main, extra,
  base, kernels, profile, nonfree, alt-nonfree, multilib. This is what
  `/etc/alpm/repos.d` points at.
- **ports-arctic.apiwow.net** serves recipes only, as
  `ALL/<repo>/<name>/recipe`. alpm reaches it through `ALPM_PORTS`, not
  through repos.d, so "what can be installed" and "what can be compiled" are
  never the same list. `alpm ins -s` and `alpm get -s` are the only things
  that touch it.

`build/publish-pkgs.sh` and `build/publish-ports.sh` generate both sites from
what is actually in the tree - indexes and directory listings alike - so a
repository cannot advertise a package it does not host. `linux-firmware` is
the one deliberate omission: at 162 MiB it is past the mirror's file size
limit and comes off the ISO instead.

Every repository is mirrored to Codeberg as well as GitHub;
`build/mirror-codeberg.sh` pushes all six in one command.

## Installer

Fully declarative, no menus. Edit `/etc/arctic/install.conf`, run
`arctic-install`. Setting `A_DISK=/dev/sdX` partitions, formats, installs
the base system and the bootloader in one shot, after a confirmation
prompt; leaving it unset and setting `A_ROOT_PART`/`A_BOOT_PART` instead
uses partitions made ahead of time. Either way there is no target
directory to mount and keep in sync by hand — that is internal to the
tool now.

`arctic-install` and `arctic-boot-strap` are the only install-time
binaries. The old interactive `arctic-conf`/`arctic-boot-conf` TUI tools
are gone — partitioning logic moved into `arctic-install` itself, driven
by the config file instead of menu answers.

Declarative system management on top of that, once installed:

- `arctic-rebuild` — reconciles the running system to `/etc/arctic/system.conf`
  (installs what's newly listed, removes what's no longer listed, same
  relationship NixOS's `configuration.nix` has to `nixos-rebuild switch`).
  First run with an empty config seeds it from what's actually installed
  instead of removing everything.
- `arctic-shell [--network] [--keep] <pkgs> [-- cmd | - cmd]` — ephemeral
  package environments, content-addressed by package set so the same request
  reuses a previous build.
- `arctic gc` — prunes the package cache, orphaned deps, and unused shell
  environments.

## Init systems

busybox init is the default and what every `/etc/rc.d` script is written
against. `A_INIT` also takes openrc, sysvinit, runit, dinit and nitro; all
five have real binary packages in `main`.

`arctic-init-setup` translates `/etc/rc.d` into whichever init is chosen -
openrc-run scripts plus runlevel links, LSB scripts plus rc3.d/rc5.d links,
runit `sv` directories plus stages 1/2/3, dinit service files plus `boot.d`,
or nitro service directories plus `SYS`. A service stays a one-file change in
`/etc/rc.d` rather than five hand-maintained copies.

nitro's translation was verified by running nitro as a supervisor over a
generated tree: a supervised daemon reaches UP and `nitroctl down` stops it, a
scripted service becomes a ONESHOT, and a service with a `down` file stays
DOWN until brought up by hand. The other four are verified by inspection of
what they generate; a full QEMU boot per init is **not** done yet.

`service` refuses to guess: on a system running dinit/openrc/runit/nitro it
hands the verb to that init's own tool rather than driving `/etc/rc.d` behind
its back. Which init a system uses comes from `/etc/arctic/init` first and
pid 1 second - inside a chroot, `/proc/1` is the *host's* init and answering
from it is wrong exactly when someone is repairing services by hand.

## Building

Every build goes through `build/arctic-sandbox` (bubblewrap: the whole host
read-only, only the build and source trees writable). `arctic-sandbox
--check` proves it still holds, including that a `mount -o remount,rw` from
inside is refused.

`alpm-build` keeps a **build sysroot** at `$ALPM_SYSROOT`: every package it
produces is unpacked there and later builds compile and link against it
(`PKG_CONFIG_PATH`, `ACLOCAL_PATH`, `PATH`, `-isystem`, `-L`,
`-Wl,-rpath-link`). Each `.pc` file is rewritten as it lands so its absolute
paths point into the sysroot rather than at `/usr` on the build host.

## Known-fixed bugs worth remembering

- **The live image had no network at all.** Only `lo` came up, and every
  network repository was "unreachable". Nothing loaded a driver for hardware
  that was already present at boot: mdev only fires for devices that appear
  afterwards, and udev - which coldplugs on other systems - is not what
  Arctic runs, so e1000, virtio_net and r8169 sat unused in
  `/usr/lib/modules`. rc.boot walks every modalias under `/sys` now.
  Verified in QEMU: `e1000: eth0 NIC Link is Up`, DHCP lease, default route
  and a nameserver, where before there was nothing but `lo`.
- **curl on the live image could not start.** First
  `libnghttp2.so.14: cannot open shared object file`, then after fixing the
  recorded dependencies, `libidn2.so.0`. A package's recorded dependency
  list is what the manifest says, not what the compiler actually linked.
  mkiso resolves the recorded dependencies *and* then closes over real
  linkage - every DT_NEEDED under the image, against a soname-to-package
  index built from the repository - so a library the metadata never
  mentioned still lands on the image. curl is what fetches every https
  repository, so both times the whole network side of the image was dead.
- **The initramfs was 4 KB and could not boot anything.**
  `find -print0 | cpio --null` - `--null` is GNU cpio only, the cpio an
  Arctic system has rejects it, and with its error discarded xz happily
  compressed an empty stream. Newline-separated names now, and it refuses
  to leave an implausibly small image behind rather than discovering it at
  the next boot.
- **Every transaction ended by printing an error after its success line.**
  `head -n -20`, used to prune old transactions, is a GNU extension; toybox
  answers `head: -n < 0`. Counted first, then asked for a positive number.
- **An upgrade could strand itself halfway.** Fetch and install were
  interleaved, so a transaction upgrading a library the downloader links
  against - libressl, say - left the curl on disk missing the soname it was
  built for, and every package still to come failed to download. Everything
  is fetched first now, then installed.
- **`alpm ins -s` built the package and threw it away.** It looked for the
  result under `$ALPM_CACHE/build/out` while alpm-build writes to
  `$ALPM_BUILDROOT/out` - the same path only when `ALPM_BUILDROOT` is unset.
  Any scratch root or batch build ended in "build produced no package"
  immediately after a successful compile.
- **`fix_usrmerge` overwrote its caller's loop variable.** It used a bare
  `p` for the path it was repairing, and it is called from `install_one`,
  which runs inside a `for p in ...` loop over package names. A single
  install only showed it in the closing line ("/usr/sbin built from source
  and installed"); installing several from source in one command operated on
  the wrong name from the second onwards.
- **`alpm owns` exited 1 after printing the right answer**, because the
  function ended on a test that is false when the file *was* found.
- **`alpm commit` activated the package and then reported failure**, dying
  under `set -u` on `HOOK_KERNEL: unbound variable` - `run_hooks` reads it
  and only some commands set it first.
- **A dependency-free package was permanently unsatisfied.** The index's `-`
  placeholder for "no dependencies" was written through to DEPS as though it
  were a package name, so `doctor` reported an unsatisfied dependency named
  `-` on a healthy system.
- **The resolver printed a shell error over its own progress bar.**
  `can't open .../DEPS: no such file` - a failed input redirection is the
  shell's own error, which `2>/dev/null` on the command does not silence.
  The entries with no DEPS were the live image's, which wrote PKGINFO and
  FILES but never DEPS.

- **A directory under `local/` counted as an installed package.**
  `is_installed()` tested `[ -d "$ALPM_DB/local/$1" ]`, and `install_one`
  wrote PKGINFO *first*, so an install that died or was interrupted anywhere
  after `mkdir` left an entry that every later command believed. `alpm ins
  vim` reported vim already installed while `alpm deps vim` died on the DEPS
  file that never got written, and the resolver counted it as satisfied for
  everything that needed it. Fixed by assembling the entry in
  `local/.incoming-<pkg>` and moving it into place with PKGINFO written last,
  keying `is_installed()` on PKGINFO, and having `doctor` find and offer to
  remove entries left by older versions. Verified by creating the exact
  wreckage - a `local/nano/` with no PKGINFO - and re-running all three
  commands.
- **`alpm fetch all` reported four of eight repositories unreachable.** The
  live image had no curl and no CA bundle, and toybox's wget answers every
  `https://` URL with "unsupported protocol". The four that appeared to work
  were the ones the ISO carries on the medium over `file://`. Fixed by adding
  curl and ca-certificates to the live image's tools and to the `base` meta
  package.
- **Every source-build fetch died with "unknown wget option q".** toybox wget
  implements `--max-redirect`, `-d`, `-O` and `-p`, and nothing else; the
  downloader passed `-q -O`. `-O` is the one output flag toybox, busybox and
  GNU wget all agree on, so quietness comes from a redirect now. Confirmed
  against the real toybox binary rather than from the man page.
- **`alpm ins alacritty` offered to compile a package that had a binary.**
  Two causes. The index was stale because of the https failure above, and a
  missing *dependency* was reported as if the requested package itself were
  unavailable. alpm now refuses to run at all without an index ("run 'alpm
  fetch all' first"), only offers compilation when no synced repository has a
  binary, and names the chain when a dependency is missing: "alacritty needs
  wayland, and no synced repository has it".
- **Kernel packages could not be installed by the name everything documented.**
  They were built as `Arctic-base-kernel` while `install.conf`, the docs and
  every other package used lowercase. Standardised on lowercase, including
  rewriting the name inside the already-built `.alpmz` files - renaming the
  file is not enough, `install_one` takes the name from `.PKGINFO`.
- **Installing a kernel re-fetched glibc on a system that already had it.**
  Resolution skipped already-satisfied packages silently, so a re-fetch and a
  correct skip looked identical. Satisfied dependencies now print
  `Dependency met 'glibc', skipping...` and are left alone.
- **A build could not use a package Arctic had just built.** Builds saw only
  the host's headers and libraries. libxcb failed every attempt with
  `IndexError: list index out of range` because `c_client.py` could not see
  xcb-proto's XML, and anything that did build linked against whatever the
  host happened to have. Fixed by the build sysroot described above; libxcb
  builds.
- **`alpm-build` reused `$srcdir` between builds.** Only `$pkgdir` was wiped,
  so every attempt inherited the last one's object files: bzip2's shared
  library failed with "recompile with -fPIC" against objects that predated
  the flag being passed at all. Both trees are wiped now - the tarballs are
  cached separately, so re-extracting costs nothing.
- **`build-batch.sh` skipped packages it had never built.** It tested
  `<name>-*.alpmz`, so `wayland-protocols-1.48-1.x86_64.alpmz` answered for
  `wayland`: wayland was reported "already built" on every run while nothing
  provided it. Matched on the decoded package name now.
- **`--cap-drop ALL` in the sandbox broke every source build.** Dropping
  CAP_CHOWN/CAP_FOWNER/CAP_DAC_OVERRIDE turned tarball extraction into a wall
  of "Can't set user=1000/group=1000" and "Can't unlink already-existing
  object". Narrowed to CAP_SYS_ADMIN and CAP_SYS_MODULE, which is what closes
  the remount-read-write escape; `--check` still proves the remount is
  refused.
- **`service` reported a service as "stopped" when it was not installed at
  all.** `exists()` only checked that the rc.d script was executable, and
  every Arctic install ships `/etc/rc.d/sddm` whether or not sddm is there.
  It reads the script's `CMD` (without sourcing it - sourcing runs the
  service) and reports "not installed" with the missing path, exit 4.
- **`service` died silently without `/etc/arctic/rc.lib`.** `.` is a special
  builtin: a shell that cannot open the file exits on the spot, so the
  `|| fallback` after it never ran. Tested before sourcing now.
- **`alpm-repo add` wrote a predictable file into /tmp as root.**
  `/tmp/.alpmrepo.$$` could be pre-created as a symlink by any local user and
  the tool would truncate whatever it pointed at. The value it wanted was one
  line of a `.PKGINFO` it already had in a variable.
- **The installer's log was a predictable path in a world-writable
  directory.** `/tmp/arctic-install.log`, written as root. It goes to
  `/run/arctic/install.log` when /run is available, and is `rm -f`'d before
  creation either way, which removes a symlink rather than following it.
- **A fresh install could never `alpm fetch` main/kernels/profile again.**
  mkiso bundles those repos on the medium so `arctic-install` works with no
  network, pointing them at `file:///run/arctic/medium/...` and disabling the
  matching network repo - with a comment saying arctic-install would re-enable
  the network one once installed. That step never existed. Every install left
  the new system pointing at a mount that stops existing when the disc comes
  out. Fixed by doing what the comment already promised, once at the very end
  of the install.
- **`ALPM_DB`/`ALPM_CACHE`/`ALPM_LOG` were never derived from `ALPM_ROOT`.**
  Every `--root`-style install recorded its package database into the
  *caller's* `/var/lib/alpm`. A freshly installed system's own database would
  be empty on first boot despite every file being in place.
- **`alpm.conf` could silently override an explicit `ALPM_ROOT`.**
  `alpm_load_conf()` sourced the config unconditionally; a plain `ALPM_ROOT=/`
  line in it beat whatever a caller had exported. Caller-set values are
  preserved across the config load now.
- **alpm's dispatcher only read `argv[1]` as the subcommand.** `alpm -y ins
  vim` was parsed as an unknown command. All arguments are scanned for global
  flags regardless of position.
- **cryptsetup couldn't run at all.** Missing `libpopt.so.0` — nothing in the
  manifest ever built popt. Added it as its own port.
- **Rust packages failed to build almost universally.** `--offline` with no
  vendored dependency tree, then `CARGO_HOME` defaulting under `/root`, then a
  hardcoded `clang`/`lld` linker that isn't installed on the build host. All
  three fixed in the shared template. Builds now get a `HOME` inside the build
  tree for the same reason - harfbuzz's g-ir-scanner died on
  "Invalid cross-device link" trying to write `/root/.cache`.
- **GitHub-archive source tarballs extracting to unexpected directory names.**
  The recipe generator guessed the directory from the tarball's filename,
  which is only right when the tag is a bare version: libxkbcommon tags
  `xkbcommon-1.13.2` and unpacks into `libxkbcommon-xkbcommon-1.13.2`, and a
  Forgejo archive (codeberg) unpacks into a bare `<repo>/` with no version at
  all. The repo name is taken from the URL now.
- **vim linked against the build host's GTK3/dbus/elogind stack** because its
  configure auto-detects a GUI toolkit off the host. Built with
  `--enable-gui=no --without-x` now.
- **nano crashed at startup with "undefined symbol: key_defined".** Its build
  auto-detected the host's real ncurses (same SONAME netbsd-curses uses) which
  does implement that extension, while Arctic's does not.

## Known rough edges

- **The desktop profiles do not install yet.** `arctic-xfce`, `arctic-kde`,
  `apiwow-dwm`, `arctic-sound` and `niri-dms` are meta-packages whose
  dependencies are still being built. What exists so far: dwm, dwl, st, foot,
  picom, feh, slock, slstatus, dmenu, wayland, libxkbcommon, libxcb,
  xcb-proto, xorgproto, xorg-server, xorg-xinit, libinput, pipewire,
  harfbuzz, lua, imath, bzip2. Still missing, and the reason each profile
  fails today: mesa, noto-fonts, fcft, libconfig, libev for the X profiles;
  wireplumber for audio; the Qt6/KF6/Plasma stack for `arctic-kde`; the
  xfce4 component set for `arctic-xfce`. Installing one of those
  meta-packages reports exactly which dependency is missing rather than
  failing halfway.
- **wireplumber needs lua 5.4**; Arctic packages 5.5, and its meson build
  will not accept the newer one.
- **ly is not packaged.** It authenticates through PAM, which Arctic does not
  have at all - sddm, lightdm and greetd are built against libxcrypt here.
  Adding ly means either porting its auth to shadow+libxcrypt or adding PAM
  to the base system; neither is done, so it is deliberately absent from
  `A_DM` rather than listed and broken.
- **No QEMU boot test per init yet.** openrc/sysvinit/runit/dinit are
  verified by what `arctic-init-setup` generates, not by booting a machine on
  each.
- `btrfs-progs`/`xfsprogs`/`f2fs-tools` aren't baked into the live rootfs the
  way e2fsprogs/dosfstools are — only installable as packages. The
  filesystem picker already only lists what the live session can actually
  format, so this fails safe (fewer options shown), not badly.
- helix doesn't build: one of its ~130 tree-sitter grammar dependencies
  (tree-sitter-go-template) was deleted upstream.
- `alpm rollback` restores files but doesn't fully reconcile the package
  database for packages it resurrects; `doctor` reports the resulting
  unsatisfied dependency rather than hiding it.
