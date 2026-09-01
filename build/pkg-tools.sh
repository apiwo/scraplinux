#!/bin/sh
# pkg-tools.sh - repackage ScrapLinux's own tooling straight from the source tree.
#
#   build/scraplinux-sandbox build/pkg-tools.sh [version]
#
# scraps and scraplinux-base are shell, configuration and skel files - there is
# nothing to compile - yet the only way to rebuild them was mkpkgs.sh, which
# wants the whole staged rootfs from build-rootfs.sh and repackages the
# entire distribution to do it. That is a long way round for a one-line fix
# to the package manager, and it is why fixes to scraps reached the mirror far
# later than they were made.
#
# The version has to move for `scraps update` to offer the result: an install
# holding scraps 1.0.0 will not replace it with another 1.0.0 however much has
# changed inside.
# shellcheck shell=sh disable=SC2039

set -eu

if [ "${SCRAPLINUX_SANDBOX:-0}" != "1" ]; then
	echo "$(basename "$0"): refusing to run outside the sandbox." >&2
	echo "  run it as:  build/scraplinux-sandbox $0 $*" >&2
	exit 1
fi

B=${SCRAPLINUX_BUILD:-/home/apiwo/scraplinux-build}
SRCTREE=${SCRAPLINUX_TREE:-/home/apiwo/scraplinux}
REPO=$B/repo
PKGDIRS=$B/stage/pkgs
ARCH=x86_64
DATE=$(date '+%s')
VERSION=${1:-1.1.0}

mkdir -p "$PKGDIRS" "$REPO/main/$ARCH"

step() { printf '\n:: %s\n' "$*"; }
ok()   { printf '   ok %s\n' "$*"; }

# Same .PKGINFO/.FILES layout mkpkgs.sh writes; kept identical on purpose so
# a package from here is indistinguishable from one built by a full run.
emit() {
	pd=$1 name=$2 ver=$3 repo=$4 desc=$5 lic=$6 url=$7 deps=$8 backup=${9:-} replaces=${10:-}
	[ -d "$pd" ] || { echo "   $name: nothing staged" >&2; return 1; }
	isize=$(du -sk "$pd" 2>/dev/null | cut -f1); isize=$(( ${isize:-0} * 1024 ))
	{
		printf '# ScrapLinux package, built %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
		printf 'format = 2\nname = %s\nversion = %s\nrelease = 1\narch = %s\n' \
			"$name" "$ver" "$ARCH"
		printf 'desc = %s\nurl = %s\nlicense = %s\n' "$desc" "$url" "$lic"
		printf 'isize = %s\nbuilddate = %s\nbuilder = pkg-tools.sh\nrepo = %s\n' \
			"$isize" "$DATE" "$repo"
		for d in $deps; do printf 'depend = %s\n' "$d"; done
		for b in $backup; do printf 'backup = %s\n' "$b"; done
		for r in $replaces; do printf 'replaces = %s\n' "$r"; done
	} >"$pd/.PKGINFO"
	( cd "$pd" && find . -type f -o -type l ) | sed 's|^\.||' \
		| grep -v '^/\.\(PKGINFO\|FILES\|INSTALL\)$' | sort >"$pd/.FILES"
	# Remove any older build of the same package first, so the repository
	# never holds two versions of it and the index cannot pick the stale one.
	rm -f "$REPO/$repo/$ARCH/$name"-*.spz
	out="$REPO/$repo/$ARCH/$name-$ver-1.$ARCH.spz"
	( cd "$pd" && tar -cf - . | xz -T0 -6 >"$out" )
	ok "$(basename "$out") ($(du -h "$out" | cut -f1), $(wc -l <"$pd/.FILES") files)"
}

# The version scraps reports about itself has to be the version of the package
# that contains it. They were separate strings and drifted: an image built
# straight from the source tree said 1.1.0 while the package said 1.2.0, so
# "the ISO has an old scraps" was true and false at the same time depending on
# which one you asked.
sed -i "s/^SCRAPS_VERSION=\".*\"$/SCRAPS_VERSION=\"$VERSION\"/" "$SRCTREE/scraps/libscraps.sh"

step "packaging scraps $VERSION"
pd=$PKGDIRS/scraps; rm -rf "$pd"
mkdir -p "$pd/usr/bin" "$pd/usr/lib/scraps" "$pd/etc/scraps/repos.d"
install -Dm755 "$SRCTREE/scraps/scraps"       "$pd/usr/bin/scraps"
install -Dm755 "$SRCTREE/scraps/scraps-build" "$pd/usr/bin/scraps-build"
install -Dm755 "$SRCTREE/scraps/scraps-repo"  "$pd/usr/bin/scraps-repo"
install -Dm644 "$SRCTREE/scraps/libscraps.sh" "$pd/usr/lib/scraps/libscraps.sh"
install -Dm644 "$SRCTREE/skel/etc/scraps/scraps.conf" "$pd/etc/scraps/scraps.conf"
cp -f "$SRCTREE/skel/etc/scraps/repos.d/"*.repo "$pd/etc/scraps/repos.d/"
emit "$pd" scraps "$VERSION" main "ScrapLinux Package Manager" "BSD-2-Clause" \
	"https://github.com/apiwo/scraplinux" "busybox"

step "packaging scraplinux-base $VERSION"
pd=$PKGDIRS/scraplinux-base; rm -rf "$pd"
mkdir -p "$pd/usr/share/scraplinux" "$pd/var/lib/scraplinux"
cp -a "$SRCTREE/skel/etc" "$pd/etc"
cp -a "$SRCTREE/skel/usr/." "$pd/usr/"
rm -rf "$pd/etc/scraps"          # scraps owns those files
rm -f "$pd/etc/busybox.conf"   # busybox owns that file
chmod +x "$pd/etc/rc.boot" "$pd/etc/rc.shutdown" "$pd/etc/rc.d"/* "$pd/usr/bin"/*
for f in "$SRCTREE"/branding/ascii/*; do
	[ -f "$f" ] && install -Dm644 "$f" "$pd/usr/share/scraplinux/ascii/$(basename "$f")"
done
emit "$pd" scraplinux-base "$VERSION" main \
	"ScrapLinux base configuration, init scripts and branding" "BSD-2-Clause" \
	"https://github.com/apiwo/scraplinux" "busybox iw wpa_supplicant" \
	"etc/passwd etc/group etc/shadow etc/gshadow etc/inittab etc/profile etc/zsh/zshrc etc/doas.conf etc/scraps/scraps.conf" \
	"arctic-base"

step "reindexing main"
sh "$SRCTREE/scraps/scraps-repo" gen "$REPO/main" "$ARCH" >/dev/null
ok "$(grep -vc '^#' "$REPO/main/$ARCH/INDEX") packages in main"

printf '\nupdate an installed system with:  scraps fetch all && scraps update\n'
