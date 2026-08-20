# Arctic Linux

glibc, LLVM, a BSD-style userland, busybox init, zsh, doas, and its own
package manager (alpm). Installed by hand, the way Arch or LFS is - no
guided installer, no ISO.

Full docs: **[arctic-docs.apiwow.net](https://arctic-docs.apiwow.net)**

## Install

No ISO. Boot any live Linux, partition and format by hand, then:

```sh
tar -xJf arctic-linux-def-tarball.tar.xz -C /mnt
/mnt/alpm-strap /mnt
/mnt/usr/bin/genfstab /mnt >> /mnt/etc/fstab
/mnt/arctic-chroot /mnt
```

Inside chroot: `passwd`, `adduser <name>`, `alpm add arctic-base`,
`alpm add arctic-<flavor>-kernel`, `alpm add limine`. Exit, then run
`arctic-rebuild` as root to activate the kernel and write the bootloader
config, and deploy it by hand (`limine bios-install /dev/sdX`, or copy the
EFI binaries and register one with `efibootmgr`). Reboot.

An OpenRC flavor of the tarball ships alongside the default (busybox
init) one, with OpenRC already wired up as init instead.

Full walkthrough, including partitioning and encryption:
**[arctic-docs.apiwow.net](https://arctic-docs.apiwow.net)**

## Configure

The base tarball wires up only what boots the machine - devices, mounts,
core init. Everything else (display manager, audio, desktop) is `alpm
add` plus one file. Six small files under `/etc/arctic/` cover what used
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
vi /etc/arctic/identity.conf
arctic-rebuild
```

Also: `arctic-shell <pkgs>` for a throwaway package environment, `arctic gc`
to clean up.

## Wireless

`wifi-connect` with no arguments scans, lists what is in range, asks
which interface and which network, and takes the passphrase with the
characters masked. It remembers a successful connect in
`/etc/arctic/network.conf`, so every boot after reconnects on its own,
in the background, without holding up the login prompt.

## Packages

```sh
alpm fetch all          # sync the repositories
alpm add vim            # install
alpm add -s helix       # build from source instead
alpm rollback           # undo the last transaction
alpm system check       # what's pending: package upgrades and corrections
alpm system upgrade     # sync, upgrade, apply corrections, reconcile system.conf
```

Binaries come from
**[github.com/apiwo/arctic-linux-pkgs](https://github.com/apiwo/arctic-linux-pkgs)**,
served over `raw.githubusercontent.com`; recipes from
**[ports-arctic.apiwow.net](https://ports-arctic.apiwow.net)**. The two never
mix: a repository in `/etc/alpm/repos.d` serves `.alpmz` binaries and nothing
else, and `alpm add -s` is the only thing that reaches the ports host.

Packages too large for a git mirror — the toolchain at 148 MiB, firmware at
162 MiB — are release assets instead. The `big` repository keeps its index
with the others and points `pkgurl` at them, so nothing about installing one
is different.

Every index is signed with signify. The public key arrives with
`arctic-base`, before the first fetch, and a repository says in its `.repo`
file how much its signature matters:

```
sig = required   an index without a good signature is not used
sig = optional   checked when it can be, said out loud when it cannot
sig = off        not checked
```

A signature that does not match is refused under all three. Only a missing
one is tolerated, and only while the installation image is still built
without signify on it.

`ALPM_STYLE` in `/etc/alpm/alpm.conf` picks how an install reads — `arctic`,
`apt` or `aeryn`. Same resolver and the same downloads either way.

`docs/STATUS.md` tracks what is built, what is known-broken, and what is
still source-only.

## Mirrors

[github.com/apiwo](https://github.com/apiwo/arctic-linux) ·
[codeberg.org/apiwo](https://codeberg.org/apiwo/arctic-linux)

The Codeberg mirror is behind: the storage quota there is per account, the
binary package repository filled it, and every push is rejected until that
changes. GitHub is current.
