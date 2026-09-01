# Status

What's built and working, what's known-broken, what's still source-only.
Full docs live at scraplinux-docs.apiwow.net — this file is the terse engineering
log, not a tutorial.

Release label: **ScrapLinux - A1** (`A1`). `A` is for alpha, the whole
series so far. Earlier schemes: `a1`-`a1.24`,
`a2`-`a2.61` (one-dot), then a brief `main.bigfix.smallfix` +
stability-suffix scheme (`3-SS`, `3.1-SS`) that claimed a maturity - "super
stable" - the distro was not actually at: a fresh install of `3-SS` itself
still behaved like the live image, from a bootstrap path (`scraplinux-base`/
`scraps`, packaged by `build/pkg-tools.sh` straight from `skel/`, separately
from every other package) that had gone stale and was found the same day
`3-SS` shipped. `A1 TESTING` came next and also shipped broken - wifi never
worked on a real install, only the live image; the chroot backspace fix
didn't take; `scraplinux-shell` couldn't run anything it had just installed.
That build was withdrawn and reset to a plain `A1` - an ISO build, no
qualifier claiming more verification than it had actually had.

This `A1` supersedes that one: the install model itself changed - no ISO,
no guided installer, manual tarball install instead - which is a
different thing to verify than a bugfix round on the same design, so it
replaces the earlier ISO-based `A1` release outright rather than sitting
beside it under a `B1`.

This round moved to tarball-only distribution - no ISO, no guided
installer, manual partitioning/format/chroot instead. Tarball filenames
carry no version (`scraplinux-def-tarball.tar.xz`, stable across
releases); the version lives in the release tag and in
`/etc/scraplinux-release`, which `scraplinuxfetch` reads.

## Core system

- glibc 2.44, merged-`/usr`, built from source. No binary in the image needs
  a host library.
- busybox 1.38.0 + toybox 0.8.14 (statically linked), zsh, doas, libarchive,
  mandoc, bmake, byacc, netbsd-curses, libxcrypt, libmd, zlib, xz, zstd, curl,
  signify. busybox owns a named set of applets - init, getty, mdev, mount,
  blkid, the module tools, the network tools - and toybox links everything
  else it provides. The two lists have to agree; `build/check-conflicts.sh`
  is what proves they do.
- LLVM 22.1.8 - clang, lld, libc++, compiler-rt - is packaged, so an
  installed system has a compiler and `scraps add -s` works on it. Too large
  for the mirror, so it is published as a release asset through `big`. Built
  with AMDGPU in its target list, which is not about targeting AMD as a
  platform: mesa's radeonsi asks llvm-config for an amdgpu component and
  refuses to configure without it.
- **Graphics**: mesa 26.0.2, with `iris` and `crocus` (Intel had no OpenGL
  driver at all before), `radeonsi`, `r300`, `r600`, `nouveau`, `llvmpipe`,
  `zink`, `virgl` and `svga`, plus Vulkan for AMD, Intel and swrast. NVK,
  nouveau's Vulkan driver, is out: it is written in Rust and its build wants
  bindgen. `libclc` and `spirv-llvm-translator` are packaged because the
  Intel drivers compile part of themselves from OpenCL C.
- **Desktops**: the Xfce 4.20 component set builds and is packaged -
  libxfce4util, xfconf, libxfce4ui, libxfce4windowing, garcon, exo, xfwm4,
  xfce4-panel, xfdesktop, xfce4-session, thunar, xfce4-settings,
  xfce4-appfinder, tumbler - along with openbox and icewm, gtk3, gdk-pixbuf,
  imlib2, libwnck and the X libraries under them. LXDE and LXQt have recipes
  in the ports tree but are not built: LXDE needs menu-cache and vte3, LXQt
  needs the Qt6 stack.
- Kernel 7.1.3 (Gentoo dist-kernel config + ScrapLinux delta: no BTF/DWARF, no
  module signing, storage/USB/squashfs/overlayfs in-tree). Flavors: base,
  libre, small (monolithic, no module loader), lts, rt, hardened.
- Two base tarballs, no ISO: `scraplinux-def-tarball.tar.xz` (busybox
  init) and an OpenRC flavor with OpenRC already wired up as init instead.
  Extract onto a formatted target, `scraps-strap` it, chroot in, `scraps add`
  the rest by hand.
- scraps: fetch, dependency resolution, ins/reins/del/del+deps with orphan
  cleanup, ins -nomod + commit for staged installs, verify, rollback
  (btrfs-snapshot and file-replace based), doctor, why, owns, search, stats.
  POSIX sh, and it stays that way.
- **Networking**: one stack, live and installed alike - wpa_supplicant +
  udhcpc, driven by `wifi-connect`. No NetworkManager anywhere in the base
  system; two networking stacks that could disagree about which one owned
  the radio is gone as a category of bug, not just a specific instance of
  one. `wifi-connect` with no arguments scans, lists what is in range, asks
  which interface and which network, reads the passphrase with asterisks,
  and on a successful connect writes the SSID/PSK/interface to
  `/etc/scraplinux/network.conf`. `rc.d/wifi` reads that back on every boot and
  reconnects - started in the background by rc.boot, never waited on, so
  an association or a DHCP lease never holds up the login prompt.
  `rc.d/network` handles plain wired DHCP the same way, no wifi/static
  branches of its own.

## Packages and repositories

Binaries and recipes are on separate hosts and never mix:

- **raw.githubusercontent.com/apiwo/scraplinux-pkgs** serves `.spz`
  binaries only - main, extra, base, kernels, profile, nonfree, alt-nonfree,
  multilib, fix, big. This is what `/etc/scraps/repos.d` points at. It is
  deliberately *not* pkg-scraplinux.apiwow.net: that domain sits behind a CDN
  which served two-week-old indexes while the origin was current, and an
  installed machine was told about packages that no longer existed.
- **ports-scraplinux.apiwow.net** serves recipes only, as
  `ALL/<repo>/<name>/recipe`. scraps reaches it through `SCRAPS_PORTS`, not
  through repos.d, so "what can be installed" and "what can be compiled" are
  never the same list. `scraps add -s` and `scraps get -s` are the only things
  that touch it.

`build/publish-pkgs.sh` and `build/publish-ports.sh` generate both sites from
what is actually in the tree - indexes and directory listings alike - so a
repository cannot advertise a package it does not host.

**Large packages.** GitHub refuses any file of 100 MiB or more, which is not
a limit that falls on optional things: `linux-firmware` is 162 MiB and the
packaged toolchain is 148 MiB. Both are release assets under the tag
`pkgs-x86_64` now. The `big` repository keeps its index in the tree with the
others and points `pkgurl` at the release, so scraps fetches the index from one
place and the package from another and nothing about installing one differs.
Verified by installing firmware onto a machine from it.

**Signed indexes.** Every index is signed with signify (Ed25519). scraps used
to trust that an index came from wherever the packages did; it does not have
to. A forged index hands a machine any package at all, because the checksum
scraps verifies afterwards comes from that same file. The public key ships in
`scraplinux-base` at `/etc/scraps/keys`, so it is on the machine before its first
fetch, and signify is part of the base system so a fresh install can check
what it downloads. A `.repo` file carries `sig = required | optional | off`;
a signature that does not match is refused under all three, and only a
missing one is tolerated - which is the state the installation image is still
in, because it is built without signify on it. The secret key lives on the
publishing machine and in no repository.

**A published release is immutable.** `publish-pkgs.sh` refuses to replace a
name-version-release with different bytes. scraps was rebuilt twice as 1.2.5-1,
a machine fetched the newer package against the older index, and the install
died on a checksum mismatch part way through the base system.

