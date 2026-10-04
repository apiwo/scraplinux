# ScrapLinux rescue status

Running tracker for the stabilisation work. Updated after every phase.
The long historical engineering log lives in `docs/STATUS.md` and is separate
from this file.

Current phase: 3, init. The recipe collapse is done and dinit is next.
Decisions taken: dinit as the only init, iwd and dhcpcd for WiFi.

## Works, with evidence

- Base console system boots to a login prompt under QEMU UEFI, 10 consecutive
  runs, zero panics, 5.6 to 6.1 s wall including firmware. See `AUDIT.md`.
- `scraps` resolves a small package in 0.48 s, inside the 1 s target.
- `build/boot-test.sh` builds a test disk, boots it headless, and reports
  pass or fail with a boot time and a full serial log per run.
- wlroots 0.20.2 now builds with its DRM backend, libinput, GLES2, Vulkan and
  XWayland, so a wlroots compositor can address real hardware.
- wlroots 0.19.2 is packaged alongside 0.20 under versioned names.
- Recipes are the only source of package facts. `scraps-repo ports` derives
  `ALL/ports.idx` from 680 recipes in 0.05 s, and refuses a recipe whose name
  does not match its directory or a package defined twice.
- `build/check-recipes.sh` passes all 680 recipes.
- scraps 1.5.1 and scraplinux-base 1.5.0-3 are published. An install of the
  previous pair, upgraded by the old scraps 1.4.35 itself, keeps its password,
  config edits, init link, busybox.conf, signing key and repo files.
- `scraps add -s` resolves recipes from GitHub directly, 680 of them, including
  ones the old manifest never listed.

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
- Init ownership is unsafe. `/sbin` links to `usr/bin`, so the scinit link at
  `/sbin/init` sits on busybox's own `/usr/bin/init`. Reinstalling busybox makes
  busybox init PID 1, and a busybox without that applet would delete the link.
  Resolved by dinit owning `/usr/bin/init` as a package.
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

## Next

dinit 0.19.4 as the only init: package it, write a parallel service set to
replace rc.boot, wire it as `/usr/bin/init`, boot-test it, then remove scinit,
s6, 66, openrc, sysvinit and the busybox init applet. iwd and dhcpcd follow as
background services.
