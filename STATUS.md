# ScrapLinux rescue status

Running tracker for the stabilisation work. Updated after every phase.
The long historical engineering log lives in `docs/STATUS.md` and is separate
from this file.

Current phase: 3, init. Done and released as 2026.10.06: dinit is the only
init, iwd and dhcpcd the network stack.

## Works, with evidence

- dinit boots the base system to a login prompt under QEMU UEFI, 10 of 10 runs,
  zero panics, about 3.3 s wall including firmware on an idle host (5.6 to 6.1 s
  under scinit) and 1.27 to 1.52 s from kernel handoff to login. Measured per
  service: udev settle 0.32 s and fsck of the ESP 0.4 s are the critical path.
- `boot-test.sh --selftest` boots, confirms pid 1 is dinit, that dinitctl
  reaches it, that the core services are started and root is writable, then
  checks a clean power off. Passes.
- Upgrade path proven: the published scinit system, installed and booted, then
  upgraded with its own scraps 1.5.1, boots under dinit 3 of 3 with its
  enabled services carried over and scinit, rc.boot and rc.d removed. The
  published s66 tarball plus `scraps add scraplinux-base` also boots under dinit.
- A fresh install from the new tarball using only the live mirror boots.
- `scraps` resolves a small package in 0.48 s, inside the 1 s target.
- `build/boot-test.sh` builds a test disk, boots it headless, and reports
  pass or fail with a boot time and a full serial log per run.
- wlroots 0.20.2 now builds with its DRM backend, libinput, GLES2, Vulkan and
  XWayland, so a wlroots compositor can address real hardware.
- wlroots 0.19.2 is packaged alongside 0.20 under versioned names.
- Recipes are the only source of package facts. `scraps-repo ports` derives
  `ALL/ports.idx` from 680 recipes in 0.05 s, and refuses a recipe whose name
  does not match its directory or a package defined twice.
- `build/check-recipes.sh` passes all 666 recipes.
- Published: dinit 0.19.4-2, scraplinux-base 1.6.0-2, scraps 1.5.2, iwd 3.12-2,
  dhcpcd 10.5.2, ell 0.83-2, and dependency-corrected doas, st, dwm, dwl,
  wlroots, wlroots0.19, hwdata, swayidle, xdg-desktop-portal-wlr, encodings and
  font-misc-misc. Every one checked so each linked library has a declared
  provider.
- `scraps add -s` resolves recipes from GitHub directly, including ones the old
  manifest never listed.
- C++ recipes build in the sandbox, against ScrapLinux's own libc++.

## Broken, with evidence

- Graphics stack dependency metadata is systematically incomplete. 17 of the
  first 58 packages checked ship ELFs whose libraries nothing pulls in: gtk3 41,
  imlib2 36, cairo 21, libxkbcommon 11, pango 11 and others. See `AUDIT.md`.
- BIOS boot does not reach the kernel. The missing GPT BIOS boot partition is
  fixed, the remaining cause is unknown. Phase 8.
- `scraps sync` takes 11.91 s against a 5 s target, with no incremental fetch.
- X11 and Wayland sessions are unverified end to end. Not yet attempted in this
  phase.
- Real hardware is entirely unverified in this phase.
- Shell startup, idle RAM, process count and the recipe build scoreboard are not
  measured yet.
- The ports website, ports-scraplinux.apiwow.net, has not deployed since early
  September and serves the old tree. scraps no longer depends on it. Needs the
  Cloudflare Pages project reconnected to the renamed repository.
- 251 recipes have never had a binary published, and 15 published binaries
  carry a newer release than their recipe (llvm, util-linux, pam, rust, ell
  0.83 against a 0.79 recipe, and others). Those binaries came from recipe
  states that are not in the tree.
- busybox still ships init, halt, poweroff and reboot applet links. They are
  harmless now, scraplinux-base and dinit own those paths, but busybox should
  stop shipping them; that rebuild needs its own upgrade test.
- scraps tracks ownership by path string, and `/usr/sbin` links to `/usr/bin`, so
  a package listing `/usr/sbin/halt` (sysvinit did) and one listing
  `/usr/bin/halt` own the same file without either knowing.
- Five recipes do not build in the sandbox: libarchive (libb2), git, foot
  (unknown -Werror option), sway (pcre link) and mesa (a meson dependency).
- X11 has no font-alias package. icewm-3.7.4-1 ships 46 files under a build
  path.
- The 2026.10.06 release has no live ISO; the ISO pipeline still builds
  wpa_supplicant (`build/build-usable.sh`).
- The dependency check behind publishing treats a library with two providers
  (libudev.so.1 from eudev and libudev-zero) as one, giving false positives.
- A display manager and the tty1 getty both want the first VT; unverified.
- 2026.09.01's release page linked checksum files that were never uploaded.
- Upgrading scraps overwrites `/etc/scraps/repos.d/*.repo`, so a repo disabled
  by hand comes back.
- `build/publish-pkgs.sh` mirrors the local build repo wholesale. Today a full
  run would withdraw 11 newer packages and its default target has no git remote.
  Publishing is done per package until that is fixed.