Every repository is meant to be mirrored to Codeberg as well as GitHub, and
`build/mirror-codeberg.sh` pushes all six in one command - but the Codeberg
mirror is **behind and cannot currently be updated**. The storage quota there
is per account and the binary package repository has filled it, so every
push, including the small ones, is rejected with "Quota exceeded";
`scraplinux-ports` was never created there and Codeberg has push-to-create
disabled. GitHub is the only mirror that is current. Either the quota goes
up or the binaries stop being mirrored - they are served from GitHub in
either case, which is what `/etc/scraps/repos.d` points at.

## Install

No ISO, no guided installer - `scraplinux-install` and `scraplinux-boot-strap` are
both gone outright, no compat stub. Install is manual, KISS-Linux-style:
boot any live Linux, partition and format by hand, extract a base
tarball onto the target, bootstrap scraps into it, chroot in, install the
rest with ordinary `scraps add`, run one finishing command, deploy the
bootloader by hand, reboot. See the main site's install guide for the
exact command sequence.

Two new small tools carry the weight the old installer used to:

- `scraps-strap <target-root>` — run once, right after extracting the
  tarball. scraps itself ships pre-installed in the tarball; this only
  syncs fresh repo indexes into the extracted tree, passing
  `SCRAPS_CONF`/`SCRAPS_REPOD` explicitly rather than relying on their
  default host-absolute paths (correct for the old installer, which ran
  from a live ScrapLinux session that already had real repo config at
  `/etc/scraps` - there is no such host here, whatever booted this tarball
  is some other live Linux with no `/etc/scraps` at all).
- `genfstab <target-root>` — its own tiny package (`scraps add genfstab`),
  not bundled raw. Writes `/etc/fstab` from `/proc/mounts`, same
  UUID-first logic the old installer's `genfstab()` had (never
  `PARTUUID=` - the initramfs resolves `root=` with busybox `findfs`,
  which only understands `LABEL=`/`UUID=`). Has to run before chroot, not
  after: it reads the outer mount table, which a chroot has no view of
  without `/proc` bind-mounted first.

`scraplinux-chroot` is unchanged (still bind-mounts `/proc /sys /dev /run`,
still has the chroot backspace fix), just relocated out of the deleted
`installer/` directory into the tarball's own bundled tools.

Declarative system management, once installed - now six small files
under `/etc/scraplinux/` instead of one big `system.conf`, each with one job:
`pkgs.conf` (a pure mirror of what's explicitly installed, kept in step
by scraps itself - never a reconcile target, which is what once let a
system upgrade quietly remove hand-installed packages), `network.conf`
(written by `wifi-connect` on a successful connect, read back by
`rc.d/wifi` at every boot), `users.conf`, `services.conf`,
`hardware.conf` (gpu/microcode/bootloader/boot timeout), `identity.conf`
(hostname/timezone/locale/keymap). See `conf.lib` for the file format - a
bracketed block grammar, no shell-sourcing needed to read a value.

- `scraplinux-rebuild` — reconciles the running system against those five
  declarative files (never `pkgs.conf` - see above). Also does what
  `scraplinux-boot-strap` used to do for an already-installed system:
  activates any kernel package still marked `-nomod` from a chroot
  install (`scraps commit`), and writes `limine.conf`/`grub.cfg` from the
  real `/etc/fstab`/`/etc/crypttab` - never runs the actual deploy
  command, that stays manual. A declared bootloader that doesn't match
  the one actually installed is reported, not switched. Every successful
  run snapshots and records a generation. First run on an empty file
  seeds it from what's actually there instead of wiping it.
- `scraplinux-shell [--network] [--keep] <pkgs> [-- cmd | - cmd]` — ephemeral
  package environments, content-addressed by package set so the same request
  reuses a previous build. Every invocation also sweeps the cache directory
  for an environment left mounted by a session that was killed outright,
  unmounting (and, unless it was built `--keep`, removing) whatever it
  finds with no live process still holding it.
- `scraplinux gc` — prunes the package cache, orphaned deps, and unused shell
  environments.

Networking has one stack now, not two: no NetworkManager anywhere in the
base system. `wifi-connect` (wpa_supplicant + udhcpc) is it, live and
installed alike - one code path instead of a live-only tool and an
installed-only daemon that could disagree about which one owned the
radio, which was the actual cause of wifi settings not carrying across
an install and of some of the slow-boot reports.

## Init systems

**initialization** is the default: a fork of nitro, packaged from
github.com/apiwo/initialization, and the init ScrapLinux ships rather than one of
several a system might pick. Its `make install` referenced a `service` binary
that is not in the tree, which stopped every install of it - fixed upstream.
It does not ship a `service` of its own here either: that belongs to
scraplinux-base, which hands a verb to whichever init is actually running.

`A_INIT` also takes busybox, openrc, sysvinit, runit, dinit and nitro, and
each installs *that* init's own tools - choosing openrc installs openrc and
its commands and nothing of initialization's. Every `/etc/rc.d` script is
written against busybox init's shape and translated from there. s6-66 and
systemd-libre are named in the installer's list but are not packaged yet.

`scraplinux-init-setup` translates `/etc/rc.d` into whichever init is chosen -
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
its back. Which init a system uses comes from `/etc/scraplinux/init` first and
pid 1 second - inside a chroot, `/proc/1` is the *host's* init and answering
from it is wrong exactly when someone is repairing services by hand.

## Building

Every build goes through `build/scraplinux-sandbox` (bubblewrap: the whole host
read-only, only the build and source trees writable). `scraplinux-sandbox
--check` proves it still holds, including that a `mount -o remount,rw` from
inside is refused.

`scraps-build` keeps a **build sysroot** at `$SCRAPS_SYSROOT`: every package it
produces is unpacked there and later builds compile and link against it
(`PKG_CONFIG_PATH`, `ACLOCAL_PATH`, `PATH`, `-isystem`, `-L`,
`-Wl,-rpath-link`). Each `.pc` file is rewritten as it lands so its absolute
paths point into the sysroot rather than at `/usr` on the build host.

## Known-fixed bugs worth remembering

