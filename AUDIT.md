# ScrapLinux audit, phase 0

Date: 2026-10-04. All numbers here were measured on this machine, not estimated.
Anything not measured is marked "not measured yet" rather than guessed.

## What exists

| Area | Reality |
| --- | --- |
| Init | `scinit`, a single POSIX sh file at `skel/sbin/scinit`, written for this project. The brief calls it `scrapinit`, that name does not exist. |
| Package manager | `scraps`, POSIX sh, with `libscraps.sh`, `scraps-build`, `scraps-repo`, `scraps-strap`. |
| Recipe tree | 692 recipe files on disk, 677 manifest entries, repos: main base extra kernels profile multilib nonfree alt-nonfree. |
| Binary packages | main 122, base 219, extra 66, profile 13, multilib 10, fix 5, kernels 2, nonfree 2. Large packages (llvm, rust, kernels, linux-firmware) are served as GitHub release assets, not in the tree. |
| Display manager | Upstream SDDM 0.21.0 is already packaged and is what the wayland flavor enables at boot. |
| Kernel | `ScrapLinux-base-kernel` 7.1.3. Five further flavors exist (hardened, libre, lts, rt, small) plus five orphaned `Arctic-*` directories that no longer appear in the manifest. |
| Network | wpa_supplicant 2.11 and NetworkManager 1.50.0 packaged. iwd, dhcpcd, chrony and connman are not packaged at all. |
| Profile packages | 10 in the manifest: niri-dms, scraplinux-kde, scraplinux-xfce, apiwow-dwm, apiwow-lxqt, scraplinux-sound, sound-setup, sound-setup-openrc, lazyvim, x11-extra. |

## Measured baseline

Boot, QEMU, UEFI (OVMF), NVMe, 2 vCPU, 2 GB, base console flavor, 10 consecutive runs:

```
run 1   uefi   PASS  wall 5.82s  kernel-handoff 0.942756s  rc.boot 2.46s
run 2   uefi   PASS  wall 5.57s  kernel-handoff 0.743163s  rc.boot 2.44s
run 3   uefi   PASS  wall 6.08s  kernel-handoff 0.906776s  rc.boot 2.45s
run 4   uefi   PASS  wall 5.82s  kernel-handoff 0.891555s  rc.boot 2.49s
run 5   uefi   PASS  wall 6.08s  kernel-handoff 1.194974s  rc.boot 2.40s
run 6   uefi   PASS  wall 5.56s  kernel-handoff 0.823870s  rc.boot 2.50s
run 7   uefi   PASS  wall 6.07s  kernel-handoff 1.023326s  rc.boot 2.59s
run 8   uefi   PASS  wall 5.57s  kernel-handoff 0.752576s  rc.boot 2.60s
run 9   uefi   PASS  wall 5.56s  kernel-handoff 0.726892s  rc.boot 2.43s
run 10  uefi   PASS  wall 5.56s  kernel-handoff 0.708338s  rc.boot 2.51s

10 passed, 0 failed
```

Wall time includes OVMF firmware startup. Kernel handoff is the kernel's own
timestamp for `Run /init as init process`. rc.boot is what `rc.lib` reports.

| Measurement | Value | Phase 10 target | Status |
| --- | --- | --- | --- |
| Boot to login prompt, QEMU UEFI | 5.6 to 6.1 s | under 10 s | meets |
| Panics in 10 consecutive boots | 0 | 0 | meets |
| Boot, QEMU BIOS | fails, see below | must boot | fails |
| `scraps sync`, all 9 repos | 11.91 s | under 5 s | fails |
| `scraps` resolve a small package | 0.48 s | under 1 s | meets |
| Metadata on disk after sync | 128 KB | n/a | n/a |
| Shell startup inside ScrapLinux | not measured yet | under 50 ms | unknown |
| Idle RAM, process count | not measured yet | under 600 MB | unknown |
| Recipe build scoreboard | not measured yet | 100 percent of stable set | unknown |

## Package health, measured

`build/verify-packages.sh` installs a package alone into a clean root and checks
that every ELF it ships resolves. It previously only ever looked at the `main`
and `kernels` repos, in both the repo config and the package loop, so the entire
graphics stack had never been checked by it. After fixing that, a partial run
over the X11 and Wayland closure (killed partway, 58 of 134 packages reached):

```
41 passed, 17 failed
```

Failures with unresolved libraries, which are real defects in dependency data:

