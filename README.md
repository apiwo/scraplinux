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
A_ENCRYPT=yes
A_INIT=nitro
A_EXTRA=git tmux ripgrep
```

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
```

Binaries come from **[pkg-arctic.apiwow.net](https://pkg-arctic.apiwow.net)**,
recipes from **[ports-arctic.apiwow.net](https://ports-arctic.apiwow.net)**.
The two never mix: a repository in `/etc/alpm/repos.d` serves `.alpmz`
binaries and nothing else.

`ALPM_STYLE` in `/etc/alpm/alpm.conf` picks how an install reads — `arctic`,
`apt` or `aeryn`. Same resolver and the same downloads either way.

`docs/STATUS.md` tracks what is built, what is known-broken, and what is
still source-only.

## Mirrors

Everything is on GitHub and Codeberg both:
[github.com/apiwo](https://github.com/apiwo/arctic-linux) ·
[codeberg.org/apiwo](https://codeberg.org/apiwo/arctic-linux)