- **A2: `dwl` genuinely could not build - "use of undeclared identifier
  'XDG_TOPLEVEL_CONFIGURE_BOUNDS_SINCE_VERSION'" - and it was not the
  wayland-scanner/xdg-shell.xml mismatch its own `recipe.local` originally
  suspected.** Directly ruled that out: `wayland-scanner server-header`
  against ScrapLinux's own `xdg-shell.xml` emits all 54 `SINCE_VERSION`
  constants, including both missing ones, deterministically - checked
  serially (`-j1`, no parallel-build race possible) with a byte-for-byte
  fresh header on disk at the moment of the failing compile. The real
  cause: wlroots 0.20's installed `wlr_xdg_shell.h` gets its constants
  from `<wayland-protocols/xdg-shell-enum.h>` - a *separate*, more
  limited header wayland-protocols pre-generates with wayland-scanner's
  `enum-header` mode, which only covers enum value constants, not
  per-message `SINCE_VERSION` guards for events like `configure_bounds`.
  dwl 0.8 was written against wlroots 0.19, before this restructuring,
  and has never been adjusted for it - no newer tagged release exists
  upstream. Fixed by defining both guards locally in `client.h` at their
  real xdg-shell protocol version numbers (checked directly against the
  XML: `configure_bounds` `since="4"`, `wm_capabilities` `since="5"`).
  First verification pass was wrong in two ways, both corrected. First:
  it was run nested inside the live niri session
  (`WAYLAND_DISPLAY=wayland-1` against the real desktop) - two of those
  attempts (before the test's own mount/DRM setup was fixed) actually
  segfaulted `dwl` inside `libwayland-server.so.0.25.0` and froze the
  real machine's display for several minutes; only the third, clean-
  environment attempt got reported. Nesting a compositor under test into
  a real live session is not an acceptable blast radius regardless of
  whose bug causes the crash - every verification of a graphical runtime
  since uses `WLR_BACKENDS=headless` (fully offscreen, no display/session
  involved) instead. Second, separately: the fixed build was never
  actually published - `scraps add -s dwl` installs straight into the
  chroot doing the build, and the built `.spz` was never copied from
  there into the shared package repo, so the repo kept serving the old,
  wlroots-0.19-linked binary the whole time despite the recipe fix being
  correct and committed. A completely fresh `scraps add dwl` against the
  actual published repo confirmed this (`libwlroots-0.19.so`, immediate
  load failure) before the republish; confirmed fixed after.
  A third, real bug turned up while reconciling this: after the header
  fix, a *correctly source-built* `dwl` still failed to link -
  `ld.lld: error: unable to find library -lwlroots-0.20` despite
  pkg-config correctly reporting its flags - because `--sysroot` also
  redirects the linker's default library search, and most `.pc` files'
  `--libs` output has no explicit `-L/usr/lib` to survive that (see the
  `scraps-build` fix below, third instance of the same missing-sysroot-
  entry class as the `usr/include`/pkg-config ones above it).
  Currently verified: a byte-for-byte fresh chroot, `scraps add dwl`
  against the (now correctly) published repo, linked against
  `libwlroots-0.20.so` (`readelf -d`), run with `WLR_BACKENDS=headless`
  for a full bounded window with no crash - clean event loop the entire
  time, exited only on the test's own timeout. Not yet wired into the
  `wayland` tarball flavor's default bundle - that uses `-dms`
  session-wrapper packages and no `dwl-dms` exists yet, only the raw
  `dwl` package.

- **A2: `libglvnd`'s own `.PKGINFO` had `depend = glibc,libx11,libxext` -
  one comma-separated string, not three separate dependencies - so scraps
  could never resolve it at all** ("needs glibc,libx11,libxext, and
  nothing has it - not a repository, not the ports tree"), blocking
  anything needing real `egl.pc`/`glesv2.pc` (mesa only ships its own
  vendor-specific `libEGL_mesa.so` under libglvnd dispatch, not the
  `EGL`/`GLESv2` pkg-config names applications actually look for).
  Recipe and published package both fixed to three plain `depend=`
  entries.

- **A2: `rust`/`cargo` could not run at all on a real install, and
  `scraps add -s` on anything (Rust or not) that compiled its own C code
  failed the same way - four independent bugs, each looking like a
  different failure.** First, `cargo: error while loading shared
  libraries: libgcc_s.so.1: cannot open shared object file`: rustc/cargo
  link `-lgcc_s` for unwinding regardless of ScrapLinux being an LLVM
  distribution with no GCC in it, and nothing declared `gcc-libs` (see
  below) as a dependency, so a real install never had the library at all.
  Second, once that was fixed, `rustc: error while loading shared
  libraries: libc++.so.1: cannot open shared object file` - the exact
  "Alpha 3 SS" bug further down this list, which turned out to have
  silently stopped applying: `skel/etc/ld.so.conf` fixed it for the old
  mkiso/skel-copy install path, and was never added to `build-tarball.sh`'s
  own curated file list when the tarball-only install model replaced that
  path. Third, `libLLVM.so` genuinely links `libxml2.so.16` and the `llvm`
  package never declared it, so `clang`/`cc` itself failed the same way
  once something actually needed clang to run (a plain `scraps add llvm`
  with nothing invoking clang never surfaced it). Fourth, once clang could
  run, `scraps add -s ripgrep` (a totally ordinary source build, the pcre2
  crate has no C in it at all - the scraps bootstrapping itself does)
  failed with `fatal error: 'stdlib.h' file not found`: `scraps-build`
  unconditionally passes `--sysroot=$SCRAPS_SYSROOT` to clang, and
  `$SCRAPS_SYSROOT` only ever holds packages built earlier in the *same*
  `scraps-build` session - glibc came from the base tarball, not from this
  session, so the sysroot's `usr/include` never had a C standard library
  in it at all outside of the one-shot package-building pipeline. Fixed
  with a symlink (`$SCRAPS_SYSROOT/usr/include -> /usr/include`), created
  only when `SCRAPLINUX_SANDBOX` is unset - inside the sandboxed build-host
  pipeline that bind-mounts the *host's* real headers read-only, trusting
  `/usr/include` would be exactly the host-contamination bug this sysroot
  exists to prevent; inside `scraplinux-chroot`, or on a real installed
  system, `/usr/include` genuinely is ScrapLinux's own glibc. All four
  verified end to end: a byte-for-byte fresh loopback disk, tarball
  extracted, `scraps-strap`'d, chrooted into with nothing pre-cached,
  `scraps add -y scraplinux-base` then `scraps add -y rust cargo llvm bmake`
  then `scraps add -y -s ripgrep` compiles and installs a working `rg` with
  no manual intervention.

- **A2: the same missing-sysroot-entry bug, for `pkg-config` instead of
  headers - `scraps add -s librsvg`/`bat`/`eza` reported an ordinarily
  `scraps add`-installed library ("cairo", "gio-2.0", ...) as not found at
  all.** Same root cause as the header case just above: `PKG_CONFIG_PATH`
  only ever pointed inside `$SCRAPS_SYSROOT`, which does not contain
  whatever was separately installed onto the actual system with a plain
  `scraps add`. Fixed the same way: `$SCRAPS_SYSROOT/usr/lib/pkgconfig` and
  `usr/share/pkgconfig` are symlinked to the real ones, gated on
  `SCRAPLINUX_SANDBOX` being unset for the identical host-contamination
  reason. Uncovered a second bug on the way: `pkgconf` (ScrapLinux's actual
  `pkg-config` implementation) never installed a `pkg-config` compat
  symlink, which is what every `*-sys` crate's build.rs and every
  autotools `configure` actually look for by name - `pkgconf` being
  installed and on PATH did nothing, and the error ("pkg-config command
  could not be found") read exactly like the tool being entirely
  missing. Every other distribution's pkgconf package ships this symlink;
  ScrapLinux's now does too.

- **A2: `bat` and `eza` only ever worked by accident, linked against the
  build host's own Gentoo `libgit2.so.1.9.4`, which does not exist on any
  real ScrapLinux install.** `libgit2-sys`'s build.rs prefers a system
  libgit2 found via pkg-config over building its own vendored copy, and
  the sandbox bind-mounts the whole host filesystem read-only - including
  the host's real `/usr/lib64/libgit2.so.1.9.4`, which nothing in ScrapLinux
  ships. `readelf -d` on the published binaries showed `NEEDED
  libgit2.so.1.9` right there. Fixed with
  `LIBGIT2_SYS_USE_PKG_CONFIG=0` in both recipes, forcing the vendored,
  statically-linked build instead; confirmed by re-running `readelf -d` on
  the rebuilt binaries (no `libgit2` in `NEEDED` at all) and by both
  binaries actually running.

- **A2: `gcc-libs` (`libstdc++`/`libgcc_s`, needed by the NVIDIA driver
  and now rustc/cargo too) was never actually verified to build, and was
  missing the plain, unversioned `.so` symlinks anything passing
  `-lgcc_s`/`-lstdc++` to the linker needs.** Its own `recipe.local`
  already said as much - the published package turned out to be real
  `.so.N` files of uncertain provenance, not something `scraps-build` ever
  produced from this recipe, and `scraps owns` found no package that
  actually owned `libgcc_s.so.1` in a build sysroot. `mkpkgs.sh`'s
  packaging step (which is where the currently-published package
  actually comes from - a snapshot-rootfs bootstrap package, the same
  class as `scraplinux-base` itself) now adds
  `libgcc_s.so -> libgcc_s.so.1` and `libstdc++.so -> libstdc++.so.6`
  after copying the runtime files in. A genuine from-source,
  `scraps-build`-verified rebuild of `gcc-libs` is still not done - real
  GCC bootstrap, more time than this pass had for one already-published
  package - and stays a known gap.

- **A2: `nushell`'s package() step installed nothing - "bad
  'target/release/nushell': No such file or directory" after a clean,
  successful compile.** The crate is named `nushell`; the binary it
  actually produces is `nu`. Fixed and verified: `scraps add -s nushell`
  installs a working `nu`.

- **A2 (found, not fixed): `greetd` cannot build on ScrapLinux at all -
  `pam-sys` is a hard, non-optional dependency in its own Cargo.toml**
  (`error: unable to find library -lpam`), and ScrapLinux has no PAM
  anywhere, deliberately (see "ly is not packaged" below). Fixing this
  means either adding PAM to the base system - a real reversal of an
  existing design decision - or patching greetd's own auth backend to use
  libxcrypt directly, a genuine upstream-facing fork. Neither attempted.
  `tuigreet` depends on `greetd` and is blocked the same way, transitively.

- **A2 (found, not fixed): `librsvg` needs `mount.pc` (libmount), which
  `util-linux` itself does not install at all, though it builds the
  actual `.so` files fine.** `gio-sys`'s pkg-config `Requires:` chain
  pulls in `mount` through `gio-2.0`; the older `util-linux-libs` package
  did ship the `.pc` files, but `util-linux` supersedes it (same
  `libuuid.so` etc - installing both conflicts) without carrying them
  forward. Confirmed as the only remaining blocker with the full
  X11/xorgproto dependency chain (`libx11 libxrender libxft libxext
  libxcb xorgproto`, now in librsvg's own `makedepend`) already
  installed. Fix belongs in `util-linux`'s own recipe/package() step, not
  attempted this pass - see `ports/base/librsvg/recipe.local`.

- **A2 (found, not fixed): `wezterm`'s pinned version, `20260401`, never
  existed - a placeholder guess, not a real release tag.** wezterm tags
  dated releases `YYYYMMDD-HHMMSS-<commit>`, and had not cut one since
  `20240203-110809-5046fc22`. Fixed the version/source URL to the real
  tag and its `-src` release asset (needed for vendored submodules a
  plain GitHub archive tarball omits) - source now fetches, extracts and
  compiles correctly. Blocked past that on a genuine upstream
  compatibility gap, not an ScrapLinux bug: `openssl-sys` 0.9.99 refuses
  anything newer than LibreSSL 3.8.1, and ScrapLinux ships 4.2.0. See
  `ports/extra/wezterm/recipe.local`.

- **A2 (found, not fixed): `yazi` 26.5.6 needs rustc 1.95.0; ScrapLinux
  packages 1.94.0.** Not chased further this pass - either bump the
  pinned yazi version to one with a compatible MSRV, or update ScrapLinux's
  own rust/cargo package, both real, untried work.

- **A1: wifi worked on the live image and never on a real install,
  for three independent reasons that all had to be found separately.**
  `linux-firmware` is well over the free-tier mirror's size limit, so
  `scraplinux-install`'s own `target_scraps add linux-firmware` 404d on every real
  install while `warn_soft` swallowed the failure silently - the wireless
  driver loaded and `wlan0` existed either way, but the radio itself had no
  firmware to load. Fixed by copying the live medium's own curated
  wireless-plus-console firmware set directly onto the target instead of
  asking a mirror for a file it was never going to serve. Separately,
  `wifi-connect` never had to think about privilege on the live image, which
  logs in as root - a real install's default login is the account
  `scraplinux-install` created, and `iw scan` came back "Operation not permitted
  (-1)" there, which `wifi-connect` turned into "no networks found - move
  closer, or check the antenna," a permissions error diagnosed as a range
  problem. It re-execs itself through `doas` when not already root now, and
  refuses with a real message if `doas` isn't there to do it. Third, a
  soft-blocked radio still creates its netdev, so `iw scan` finding nothing
  on a rfkilled card looked identical to no hardware being present;
  rfkill is unblocked before every scan now. The wireless profile a real
  install actually used is carried across to the installed system's own
  `rc.d/wifi` + `wpa_supplicant` pairing (not handed to NetworkManager,
  which would otherwise fight the same radio for it) and reconnects on
  every boot after - this specific end-to-end flow, install over wifi then
  reboot into a working connection with no manual steps, still needs a real
  machine to confirm; QEMU has no wireless NIC emulation.

- **A1: `A_NTP` defaulted to yes and enabled a service nothing could
  ever run.** `/etc/rc.d/ntpd` runs `/usr/bin/ntpd`, a standalone binary no
  package in ScrapLinux provides - busybox's own `ntpd` applet is a different
  invocation entirely. Off by default now, same reasoning as microcode:
  don't enable something nothing packages yet.

- **A1: backspace still moved the cursor forward inside
  `scraplinux-chroot`, after an earlier fix for exactly that.** zsh's ZLE runs
  the terminal in raw mode for its own line editing and never consults
  `stty erase` - the earlier fix (`scraplinux-chroot` setting `stty erase ^?`)
  only ever helped the `/bin/sh` fallback, not zsh. A separate zsh
  `bindkey '^?'/'^H' backward-delete-char` had already been added in the
  right place, and was silently undone eight lines later by a pre-existing
  `bindkey '^H' backward-kill-word` - bindkey applies in order, so whichever
  terminal actually sends `^H` for backspace still deleted a whole word.
  `^W` already does word-delete in zsh's own emacs keymap by default; the
  stray line added nothing and only broke the fix it came after. Verified
  in QEMU: entering a chroot and sending both `^?` and `^H` now deletes one
  character each, not a word.

- **A1: `scraplinux-shell` built a working package set into an
  environment where none of the ordinary commands to use it worked.** `id`,
  `which`, `ls`, `grep` and more failed with "error while loading shared
  libraries: libcrypt.so.2: cannot open shared object file" inside the
  interactive shell it drops into, immediately after reporting a clean
  install. glibc dropped `crypt()` itself; `libxcrypt` provides it, and
  every real install gets it as part of the base meta-package - but neither
  busybox nor toybox declares it as a dependency, so scraps never pulled it
  into the hand-picked `glibc busybox toybox` set an ephemeral environment
  builds from. Added explicitly. Separately, a session killed outright
  (SIGKILL, a host crash) took `/dev`, `/proc` and `/sys` down with it - the
  exit trap that unmounts them before `rm -rf` only runs on a normal exit or
  a caught signal - and what was left behind had to be found by hand from
  `lsblk` and cleaned up manually, usually surfacing later as `rm: sys:
  Device or resource busy` from something unrelated touching the same tree.
  Every invocation now sweeps other environments under the cache directory
  for a live mount with no running process holding its lock file, and
  unmounts (and, unless built `--keep`, removes) what it finds. Verified in
  QEMU: an environment fabricated to look like a crashed session is
  unmounted and deleted by the next unrelated invocation; the same
  fabricated as `--keep` is unmounted but left in place.

- **A1: a slow service held up every service after it, whether or
  not either had anything to do with the other.** `rc.d/wifi` and
  `rc.d/network` can each spend real seconds waiting on an association or a
  lease; `sshd` or a display manager has no reason to wait on either.
  Services now start together and are waited on in the same order they
  started, so output stays in a fixed, readable order even though the work
  itself overlaps. Also stopped keying a service's pid off an eval'd
  `$n`-named variable - a name from `A_SERVICES` with a dash in it broke the
  eval'd assignment instead of just failing to start.

- **A1: `scraps system fix` conflated "what's pending" with "apply
  it," with no way to see the first without risking the second.** Split
  into `scraps system get` (installed release, kernel, generation), `scraps
  system check` (everything pending, package upgrades and fix-repository
  corrections alike, never applying anything), and `scraps system upgrade`
  (syncs, upgrades, updates the bootloader, applies corrections, and now
  also reconciles against `system.conf` - a package upgrade and a
  declarative config change wait on the same command instead of two).
  `scraps system fix` is gone outright, not aliased - the listing and
  applying logic it had moved into a shared internal helper the other two
  both call, so they can never disagree about what counts as pending.

- **A1: `install.conf`'s networking, graphics driver, microcode and
  bootloader settings only ever applied once, at install time.** Editing
  `A_NET`/`A_WIFI_*`/`A_GPU`/`A_MICROCODE`/`A_BOOTLOADER` after install did
  nothing, because nothing ever read them again. The same settings, same
  shape, now live in `system.conf` as `SYS_NET_MODE`/`SYS_GPU`/
  `SYS_MICROCODE`/`SYS_BOOTLOADER` and are reconciled by every
  `scraplinux-rebuild`: a declared static address or wifi profile writes the
  same NetworkManager keyfiles `scraplinux-install` itself writes (only
  rewriting one when it actually differs from what's on disk), `auto`
  GPU/microcode resolve through the same PCI/cpuinfo detection and fold the
  right packages into the ordinary install list, and a declared bootloader
  that doesn't match the running one is reported rather than switched -
  changing it means reinstalling boot sectors on a disk that already has
  data on it, which stays `scraplinux-boot-strap`, run by hand. Verified in
  QEMU: a declared static address writes `scraplinux-wired.nmconnection` with
  the right address/gateway/dns, and a second rebuild against the same file
  reports nothing left to do.

- **Alpha 3.1 SS: a real install still behaved like the live image - the
  first-login greeting told you to run `scraplinux-install` again, wifi-connect
  reported "no networks found" against real hardware, and kernel-module
  coldplug took the full ~30s the live ISO does not.** All three were the
  same bug: `scraplinux-base` and `scraps` do not build through the normal
  `ports/*/recipe` + `scraps-build` pipeline - `build/pkg-tools.sh` packages
  them straight from the live `skel/` tree instead, because `scraps-build`
  itself depends on `scraps` already being installed. Every `skel/` fix this
  entire cycle (the rc.boot coldplug fix, the removed live-image
  wifi-connect greeting, the ld.so.conf fix, wifi-connect's
  NetworkManager-conflict detection) reached the live ISO through `mkiso`'s
  own direct copy of `skel/`, and never reached a real install, because
  nothing had rerun `pkg-tools.sh` since before any of it existed - the
  published `scraplinux-base` was still `1.4.1`, built 2026-08-16. Fixed by
  rerunning `build/scraplinux-sandbox build/pkg-tools.sh 1.4.2` and republishing.
  `ports/main/scraplinux-base/recipe` (a separate, `scraps-build`-buildable recipe
  with its own stale `skel.tar`/`branding.tar`) is dead code that nothing in
  the real pipeline uses - don't waste time keeping it in sync instead of
  this.

- **Alpha 3 SS: `clang` could not run at all on a freshly installed system -
  every source build was broken from the first boot.** LLVM's own CMake
  defaults install `libc++`/`libc++abi`/`libunwind` into a target-triple
  subdirectory (`/usr/lib/x86_64-unknown-linux-gnu/`) instead of straight
  into `/usr/lib` like every other ScrapLinux package, and nothing told the
  dynamic linker to look there - there was no `/etc/ld.so.conf` at all.
  `clang` itself is linked against `libc++`, so it failed before compiling
  a single line: `clang: error while loading shared libraries: libc++.so.1:
  cannot open shared object file: No such file or directory`. `scraps add -s`
  on any package failed the same way, immediately, with no useful error
  pointing at the real cause.

  This went unnoticed all the way to a release candidate because every
  build this cycle ran through the sandboxed build host, which bind-mounts
  the *host's* whole filesystem read-only - the host's own `/etc/ld.so.conf`
  and cache were visible inside the sandbox and quietly did the resolving
  that a real, freshly installed ScrapLinux system has no way to do. It only
  showed up chrooting into an actual `scraplinux-install` target with no host
  underneath it to fall back on - a reminder that the sandboxed build
  environment is not a substitute for testing a real install, only a
  guard against a build clobbering the host.

  Fixed with `skel/etc/ld.so.conf` listing the triple directory - `scraps`
  already runs `ldconfig` after every transaction (`run_hooks` in
  `scraps/scraps`), it just had nothing to read before this existed.

- **Alpha 3 SS: `nmtui` hardcoded the build host's own `/usr/lib64/libnewt.so`
  instead of a proper soname.** NetworkManager was built before `newt` had
  been seeded into the sysroot, so its configure step detected and linked the
  build host's real 64-bit `libnewt.so` at that path rather than a sysroot
  copy. `readelf -d` on the shipped `nmtui` showed the absolute host path in
  `DT_NEEDED`, which is why `nmtui` could not even start on a real install
  (`/usr/lib64/libnewt.so: cannot open shared object file`) despite `newt`
  being packaged and installed. Fixed by seeding `newt` and `slang` into the
  sysroot before rebuilding NetworkManager; the rebuilt binary links
  `libnewt.so.0.52` as a soname like every other shared library on the
  system.

- **Alpha 3 SS: `wifi-connect` and NetworkManager fought over the same radio.**
  `wifi-connect`'s `iw scan` ran against a device NetworkManager's own
  wpa_supplicant already had open, failed with "device busy", and the
  fallback message ("no networks found, move closer to the router") looked
  like a hardware/range problem when it was actually two programs contending
  for one radio. `wifi-connect` now detects a running NetworkManager first
  and tells the user to use `nmtui` instead of scanning underneath it.

- **Alpha 3 SS: every fresh btrfs install kernel-panicked at "Attempted to
  kill init!".** The installer wrote the initramfs a root device with no
  `subvol=` flag, so it mounted the top-level btrfs volume instead of the `@`
  subvolume that actually contains `/sbin/init` - the panic was the kernel
  correctly reporting that PID 1 did not exist where it looked. Fixed in
  `scraplinux-boot-strap` for both the Limine and GRUB code paths: `rootflags=`
  is now computed by reading the `subvol=` option back out of the `/etc/fstab`
  line the installer itself just wrote, for both bootloaders.

- **Alpha 3 SS: coldplug's progress dots never appeared on the boot entry
  everyone actually boots from.** a2.5 added a heartbeat of `.` characters
  while kernel modules load, gated on `QUIET != 1` so it wouldn't clutter a
  quiet boot - but the *default* Limine entry passes both `quiet` and
  `scraplinux.splash`, either of which sets `QUIET=1` in `rc.boot`. The dots were
  live code that simply never ran on the one entry that matters, so a boot
  that was actually loading modules for a few seconds looked identical to a
  frozen one. The dot loop itself is no longer gated on `QUIET`; only the
  one-time `:: loading drivers` label is quiet-gated, so quiet boots still
  see the heartbeat without a stray label line.

- **`-f` is not an option ScrapLinux's wpa_supplicant has, and passing it stopped
  wireless dead.** a2 added `-f "$log"` to the supplicant invocation so a
  failed association would leave something to read. `-f` is compiled in by
  `CONFIG_DEBUG_FILE`, which this build does not set, so wpa_supplicant
  printed its usage and exited without ever touching the radio - and the
  "log" the failure path then showed was that usage text, which is what the
  screenshot of a2 failing actually contained. Redirection does the same job
  and cannot be refused.

  The option was checked with `wpa_supplicant -h` **on the build host**,
  whose wpa_supplicant is built with `CONFIG_DEBUG_FILE` and accepts `-f`
  perfectly. Check flags against the binary ScrapLinux ships:

      $ strings squash/usr/sbin/wpa_supplicant | grep -E '^  -[fBc] '
        -B = run daemon in the background
        -c = Configuration file

- **A supplicant that never started still counted as started.** `-B` forks,
  so the exit status says nothing about whether the daemon survived, and a
  build that refuses an option can exit 0 having printed usage. The control
  socket and the process are what get checked now.

- **No installed system could boot.** The installer wrote `root=PARTUUID=` on
  the kernel command line and into fstab, on the reasoning that the kernel
  resolves a partition-table UUID immediately with no filesystem probing.
  That is true, and it never applied: ScrapLinux always boots through an
  initramfs, and the initramfs resolves `root=` with busybox `findfs`, which
  implements `LABEL=` and `UUID=` and nothing else.

      # findfs UUID=f1832033-6264-4f35-8f81-43170e93a396
      /dev/vda3
      # findfs PARTUUID=9813faed-6c1b-4e86-808b-61e6498d25db
      Usage: findfs LABEL=label | UUID=uuid

  Every install finished cleanly, reported success, and then stopped at
  `no device matches PARTUUID=...` and dropped to the initramfs shell with
  the disk sitting right there - `/dev/vda3` was in `/dev` and `blkid` named
  it. busybox `blkid` does not report PARTUUID either, so nothing on the
  machine could have resolved that spec. fstab has the same problem, which
  is the same reason `/boot` would not mount. Both are written as `UUID=`
  now, falling back to `PARTUUID=` and then to the device path, and
  `scraplinux-boot-strap` re-derives the spec rather than copying a PARTUUID out
  of an older fstab. The initramfs also falls back to `LABEL=scraplinux-root` -
  every filesystem the installer makes carries that label - so a machine
  installed by an older version still comes up.
- **The firewall had no package.** `A_FIREWALL=y` is the default, nftables
  had no binary in any repository, and the installer fell back to compiling
  it inside the target, where it failed with "C compiler cannot create
  executables". The install reported success anyway. nftables would not build
  on the host either: its configure probes for the symbol `readline` inside
  `-ledit` and ScrapLinux's libedit does not ship that compatibility name, so it
  stopped with "No suitable version of libedit found". Built `--with-cli=no`,
  which drops `nft -i` and nothing else, and packaged along with libnftnl.

- **Wireless could never have worked, on any network.** `wifi-connect` built
  its `wpa_supplicant.conf` by piping the passphrase into `wpa_passphrase`,
  to keep it out of argv where every process on the machine could read it.
  `wpa_passphrase` turns terminal echo off before reading, so it calls
  `tcgetattr` on its stdin - and on a pipe that fails with ENOTTY and it exits
  1 having written nothing. Its stderr went to `/dev/null` and its exit status
  was never checked, so what landed on disk was a config file with no
  `network=` block in it at all. wpa_supplicant then started cleanly,
  associated with nothing, and the wait loop blamed the passphrase 30 seconds
  later. The block is written directly now - wpa_supplicant derives the key
  from a quoted passphrase itself, and `wpa_passphrase`'s own output carries
  the plaintext in a `#psk=` comment beside the hash anyway, so there was
  never anything to protect. The file is 0600 either way, and the recipe
  refuses to continue if no network block landed.
- **Nothing wrote a `ctrl_interface`, so `wpa_cli` could not connect.**
  `wpa_passphrase` emits a network block and no header, so wpa_supplicant
  opened no control socket. Every `wpa_cli` call in `wifi-connect` failed
  silently, including the association check in its wait loop - and the error
  message told you to run `wpa_cli -i wlan0 status`, which answered "Could not
  connect to wpa_supplicant: wlan0". The failure path prints the actual state
  and the last lines of the supplicant log now instead of naming a command.
- **The installer dropped the wireless key it was carrying across.** It read
  the psk out of `wifi-connect`'s config with `grep -v '^"'`, taking the
  unquoted hex derivation and deliberately skipping a quoted passphrase. Once
  `wifi-connect` wrote the quoted form that match came up empty, and the
  profile was written with no `[wifi-security]` section - an open-network
  profile for a WPA network. Both spellings are accepted now.
- **The live image had no regulatory database.** With none the kernel stays in
  world domain `00`, where most 5 GHz channels are receive-only: an access
  point turns up in a scan and the card is then forbidden to transmit to it,
  which is indistinguishable from a wrong passphrase. `wireless-regdb` is 5 KB
  and is on the image now, and `wifi-connect` says so when the domain is still
  `00`. Its recipe installs the signed database upstream ships rather than
  running the default make target, which regenerates it with python and a
  private key that is not distributed.
- **The whole boot was right-aligned against column 80 of a 240-column
  console.** `rc.lib` measured the console once, when it was sourced - which
  is the first thing rc.boot does, before it has mounted `/dev`. There was no
  `/dev/console` to ask yet, so every boot took the 80-column fallback. The
  width is worked out at first use now, and cached.
- **Every service reported `t=0.0s`.** The elapsed time was printed to one
  decimal place and almost everything starts in under a tenth of a second, so
  the timing column said nothing at all on nearly every line. Two digits is
  what `/proc/uptime` actually offers.
- **`bad()` printed a shell error on top of the failure it was recording.**
  It appended to `/run/scraplinux/boot.errors` with `2>/dev/null`, and a
  redirection that cannot be opened is reported by the shell itself before
  that redirection is in effect - so any failure before `/run/scraplinux` existed
  put "can't create ..." on the console mid-boot. Tested first now.
- **`scraplinuxfetch` reported the wrong shell.** It read `$SHELL` and fell back
  to the passwd entry; the live session exports neither and root's entry still
  says `/bin/sh`, so a session demonstrably running zsh was reported as `sh`.
  It reads what is actually running it now.
- **The live image greeted an operator with a hardware inventory.**
  `scraplinux-welcome` ran `scraplinuxfetch`, which answers "what is this machine" -
  not the question someone who has just booted an installer has. It prints
  the three steps to install, the four scraps commands worth knowing, where the
  configuration lives, and how to chroot back in to repair one.

- **A new install had an address, a route, and no resolver.** Nothing wrote
  `/etc/resolv.conf`: NetworkManager writes one once it is managing a link,
  and until then there was none at all, so every lookup failed with
  `ping: bad address 'google.com'` on a machine whose network was working
  perfectly. The installer writes a resolver and an `nsswitch.conf` now
  rather than leaving glibc on its compiled-in fallback.
- **`iw` was never on the installation image**, so `wifi-connect scan`
  answered "iw is not installed" and the only way onto wireless was to type
  an SSID exactly right from memory. It is packaged and on the image, and
  `wifi-connect` run with no arguments does the whole thing.
- **The installer told you to install a bootloader it had already
  installed.** It has run `scraplinux-boot-strap` itself for a while, but the
  closing summary still ended with two commands to type, so a finished
  install read as an unfinished one.
- **A malloc and an HTTP/2 library put a compiler on the image.** jemalloc
  was built with its C++ integration and nghttp2 ships C++ applications, so
  both linked libc++ - and the only package providing libc++ is llvm, so
  mkiso's library closure installed 350 MiB of compiler to satisfy one
  runtime library. The image went from 381 MiB to 589. jemalloc is
  `--disable-cxx` and nghttp2 is library-only, which is why it is packaged at
  all: curl speaks HTTP/2 through it.
- **A comment between two continued lines silently truncated a command.**
  mesa's meson invocation lost every option after it - the shell joins the
  lines first, so the `#` starts mid-command and swallows the rest - and mesa
  configured itself with the defaults instead. It built. What came out was
  not what the recipe said. `build/check-recipes.sh` refuses that shape now.
- **Every Xfce recipe pointed at a version that does not exist.** They named
  4.22; upstream is 4.20, in a `4.20/` directory, as `.tar.bz2`. Nothing in
  the desktop could be fetched, let alone built.

- **The base system stopped installing at `/usr/bin/blkid`.** toybox linked
  every command it provides except nine; busybox claims fifty-two. The two
  disagreed about twenty-two paths, glibc about `getconf` and `iconv`,
  netbsd-curses about `clear` and `reset`, attr about `setfattr`. It was
  survivable while the last symlink written won, and stopped being survivable
  the moment scraps learned to refuse a path another package owns. toybox's
  skip list is busybox's applet set now, and `build/check-conflicts.sh` reads
  the archives to prove the two still agree - the alternative was finding one
  path per twenty-minute install.
- **A base install carried two TLS libraries and finished with neither.**
  wpa_supplicant linked OpenSSL's `libssl.so.3` because openssl happened to
  be in the build sysroot when it was built, while everything else - curl
  included - links libressl. Both claim `/usr/include/openssl` and
  `/usr/lib/libssl.so`, so the network set stopped on the conflict: libressl,
  NetworkManager and curl never landed, and the install still reported
  success. A machine was left with no way to fetch a package or configure a
  network. wpa_supplicant is built against libressl now; `CONFIG_TLS=openssl`
  stays, because that is its name for the API and not for the package.
- **An install with no password could not be logged into.** root ships
  locked, and a user created without a password is locked too, so a config
  that set neither produced a system that installed perfectly and then had
  nothing that could log in - found at the first boot, with the medium put
  away. The installer refuses that config now.
- **libressl would not link under lld.** Every 64-bit object, the crt files
  included, was rejected as "incompatible with elf32-i386" although nothing
  asked for 32-bit code. On a multilib build host `/usr/lib` is the 32-bit
  directory; ScrapLinux installs to `/usr/lib`, so libtool searches it at relink
  time and finds glibc's 32-bit `libc.so`, a linker script beginning
  `OUTPUT_FORMAT(elf32-i386)` - which lld honours over the `-m elf_x86_64`
  the driver had already passed. It was never a libressl bug and any
  autotools package could have hit it. `scraps-build` puts the host's 64-bit
  directory behind the sysroot on hosts laid out that way; libressl builds
  rather than being repacked by hand.
- **`gen-ports.py` silently reverted hand-edited recipes.** less and
  util-linux-libs lost their `replaces` field and their release bump when the
  generator rewrote them from the manifest, so the recipes no longer built
  the packages being shipped. A `recipe.local` marker is what stops it, and
  both have one.
- **`publish-fix.sh` published the oldest build of a version.** The manifest
  names a version, not a release, and the first name a glob produces is the
  lowest - so a fix could be published as a package built before it. It also
  would have taken `-10` over `-2`.

- **The live image had no network at all.** Only `lo` came up, and every
  network repository was "unreachable". Nothing loaded a driver for hardware
  that was already present at boot: mdev only fires for devices that appear
  afterwards, and udev - which coldplugs on other systems - is not what
  ScrapLinux runs, so e1000, virtio_net and r8169 sat unused in
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
  ScrapLinux system has rejects it, and with its error discarded xz happily
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
- **`scraps add -s` built the package and threw it away.** It looked for the
  result under `$SCRAPS_CACHE/build/out` while scraps-build writes to
  `$SCRAPS_BUILDROOT/out` - the same path only when `SCRAPS_BUILDROOT` is unset.
  Any scratch root or batch build ended in "build produced no package"
  immediately after a successful compile.
- **`fix_usrmerge` overwrote its caller's loop variable.** It used a bare
  `p` for the path it was repairing, and it is called from `install_one`,
  which runs inside a `for p in ...` loop over package names. A single
  install only showed it in the closing line ("/usr/sbin built from source
  and installed"); installing several from source in one command operated on
  the wrong name from the second onwards.
- **`scraps owns` exited 1 after printing the right answer**, because the
  function ended on a test that is false when the file *was* found.
- **`scraps commit` activated the package and then reported failure**, dying
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
  `is_installed()` tested `[ -d "$SCRAPS_DB/local/$1" ]`, and `install_one`
  wrote PKGINFO *first*, so an install that died or was interrupted anywhere
  after `mkdir` left an entry that every later command believed. `scraps add
  vim` reported vim already installed while `scraps deps vim` died on the DEPS
  file that never got written, and the resolver counted it as satisfied for
  everything that needed it. Fixed by assembling the entry in
  `local/.incoming-<pkg>` and moving it into place with PKGINFO written last,
  keying `is_installed()` on PKGINFO, and having `doctor` find and offer to
  remove entries left by older versions. Verified by creating the exact
  wreckage - a `local/nano/` with no PKGINFO - and re-running all three
  commands.
- **`scraps fetch all` reported four of eight repositories unreachable.** The
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
- **`scraps add alacritty` offered to compile a package that had a binary.**
  Two causes. The index was stale because of the https failure above, and a
  missing *dependency* was reported as if the requested package itself were
  unavailable. scraps now refuses to run at all without an index ("run 'scraps
  fetch all' first"), only offers compilation when no synced repository has a
  binary, and names the chain when a dependency is missing: "alacritty needs
  wayland, and no synced repository has it".
- **Kernel packages could not be installed by the name everything documented.**
  They were built as `ScrapLinux-base-kernel` while `install.conf`, the docs and
  every other package used lowercase. Standardised on lowercase, including
  rewriting the name inside the already-built `.spz` files - renaming the
  file is not enough, `install_one` takes the name from `.PKGINFO`.
- **Installing a kernel re-fetched glibc on a system that already had it.**
  Resolution skipped already-satisfied packages silently, so a re-fetch and a
  correct skip looked identical. Satisfied dependencies now print
  `Dependency met 'glibc', skipping...` and are left alone.
- **A build could not use a package ScrapLinux had just built.** Builds saw only
  the host's headers and libraries. libxcb failed every attempt with
  `IndexError: list index out of range` because `c_client.py` could not see
  xcb-proto's XML, and anything that did build linked against whatever the
  host happened to have. Fixed by the build sysroot described above; libxcb
  builds.
- **`scraps-build` reused `$srcdir` between builds.** Only `$pkgdir` was wiped,
  so every attempt inherited the last one's object files: bzip2's shared
  library failed with "recompile with -fPIC" against objects that predated
  the flag being passed at all. Both trees are wiped now - the tarballs are
  cached separately, so re-extracting costs nothing.
- **`build-batch.sh` skipped packages it had never built.** It tested
  `<name>-*.spz`, so `wayland-protocols-1.48-1.x86_64.spz` answered for
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
  every ScrapLinux install ships `/etc/rc.d/sddm` whether or not sddm is there.
  It reads the script's `CMD` (without sourcing it - sourcing runs the
  service) and reports "not installed" with the missing path, exit 4.
- **`service` died silently without `/etc/scraplinux/rc.lib`.** `.` is a special
  builtin: a shell that cannot open the file exits on the spot, so the
  `|| fallback` after it never ran. Tested before sourcing now.
- **`scraps-repo add` wrote a predictable file into /tmp as root.**
  `/tmp/.scrapsrepo.$$` could be pre-created as a symlink by any local user and
  the tool would truncate whatever it pointed at. The value it wanted was one
  line of a `.PKGINFO` it already had in a variable.
- **The installer's log was a predictable path in a world-writable
  directory.** `/tmp/scraplinux-install.log`, written as root. It goes to
  `/run/scraplinux/install.log` when /run is available, and is `rm -f`'d before
  creation either way, which removes a symlink rather than following it.
- **A fresh install could never `scraps fetch` main/kernels/profile again.**
  mkiso bundles those repos on the medium so `scraplinux-install` works with no
  network, pointing them at `file:///run/scraplinux/medium/...` and disabling the
  matching network repo - with a comment saying scraplinux-install would re-enable
  the network one once installed. That step never existed. Every install left
  the new system pointing at a mount that stops existing when the disc comes
  out. Fixed by doing what the comment already promised, once at the very end
  of the install.
- **`SCRAPS_DB`/`SCRAPS_CACHE`/`SCRAPS_LOG` were never derived from `SCRAPS_ROOT`.**
  Every `--root`-style install recorded its package database into the
  *caller's* `/var/lib/scraps`. A freshly installed system's own database would
  be empty on first boot despite every file being in place.
- **`scraps.conf` could silently override an explicit `SCRAPS_ROOT`.**
  `scraps_load_conf()` sourced the config unconditionally; a plain `SCRAPS_ROOT=/`
  line in it beat whatever a caller had exported. Caller-set values are
  preserved across the config load now.
- **scraps's dispatcher only read `argv[1]` as the subcommand.** `scraps -y ins
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
  does implement that extension, while ScrapLinux's does not.

## Known rough edges

- **A package's declared dependencies are not checked against what it
  actually links.** dwm installs and then fails to start with
  `libharfbuzz.so.0: cannot open shared object file` - it links harfbuzz
  through libXft and does not declare it, so scraps never installed it. mkiso
  closes over real linkage for the image, and nothing does the equivalent for
  ordinary packages, so this is unlikely to be only dwm.
  `build/check-conflicts.sh` already opens every archive and could do the
  audit in the same pass: for each ELF, every DT_NEEDED must be satisfied by
  a declared dependency.
- **The "no compiler" hint names a package that does not exist.** A source
  build on a machine without clang stops with `missing: clang ld.lld` and
  advises `scraps add base-devel`; base-devel has no binary package, so
  following the advice fails. It should say `llvm`, which is the package that
  provides clang and lld - and it comes from the `big` repository, needing
  about 1.2 GiB free to unpack.

- **The packages in the images were compiled by gcc.** ScrapLinux is GNU-free in
  policy before it is in fact. LLVM is packaged now, so the next rebuild has
  a clang to use; nothing has been rebuilt with it yet.
- **The installation image has no signify on it**, so the live session cannot
  check a repository signature and the shipped `.repo` files say `optional`
  rather than `required`. An installed system has both the key and the
  verifier. Building signify into the live rootfs is what makes `required`
  the default.
- **Two conflicts remain between packages that can be installed together**,
  neither in a base install: openexr ships its own copy of Imath, and
  xorg-xwayland and xorg-server both claim `/usr/lib/xorg/protocol.txt` and
  `Xserver.1`. Both are packages installing files that belong to another
  package rather than anything scraps can resolve, and both want a rebuild of
  something large. `build/check-conflicts.sh` lists them; everything else it
  reports is pairs that are alternatives - libressl and openssl, eudev and
  libudev-zero, dinit and sysvinit - which are never installed together.
- **Nothing ships a terminfo database.** netbsd-curses builds the library but
  no compiled database, so `tput` fails on any system - which is what printed
  "tput: cannot access the terminfo database" above every login prompt until
  rc.boot stopped going through `clear` to blank the screen. Curses programs
  fall back to their built-in entries; `tput` itself does not work.

- **LXDE and LXQt have recipes but no packages.** LXDE needs menu-cache and
  vte3 (vte wants LTO it cannot do, systemd, and valac - all turned off now,
  and it still fails to compile); LXQt needs the whole Qt6 stack.
- **s6-66 and systemd-libre are listed as init choices and are not
  packaged.** s6, s6-rc and execline are; 66 itself and systemd are not.
- **btop, openexr and vte3 do not build.** btop's static pieces are compiled
  without `-fPIC` and lld refuses the relocations; openexr's vendored
  libdeflate uses AVX-512 intrinsics in functions built without the target
  feature, which gcc accepted and clang does not; vte fails to compile after
  its LTO, systemd and Vala requirements are turned off. The packages in the
  repository for openexr and btop are older gcc builds.
- **The desktop profiles do not install yet.** `scraplinux-xfce`, `scraplinux-kde`,
  `apiwow-dwm`, `scraplinux-sound` and `niri-dms` are meta-packages whose
  dependencies are still being built. What exists so far: dwm, dwl, st, foot,
  picom, feh, slock, slstatus, dmenu, wayland, libxkbcommon, libxcb,
  xcb-proto, xorgproto, xorg-server, xorg-xinit, libinput, pipewire,
  harfbuzz, lua, imath, bzip2. Still missing, and the reason each profile
  fails today: mesa, noto-fonts, fcft, libconfig, libev for the X profiles;
  wireplumber for audio; the Qt6/KF6/Plasma stack for `scraplinux-kde`; the
  xfce4 component set for `scraplinux-xfce`. Installing one of those
  meta-packages reports exactly which dependency is missing rather than
  failing halfway.
- **wireplumber needs lua 5.4**; ScrapLinux packages 5.5, and its meson build
  will not accept the newer one.
- **ly is not packaged.** It authenticates through PAM, which ScrapLinux does not
  have at all - sddm, lightdm and greetd are built against libxcrypt here.
  Adding ly means either porting its auth to shadow+libxcrypt or adding PAM
  to the base system; neither is done, so it is deliberately absent from
  `A_DM` rather than listed and broken.
- **No QEMU boot test per init yet.** openrc/sysvinit/runit/dinit are
  verified by what `scraplinux-init-setup` generates, not by booting a machine on
  each.
- `btrfs-progs`/`xfsprogs`/`f2fs-tools` aren't baked into the live rootfs the
  way e2fsprogs/dosfstools are — only installable as packages. The
  filesystem picker already only lists what the live session can actually
  format, so this fails safe (fewer options shown), not badly.
- openexr doesn't build under clang: the libdeflate it vendors uses AVX-512
  intrinsics in functions compiled without the target feature, which gcc
  accepted and clang refuses. The package in the repository is an older gcc
  build, and it is the one that ships a second copy of Imath.
- btop doesn't build: its static pieces are compiled without `-fPIC` and lld
  refuses the relocations against a PIE. The package in the repository is an
  older build from before the clang migration.
- helix doesn't build: one of its ~130 tree-sitter grammar dependencies
  (tree-sitter-go-template) was deleted upstream.
- `scraps rollback` restores files but doesn't fully reconcile the package
  database for packages it resurrects; `doctor` reports the resulting
  unsatisfied dependency rather than hiding it.
