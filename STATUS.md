# ScrapLinux rescue status

Running tracker for the stabilisation work. Updated after every phase.
The long historical engineering log lives in `docs/STATUS.md` and is separate
from this file.

Current phase: 0, audit and baseline. Complete, awaiting decisions before
phase 1 starts.

## Works, with evidence

- Base console system boots to a login prompt under QEMU UEFI, 10 consecutive
  runs, zero panics, 5.6 to 6.1 s wall including firmware. See `AUDIT.md`.
- `scraps` resolves a small package in 0.48 s, inside the 1 s target.
- `build/boot-test.sh` builds a test disk, boots it headless, and reports
  pass or fail with a boot time and a full serial log per run.
- wlroots 0.20.2 now builds with its DRM backend, libinput, GLES2, Vulkan and
  XWayland, so a wlroots compositor can address real hardware.
- wlroots 0.19.2 is packaged alongside 0.20 under versioned names.

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

## Next

Blocked on three decisions before phase 1 begins: the init, the WiFi stack, and
which profile packages go. They are in the report and in `AUDIT.md`.

Once those are settled, phase 1 is the filesystem layout and toolchain checker,
then phase 2 the kernel, then phase 3 init and boot speed.
