# Building Arctic Linux

These are the scripts that produced the images. They expect a Linux host with a
working C toolchain, `cmake`, `ninja`, `xorriso`, `mksquashfs` and about 30 GiB
free. Paths default to `/home/apiwo/arctic-build`; override with `ARCTIC_BUILD`
where the scripts honour it, or edit `B=` at the top.

```sh
./build.sh               # fetch, kernel, rootfs, usable tools, package, ISO
./build.sh rootfs iso    # or run just the steps you need, in order
```

`build.sh` is the one script to run; it drives everything else in `build/`
through `arctic-sandbox` for you. Its steps, in order: `fetch` (every upstream
tarball named in `sources.list`), `kernel`, `rootfs` (glibc, busybox, toybox,
zsh, doas, and the rest), `usable` (the disk-partitioning and wireless tools
layered on top - see `docs/STATUS.md`), `pkgs` (turn everything into `.alpmz`
and index the repos), `iso` (master the bootable image). Each step is
idempotent: anything already built is skipped, so a failed run can be fixed
and re-run without starting over.

To build one extra package for the repo directly: `build/arctic-sandbox
build/build-batch.sh <name>`.

## Publishing

```sh
build/arctic-sandbox build/publish-fix.sh    # assemble the fix repository
build/arctic-sandbox build/publish-pkgs.sh   # binaries into the pkgs checkout
build/arctic-sandbox build/publish-ports.sh  # recipes into the ports checkout
build/publish-big.sh                         # anything over 100 MB, as a release asset
build/mirror-codeberg.sh                     # the same commits to Codeberg
```

`build/check-conflicts.sh` reads the built archives and reports every path two
packages disagree about, applying alpm's own rules — identical content, a
declared `replaces`, otherwise a conflict. Run it before publishing: the
alternative is finding them one at a time, twenty minutes apart, in a QEMU
install.

Indexes are signed if the machine holds the key (`ALPM_SIGN_KEY`, default
`/home/apiwo/arctic-keys/arctic-pkg.sec`). It is not in any repository and
never will be; the publish scripts say so when they cannot find it rather
than shipping an index nobody can check.

A name-version-release that has already been published cannot be replaced
with different bytes — `publish-pkgs.sh` stops. A client holding the older
index would fetch the new package, check it against the old checksum and
refuse to install it. Bump the release.

## A note on the toolchain

Arctic ships LLVM. glibc, however, cannot be compiled by clang — upstream
requires GCC — so `build-rootfs.sh` uses the host's GCC as a stage-0 tool for
glibc alone. Nothing it produces beyond glibc is packaged.

LLVM itself is a package now — `ports/main/llvm`, 22.1.8, clang and lld and
libc++ — so an installed machine has a compiler and `alpm ins -s` works on it.
It is far past the mirror's file size limit, so it is published the same way
firmware is, through the `big` repository.

This is a *native* build, so every compiler invoked is the host's. The one thing
that must never happen is putting the target `usr/lib` on the linker's search
path: the host linker then tries to link host objects against the freshly built
libc and fails with "file in wrong format". Packages alpm-build produces are
unpacked into `$ALPM_SYSROOT` instead, and later builds see it ahead of the
host through `-isystem`, `-L` and `PKG_CONFIG_PATH`.

On a multilib host there is a trap in the other direction. `/usr/lib` there is
the *32-bit* directory, and Arctic installs to `/usr/lib`, so every `.la` file
records `libdir=/usr/lib` and libtool searches it when it relinks at `make
install`. What it finds is glibc's 32-bit `libc.so`, a linker script beginning
`OUTPUT_FORMAT(elf32-i386)`, and lld obeys it over the `-m` the compiler driver
already passed — every 64-bit object on the line, the crt files included, is
then rejected as "incompatible with elf32-i386". libressl failed exactly that
way and it read as a libressl bug. `alpm-build` puts the host's 64-bit
directory on the line behind the sysroot when it detects that layout.
