# ScrapLinux

glibc, LLVM, a BSD-style userland, busybox init, zsh, doas, and its own
package manager (scraps). Installed by hand, the way Gentoo or Kiss is - no
guided installer, no ISO.

Full docs: **[scraplinux-docs.apiwow.net](https://scraplinux-docs.apiwow.net)**

## Install

Boot any live Linux distribution or use an SSH, then partition and format by hand, then:

```sh
tar -xJf scraplinux-def-tarball.tar.xz -C /mnt
/mnt/scraps-strap /mnt
/mnt/usr/bin/genfstab /mnt >> /mnt/etc/fstab
/mnt/scraplinux-chroot /mnt
```

Inside chroot: `passwd`, `adduser <name>`, `scraps add scraplinux-base`,
`scraps add scraplinux-<flavor>-kernel`, `scraps add limine`. Exit, then run
`scraplinux-rebuild` as root to activate the kernel and write the bootloader
config, and deploy it by hand (`limine bios-install /dev/sdX`, or copy the
EFI binaries and register one with `efibootmgr`). Reboot.

An OpenRC flavor of the tarball ships alongside the default (busybox
init) one, with OpenRC already wired up as init instead.

Full walkthrough, including partitioning and encryption:
**[scraplinux-docs.apiwow.net](https://scraplinux-docs.apiwow.net)**

## Configure

The base tarball wires up only what boots the machine - devices, mounts,
core init. Everything else (display manager, audio, desktop) is `scraps
add` plus one file. Six small files under `/etc/scraplinux/` cover what used
to be one big config:

```
pkgs.conf       mirrors what's explicitly installed - never hand-edited
network.conf    wifi-connect writes this; rc.d/wifi reads it back at boot
users.conf      declared accounts, additive only
services.conf   the enabled service list
hardware.conf   gpu, microcode, bootloader, boot timeout
identity.conf   hostname, timezone, locale, keymap
```

Edit one, then reconcile it:

```sh
vi /etc/scraplinux/identity.conf
scraplinux-rebuild
```

Also: `scraplinux-shell <pkgs>` for a throwaway package environment, `scraplinux gc`
to clean up.

## Wireless

`wifi-connect` with no arguments scans, lists what is in range, asks
which interface and which network, and takes the passphrase with the
characters masked. It remembers a successful connect in
`/etc/scraplinux/network.conf`, so every boot after reconnects on its own,
in the background, without holding up the login prompt.

## Packages

```sh
scraps fetch all          # sync the repositories
scraps add vim            # install
scraps add -s helix       # build from source instead
scraps rollback           # undo the last transaction
scraps system check       # what's pending: package upgrades and corrections
scraps system upgrade     # sync, upgrade, apply corrections, reconcile system.conf
```

Binaries come from
**[github.com/apiwo/scraplinux-pkgs](https://github.com/apiwo/scraplinux-pkgs)**,
served over `raw.githubusercontent.com`; recipes from
**[ports-scraplinux.apiwow.net](https://ports-scraplinux.apiwow.net)**. The two never
mix: a repository in `/etc/scraps/repos.d` serves `.spz` binaries and nothing
else, and `scraps add -s` is the only thing that reaches the ports host.

Packages too large for a git mirror — the toolchain at 148 MiB, firmware at
162 MiB — are release assets instead. The `big` repository keeps its index
with the others and points `pkgurl` at them, so nothing about installing one
is different.

Every index is signed with signify. The public key arrives with
`scraplinux-base`, before the first fetch, and a repository says in its `.repo`
file how much its signature matters:

```
sig = required   an index without a good signature is not used
sig = optional   checked when it can be, said out loud when it cannot
sig = off        not checked
```

A signature that does not match is refused under all three. Only a missing
one is tolerated, and only while the installation image is still built
without signify on it.

`SCRAPS_STYLE` in `/etc/scraps/scraps.conf` picks how an install reads — `scraplinux`,
`apt` or `aeryn`. Same resolver and the same downloads either way.

`docs/STATUS.md` tracks what is built, what is known-broken, and what is
still source-only.

## License

ScrapLinux's own code — `scraps`, the base system, the build tooling, the
ports/recipe infrastructure, the site and docs — is licensed under the
[GNU General Public License v3.0 or later](LICENSE). Anyone can use, study,
modify and redistribute it; a distributed modified version has to stay
under the same license and keep attribution intact, so it can't be taken
proprietary or stripped of credit downstream.

Packaged third-party software keeps whatever license its own upstream
project uses — each recipe's `license=` field says which.

## Mirrors

[github.com/apiwo](https://github.com/apiwo/scraplinux) ·
[codeberg.org/apiwo](https://codeberg.org/apiwo/scraplinux)

The Codeberg mirror is behind: the storage quota there is per account, the
binary package repository filled it, and every push is rejected until that
changes. GitHub is current.
