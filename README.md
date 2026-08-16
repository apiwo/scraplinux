# Arctic Linux

**Arctic Linux - Alpha v.1**

glibc, LLVM, a BSD-style userland, busybox init, zsh, doas, and its own
package manager (alpm).

Full docs: **[arctic-docs.apiwow.net](https://arctic-docs.apiwow.net)**

## Install

Boot the ISO, edit the config, run one command:

```sh
vi /etc/arctic/install.conf
arctic-install
```

Set `A_DISK=/dev/sdX` in the config and that one command partitions,
formats, mounts, installs, and sets up the bootloader. Leave it commented
out and set `A_ROOT_PART=/dev/sdX2` instead to use partitions you made
yourself. Either way, `arctic-install` shows what it is about to do and
asks for confirmation before it touches anything.

## Configure

Everything in `install.conf` is commented out by default — uncomment what
you want:

```sh
A_DESKTOP=niri
A_USER=you
A_USERPASS=...
A_ENCRYPT=yes
A_INIT=nitro
A_EXTRA=git tmux ripgrep
```

One of them is not optional: root ships locked, so an install has to be
given a way in. Set `A_ROOTPASS`, or `A_USER` with `A_USERPASS`, or
authorise a key with `A_SSH=y` and `A_SSH_KEYS`. `arctic-install` refuses a
config that sets none of them rather than producing a system nobody can log
into.

`A_INIT` takes busybox (the default), openrc, sysvinit, runit, dinit or
nitro. Services are declared once in `/etc/rc.d` and translated into
whichever init you pick, so `service start sshd` means the same thing on
all of them.

Once installed, the system stays declarative through
`/etc/arctic/system.conf` + `arctic-rebuild`: list the packages and services
that should exist, run `arctic-rebuild`, and the system matches the file.

```sh
vi /etc/arctic/system.conf
arctic-rebuild
```

Also: `arctic-shell <pkgs>` for a throwaway package environment, `arctic gc`
to clean up.

## Packages

```sh
alpm fetch all          # sync the repositories
alpm ins vim            # install
alpm ins -s helix       # build from source instead
alpm rollback           # undo the last transaction
alpm system fix         # corrections that do not change a version
```

Binaries come from
**[github.com/apiwo/arctic-linux-pkgs](https://github.com/apiwo/arctic-linux-pkgs)**,
served over `raw.githubusercontent.com`; recipes from
**[ports-arctic.apiwow.net](https://ports-arctic.apiwow.net)**. The two never
mix: a repository in `/etc/alpm/repos.d` serves `.alpmz` binaries and nothing
else, and `alpm ins -s` is the only thing that reaches the ports host.

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