- Codeberg mirroring is stalled: no checkout has a codeberg remote since the
  rename, and the account was over quota. GitHub is the only current mirror.

## Changed in phase 0

| Change | Why |
| --- | --- |
| `build/boot-test.sh` added | There was no way to measure boot time or run the 10 boot test. Builds a disk, boots headless from a qcow2 overlay, logs serial, reports pass or fail. |
| `build/verify-packages.sh` covers every repo | It only ever read `main` and `kernels`, so the whole graphics stack had never been verified. Also takes `SCRAPLINUX_VERIFY_REPO` so it can check the published tree. |
| `scraps-build` sets `PKG_CONFIG_LIBDIR` | pkg-config fell through to the host's own `.pc` files, reporting packages as found that were not in the sysroot. |
| `build/build-batch.sh` seeds the sysroot | The sysroot only held what the same buildroot had compiled, so recipes could not see their own dependencies. |
| `gen-ports.py` meson template unsets `LD_LIBRARY_PATH` | Host meson loaded ScrapLinux's glibc and died before configuring anything. |
| hwdata recipe runs `./configure` | Without it no `hwdata.pc` was installed, which is why wlroots silently dropped its DRM backend. |
| wlroots recipe rewritten, wlroots0.19 added | Backends are now required explicitly rather than left on meson auto, and the full link set is declared. |
| mesa declares libglvnd | mesa ships only `libEGL_mesa.so.0`. `libEGL.so.1` comes from libglvnd, which nothing depended on. |
| `AUDIT.md`, `STATUS.md` added | Phase 0 deliverables. |

## Changed in the recipe collapse

| Change | Why |
| --- | --- |
| `manifest.tsv`, `gen-ports.py`, `recommends.tsv`, 146 `recipe.local` removed | Package facts lived in the manifest and again in the recipe, and drifted. Five binaries linked libraries no recipe declared. |
| `scraps-repo ports` generates `ALL/ports.idx` | scraps needs an index of recipes. It is derived, never edited. |
| 10538 generated comment lines removed from 578 recipes | Template text the generator stamped in. No command changed, checked line by line. |
| scraps shares byte-identical files between packages | The last package to install took the file over, and deleted it when it later stopped shipping it. busybox.conf was about to go on every system. |
| A `replaces=` takeover strips the old owner's last manifest line | `grep -v` exits 1 on empty output, so the old owner kept the path and removing it deleted the new package's file. |
| scraps and scraplinux-base build from a pinned scraplinux commit | Their recipes used files that existed only on the build machine. |
| scraps reads recipes from raw.githubusercontent.com | The ports website stopped deploying. |
| `check-recipes.sh` tracks single quotes | It flagged C preprocessor lines inside dwl's quoted sed script as shell comments. |
| `publish-ports.sh` publishes the checkout in place | Its default target was gone and copying a file onto itself aborted the run. |

## Changed in phase 3, init

| Change | Why |
| --- | --- |
| dinit 0.19.4-2 package | The old one was an Arctic-era build in `/sbin` with no checksum. Now in `/usr/bin`, C++ runtime linked in so pid 1 needs only glibc. |
| dinit service set replaces rc.boot | Serial boot steps became services with real dependencies, so independent ones run in parallel. |
| Services for every rc.d daemon, plus seatd and elogind | Daemons run supervised; dbus signals readiness so its dependents wait for the bus. |
| `service` drives dinitctl | Same commands, so the declarative config keeps working. |
| iwd, dhcpcd, ell recipes; wifi-connect on iwctl | The decided network stack. iwd had a binary and no recipe; ell's binary had no headers. |
| scraplinux-base 1.6.0 owns `/usr/bin/init` and migrates on upgrade | Enabled rc.d services become dinit enables; old init files and markers are removed. |
| scinit, rc.boot, rc.d, svc.lib, rc.lib, inittab, init translator, scraplinux-power, sddm-logwrap removed | One init. dinit's logfile covers what sddm-logwrap did. |
| 66, s6, execline, skalibs, oblibs, openrc, runit, sysvinit, initialization withdrawn | Nothing depended on them. |
| scraps-build: glibc kept off LD_LIBRARY_PATH, `--sysroot` in LDFLAGS, MAKESYSPATH | Host tools crashed on the sysroot's glibc, LDFLAGS-only links reached the host's 32-bit libc, bmake had no sys.mk. Nine of fourteen rebuilt recipes had stopped building. |
| scraps-build refuses payloads under the sysroot path | iwd, encodings and font-misc-misc installed into the build machine's paths. |
| build-batch rebuilds on a release change and seeds libc++ | A bumped release never rebuilt; no C++ recipe could build. |
| build-tarball fails on a missing base package | A tarball without busybox, and so without a shell, was written as a success. |
| scraplinux-base 1.5.0-4, scraps 1.5.1-2 | 1.5.0-3 installed `/etc/shadow` world readable on roots without one. Upgrades fix the modes. |

## Next

Phase 4 per the brief, or the X11 and Wayland dependency sweep the user asked
for first: rebuild the five failing recipes, the graphics packages the audit
flagged, font-alias, and verify an X11 and a Wayland session end to end.
