# Arctic Linux

glibc,(experimental musl) LLVM, a BSD-style userland, busybox init, zsh, doas, and its own
package manager (alpm).

Full docs: **[arctic-linux.apiwow.net](https://arctic-linux.apiwow.net)**

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
A_EXTRA=git tmux ripgrep
```

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

`docs/STATUS.md` in this repo tracks build status. Package downloads and
docs are on the site above.