| Package | Unresolved | Examples |
| --- | --- | --- |
| gtk3 | 41 | libXext, libXi, libXrandr, libXcursor, libXfixes, libXinerama, libXcomposite, libXdamage, libcups, libepoxy, libxkbcommon |
| imlib2 | 36 | not yet itemised |
| cairo | 21 | not yet itemised |
| libxkbcommon | 11 | libwayland-client, libxcb, libxcb-xkb |
| pango | 11 | not yet itemised |
| flac | 6 | not yet itemised |
| libxaw | 5 | not yet itemised |
| at-spi2-core | 4 | not yet itemised |
| libpciaccess, libsm, libxmu | 3 each | not yet itemised |
| feh | 2 | not yet itemised |
| libsndfile | 1 | not yet itemised |

The pattern is one defect, not twelve: declared runtime dependencies across the
graphics stack are systematically incomplete. A package installs, then fails at
run time because the libraries it links were never pulled in.

`mesa`, `dwm`, `dwl` and `labwc` reported install failures in the same run. That
was a fault in the harness, not the distro: the harness serves packages over
`file://` from the package tree, and large packages such as llvm are GitHub
release assets that do not exist there. `llvm-22.1.8-4.x86_64.spz` returns HTTP
200 from the real release URL, so real installs are unaffected. The harness needs
to learn the `pkgurl` release-asset mechanism before its install results mean
anything.

## Confirmed defects

1. **Dependency metadata is systematically incomplete across the graphics
   stack.** Evidence above. Already fixed for three cases during this session:
   mesa now depends on libglvnd (mesa ships only `libEGL_mesa.so.0`, the real
   `libEGL.so.1` is in libglvnd, and nothing depended on it, so every GL and
   Wayland program failed to start), and wlroots now declares the seventeen
   libraries it actually links instead of eight.

2. **wlroots shipped with no DRM backend.** `wlr_drm_backend_create` was absent
   from the published 0.20.2 and it did not link libdisplay-info, so every
   wlroots compositor could only run nested inside another display server and
   never on real hardware. Cause: wlroots silently drops the DRM backend when it
   cannot find hwdata through pkg-config, and the hwdata package shipped no
   `hwdata.pc` because its recipe ran `make install` without `./configure`.
   Fixed: hwdata now installs its pkg-config file, and the wlroots recipe
   requires its backends explicitly so this becomes a build failure rather than
   a silent omission.

3. **The build sandbox silently used the host's pkg-config files.** `scraps-build`
   set `PKG_CONFIG_PATH` but never `PKG_CONFIG_LIBDIR`, so pkg-config still fell
   through to the host's compiled-in directories. Packages missing from the
   sysroot were reported as found, then failed to compile against headers that
   were not there. Fixed, and `build-batch.sh` now seeds the sysroot with each
   recipe's dependency closure from real binaries.

4. **BIOS boot does not work.** Two causes found so far. The GPT layout had no
   BIOS boot partition, so `limine bios-install` refused outright ("no BIOS boot
   partition specified or detected"); that is fixed in the harness and the
   installer will need the same partition. With that fixed the installer
   succeeds but the kernel still never starts and the serial log stays empty.
   Not yet root caused. This is Phase 8 work.

5. **`scraps sync` takes 11.91 s against a 5 s target.** It fetches nine full
   repository indexes every time with no incremental mechanism.

6. **Five orphaned `Arctic-*` kernel recipe directories** remain on disk from the
   rename and are no longer referenced by the manifest.

## Corrections to the brief

These change the scope of later phases, so they are worth stating plainly.

- **The init is `scinit`, not `scrapinit`.**
- **The display manager is already real upstream SDDM 0.21.0.** There is no
  custom login daemon to delete. What is custom is `sddm-scraplinux-theme`
  ("The ScrapLinux login screen") and a `sddm-logwrap` wrapper script. Phase 7
  is therefore much smaller than the brief assumes: drop the custom theme and
  the wrapper, default to a stock theme.
- **The base console system does not panic.** Ten consecutive UEFI boots, zero
  panics, inside the 10 s budget. The panic reported from real hardware was
  `Attempted to kill init! exitcode=0x00000000` caused by scinit's shutdown path
  calling `reboot` by name through PATH, which resolved back to
  `scraplinux-power`, which is installed as `reboot`. That recursion is fixed.
  Instability is therefore concentrated in the graphical session and on real
  hardware, not in the kernel or in console boot. Real hardware is still
  unverified.
- **apwc work is paused.** Phase 6 defers custom compositors until the base is
  solid, so the in-flight apwc packaging is on hold.

## Open decisions

These are listed in the report rather than decided here, because the brief asks
for them to be decided together.

1. Init: keep and harden `scinit`, or replace it with an upstream supervisor.
2. WiFi: iwd or NetworkManager.
3. Which of the 10 profile packages to delete, and whether the `x11-base` and
   `wayland-base` dependency bundles count as the kind of meta package the brief
   wants removed.
