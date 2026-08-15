#!/bin/sh
# pkg-tools.sh - repackage Arctic's own tooling straight from the source tree.
#
#   build/arctic-sandbox build/pkg-tools.sh [version]
#
# alpm and arctic-base are shell, configuration and skel files - there is
# nothing to compile - yet the only way to rebuild them was mkpkgs.sh, which
# wants the whole staged rootfs from build-rootfs.sh and repackages the
# entire distribution to do it. That is a long way round for a one-line fix
# to the package manager, and it is why fixes to alpm reached the mirror far
# later than they were made.
#
# The version has to move for `alpm update` to offer the result: an install
# holding alpm 1.0.0 will not replace it with another 1.0.0 however much has
# changed inside.
# shellcheck shell=sh disable=SC2039

set -eu

if [ "${ARCTIC_SANDBOX:-0}" != "1" ]; then
	echo "$(basename "$0"): refusing to run outside the sandbox." >&2
	echo "  run it as:  build/arctic-sandbox $0 $*" >&2
	exit 1
fi

B=${ARCTIC_BUILD:-/home/apiwo/arctic-build}
SRCTREE=${ARCTIC_TREE:-/home/apiwo/arctic}
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
	pd=$1 name=$2 ver=$3 repo=$4 desc=$5 lic=$6 url=$7 deps=$8
	[ -d "$pd" ] || { echo "   $name: nothing staged" >&2; return 1; }
	isize=$(du -sk "$pd" 2>/dev/null | cut -f1); isize=$(( ${isize:-0} * 1024 ))
	{
		printf '# Arctic Linux package, built %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
		printf 'format = 2\nname = %s\nversion = %s\nrelease = 1\narch = %s\n' \
			"$name" "$ver" "$ARCH"
		printf 'desc = %s\nurl = %s\nlicense = %s\n' "$desc" "$url" "$lic"
		printf 'isize = %s\nbuilddate = %s\nbuilder = pkg-tools.sh\nrepo = %s\n' \
			"$isize" "$DATE" "$repo"
		for d in $deps; do printf 'depend = %s\n' "$d"; done
	} >"$pd/.PKGINFO"
	( cd "$pd" && find . -type f -o -type l ) | sed 's|^\.||' \
		| grep -v '^/\.\(PKGINFO\|FILES\|INSTALL\)$' | sort >"$pd/.FILES"
	# Remove any older build of the same package first, so the repository
	# never holds two versions of it and the index cannot pick the stale one.
	rm -f "$REPO/$repo/$ARCH/$name"-*.alpmz
	out="$REPO/$repo/$ARCH/$name-$ver-1.$ARCH.alpmz"
	( cd "$pd" && tar -cf - . | xz -T0 -6 >"$out" )
	ok "$(basename "$out") ($(du -h "$out" | cut -f1), $(wc -l <"$pd/.FILES") files)"
}

# The version alpm reports about itself has to be the version of the package
# that contains it. They were separate strings and drifted: an image built
# straight from the source tree said 1.1.0 while the package said 1.2.0, so
# "the ISO has an old alpm" was true and false at the same time depending on
# which one you asked.
sed -i "s/^ALPM_VERSION=\".*\"$/ALPM_VERSION=\"$VERSION\"/" "$SRCTREE/alpm/libalpm.sh"

step "packaging alpm $VERSION"
pd=$PKGDIRS/alpm; rm -rf "$pd"
mkdir -p "$pd/usr/bin" "$pd/usr/lib/alpm" "$pd/etc/alpm/repos.d"
install -Dm755 "$SRCTREE/alpm/alpm"       "$pd/usr/bin/alpm"
install -Dm755 "$SRCTREE/alpm/alpm-build" "$pd/usr/bin/alpm-build"
install -Dm755 "$SRCTREE/alpm/alpm-repo"  "$pd/usr/bin/alpm-repo"
install -Dm644 "$SRCTREE/alpm/libalpm.sh" "$pd/usr/lib/alpm/libalpm.sh"
install -Dm644 "$SRCTREE/skel/etc/alpm/alpm.conf" "$pd/etc/alpm/alpm.conf"
cp -f "$SRCTREE/skel/etc/alpm/repos.d/"*.repo "$pd/etc/alpm/repos.d/"
emit "$pd" alpm "$VERSION" main "Arctic Linux Package Manager" "BSD-2-Clause" \
	"https://github.com/apiwo/arctic-linux" "busybox"

step "packaging arctic-base $VERSION"
pd=$PKGDIRS/arctic-base; rm -rf "$pd"
mkdir -p "$pd/usr/share/arctic" "$pd/var/lib/arctic"
cp -a "$SRCTREE/skel/etc" "$pd/etc"
cp -a "$SRCTREE/skel/usr/." "$pd/usr/"
rm -rf "$pd/etc/alpm"   # alpm owns those files
chmod +x "$pd/etc/rc.boot" "$pd/etc/rc.shutdown" "$pd/etc/rc.d"/* "$pd/usr/bin"/*
for f in "$SRCTREE"/branding/ascii/*; do
	[ -f "$f" ] && install -Dm644 "$f" "$pd/usr/share/arctic/ascii/$(basename "$f")"
done
emit "$pd" arctic-base "$VERSION" main \
	"Arctic base configuration, init scripts and branding" "BSD-2-Clause" \
	"https://github.com/apiwo/arctic-linux" "busybox"

step "reindexing main"
sh "$SRCTREE/alpm/alpm-repo" gen "$REPO/main" "$ARCH" >/dev/null
ok "$(grep -vc '^#' "$REPO/main/$ARCH/INDEX") packages in main"

printf '\nupdate an installed system with:  alpm fetch all && alpm update\n'
