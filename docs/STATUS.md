# Status

What's built and working, what's known-broken, what's still source-only.
Full docs live at arctic-linux.apiwow.net — this file is the terse engineering
log, not a tutorial.

## Core system

- glibc 2.44, merged-`/usr`, built from source. No binary in the image needs
  a host library.
- busybox 1.38.0 + toybox 0.8.14 (statically linked), zsh, doas, libarchive,
  mandoc, bmake, byacc, netbsd-curses, libxcrypt, libmd, zlib, xz, zstd.
- Kernel 7.1.3 (Gentoo dist-kernel config + Arctic delta: no BTF/DWARF, no
  module signing, storage/USB/squashfs/overlayfs in-tree). Flavors: base,
  libre, small (monolithic, no module loader), lts, rt, hardened.
- Arctic-minimal ISO, hybrid BIOS+UEFI, boot-tested in QEMU: Limine → kernel →
  initramfs → squashfs+tmpfs overlay → switch_root → busybox init → zsh.
- alpm: fetch, dependency resolution, ins/reins/del/del+deps with orphan
  cleanup, ins -nomod + commit for staged installs, verify, rollback
  (btrfs-snapshot and file-replace based), doctor, why, owns, search, stats.
  Still the POSIX sh implementation (`alpm/`). A full Rust rewrite exists in
  `alpm-rs/` (zero external crates, same on-disk formats/CLI) and builds
  clean, but isn't wired into what actually gets packaged yet - staying on
  the shelf until it's had more real-world use.
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

## Known-fixed bugs worth remembering

- **A fresh install could never `alpm fetch` main/kernels/source/profile
  again.** mkiso bundles those four repos on the medium itself so
  `arctic-install` works with no network at all, pointing them at
  `file:///run/arctic/medium/...` and disabling the matching network repo
  to avoid a name collision - with a comment saying arctic-install would
  re-enable the network one and drop the medium-only entry once installed.
  That step never actually existed. Every install, offline or not, left the
  new system with those four repos either disabled or pointing at a mount
  that stops existing the moment the disc/USB comes out - `alpm fetch`
  silently came up short for them forever after, until someone noticed and
  fixed repos.d by hand. Fixed by doing exactly what the comment already
  promised, once at the very end of the install.
- **`ALPM_DB`/`ALPM_CACHE`/`ALPM_LOG` were never derived from `ALPM_ROOT`.**
  Every `--root`-style install (target_alpm during a real install, any
  scratch-root tooling) recorded its package database into the *caller's*
  `/var/lib/alpm` instead of the target's. A freshly installed system's own
  database would be empty on first boot despite every file being in place.
  Fixed in `libalpm.sh` by computing these three paths from `ALPM_ROOT` by
  default. This affected every install this project has produced before the
  fix landed.
- **`alpm.conf` could silently override an explicit `ALPM_ROOT` override.**
  `alpm_load_conf()` sourced the config file unconditionally; a plain
  `ALPM_ROOT=/` line in it beat whatever a caller had exported. Fixed by
  preserving/restoring caller-set values around the config load.
- **alpm's dispatcher only read `argv[1]` as the subcommand.** `alpm -y ins
  vim` (flag before the subcommand — completely ordinary to type) was parsed
  as an unknown command and fell through to the help screen. Fixed to scan
  all arguments for global flags regardless of position.
- **`iwctl`/`iwd` failed with "failed to initialize dbus."** (Historical -
  iwd/iwctl were later replaced outright by NetworkManager+nmtui, see
  "Networking" below; the dbus/machine-id lesson carried straight over.)
  Nothing on the image ever started (or shipped) a D-Bus system bus; iwd
  registered itself on it at startup. Fixed by adding dbus to the live
  rootfs build, a `messagebus` system account (dbus drops root once it
  binds the socket), and an `rc.d/dbus` service enabled by default.
- **cryptsetup couldn't run at all.** Missing `libpopt.so.0` — nothing in the
  manifest ever built popt. Added it as its own port.
- **Rust packages failed to build almost universally.** The cargo recipe
  template used `--offline` with no vendored dependency tree (immediate
  resolution failure for anything with a dependency), then `CARGO_HOME`
  defaulting under `/root` (unwritable in the sandbox), then a hardcoded
  `clang`/`lld` linker that isn't installed on the build host. All three
  fixed in the shared template.
- **GitHub-archive source tarballs extracting to unexpected directory
  names.** Tags without a `v` prefix (ripgrep, helix) weren't recognized by
  the directory-name heuristic; fixed to handle both forms.
- **vim linked against the build host's GTK3/dbus/elogind stack** because its
  configure auto-detects a GUI toolkit off the host rather than the target.
  Built with `--enable-gui=no --without-x` now.

## Known rough edges

- `btrfs-progs`/`xfsprogs`/`f2fs-tools` aren't baked into the live rootfs the
  way e2fsprogs/dosfstools are — only installable as packages. The
  filesystem picker already only lists what the live session can actually
  format, so this fails safe (fewer options shown), not badly.
- helix doesn't build: one of its ~130 tree-sitter grammar dependencies
  (tree-sitter-go-template) was deleted upstream.
- musl is a separate, much smaller effort than the glibc build — see the
  `musl` subrepo notes in `ports/manifest.tsv`. Binary packages there are
  source-availability-first, not a parallel full system yet.
- `alpm rollback` restores files but doesn't fully reconcile the package
  database for packages it resurrects; `doctor` reports the resulting
  unsatisfied dependency rather than hiding it.
