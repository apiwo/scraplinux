#!/bin/sh
# build-tarball.sh - build an Arctic Linux base tarball.
#
#   build-tarball.sh def       busybox init (default)
#   build-tarball.sh openrc    OpenRC wired up as init instead
#
# No ISO, no guided installer - see the main site's install guide.
# Bundled raw: glibc, toybox, busybox, zsh, doas, e2fsprogs, util-linux,
# alpm (pre-installed), alpm-strap, arctic-chroot. Not bundled:
# arctic-base, any kernel, limine/grub, genfstab - `alpm add` after
# alpm-strap has synced real repo indexes.
#
# shellcheck shell=sh disable=SC2039

set -eu

FLAVOR=${1:-def}
B=${ARCTIC_BUILD:-/home/apiwo/arctic-build}
SRCTREE=${ARCTIC_TREE:-/home/apiwo/arctic}
REPO=$B/repo
WORK=$B/tarball/$FLAVOR
SCRATCH=$B/tarball/.scratch-$FLAVOR
OUT=$B/tarball-out
ARCH=x86_64

case "$FLAVOR" in
def)    TARNAME="arctic-linux-def-tarball.tar.xz" ;;
openrc) TARNAME="arctic-linux-openrc-tarball.tar.xz" ;;
*) echo "build-tarball.sh: unknown flavor '$FLAVOR' (def or openrc)" >&2; exit 1 ;;
esac

step() { printf '\n\033[1;36m:: %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mok\033[0m %s\n' "$*"; }
die()  { printf '   \033[31mfatal\033[0m %s\n' "$*" >&2; exit 1; }

unmount_work() {
	[ -d "$WORK" ] || return 0
	awk -v w="$WORK" '$2 ~ "^"w {print $2}' /proc/mounts \
		| sort -r | while read -r m; do
		printf '   unmounting stale mount %s\n' "$m"
		umount -l "$m" 2>/dev/null || umount -f "$m" 2>/dev/null || :
	done
	if awk -v w="$WORK" '$2 ~ "^"w {found=1} END{exit !found}' /proc/mounts; then
		die "something is still mounted under $WORK - refusing to delete it"
	fi
}
unmount_work
rm -rf "$WORK"
rm -rf "$SCRATCH"
mkdir -p "$WORK" "$SCRATCH" "$OUT"
S=$WORK

# Merged-/usr: bin/sbin/lib/lib64 -> usr/. Created before any package is
# unpacked, so a package that installs to a literal sbin/ (openrc does)
# lands in usr/bin through the symlink instead of splitting the tree.
mkdir -p "$S/usr/bin" "$S/usr/lib"
for l in bin sbin; do
	ln -s usr/bin "$S/$l" 2>/dev/null || :
done
ln -s usr/lib "$S/lib" 2>/dev/null || :
ln -s usr/lib "$S/lib64" 2>/dev/null || :
mkdir -p "$S/run" "$S/var"
ln -s ../run "$S/var/run" 2>/dev/null || :
ln -s ../run/lock "$S/var/lock" 2>/dev/null || :
mkdir -m 1777 -p "$S/tmp"
mkdir -p "$S/home"

# --------------------------------------------------------- 1. base packages
step "resolving the base package set"

# Same dependency-closure walk as the old ISO builder's live_deps(): named
# packages plus whatever they actually declare as dependencies, read out
# of the repo's own INDEX files rather than assumed.
pkg_deps() {
	_pd_seen="" _pd_todo="$*"
	while [ -n "$_pd_todo" ]; do
		_pd_next=""
		for _pd_p in $_pd_todo; do
			case " $_pd_seen " in *" $_pd_p "*) continue ;; esac
			_pd_seen="$_pd_seen $_pd_p"
			for _pd_i in "$REPO"/*/"$ARCH"/INDEX; do
				[ -f "$_pd_i" ] || continue
				_pd_d=$(awk -F'\t' -v n="$_pd_p" '$1==n{print $8; exit}' "$_pd_i")
				[ -n "$_pd_d" ] && break
			done
			for _pd_x in $_pd_d; do
				[ "$_pd_x" = "-" ] && continue
				case " $_pd_seen $_pd_next " in *" $_pd_x "*) continue ;; esac
				_pd_next="$_pd_next $_pd_x"
			done
		done
		_pd_todo=$_pd_next
	done
	printf '%s\n' $_pd_seen
}

unpack_pkg() {
	# $1 = package name, $2 = REASON (explicit/dep)
	# Resolved through the INDEX (exact name match on column 1), not a
	# filename glob: "busybox-*.alpmz" also matches
	# "busybox-musl-1.38.0-1...alpmz" as a prefix, and sort -V ranked
	# that fake match above the real busybox build it was actually
	# after - a completely different, wrong package silently installed
	# in its place. The INDEX is also the fix for the mtime trap glob+
	# sort had on its own: a full repo repackaging run can regenerate an
	# older release with a fresh timestamp, and only the INDEX's own
	# version/release fields (kept unique per name by alpm-repo gen) say
	# which one is actually current.
	_up_n=$1 _up_reason=${2:-dep}
	_up_pkg=""
	for _up_i in "$REPO"/*/"$ARCH"/INDEX; do
		[ -f "$_up_i" ] || continue
		_up_e=$(awk -F'\t' -v n="$_up_n" '$1==n{print $2"-"$3; exit}' "$_up_i")
		[ -n "$_up_e" ] || continue
		_up_pkg="$(dirname "$_up_i")/$_up_n-$_up_e.$ARCH.alpmz"
		[ -f "$_up_pkg" ] && break
		_up_pkg=""
	done
	if [ -z "$_up_pkg" ]; then
		printf '   %s not built - skipping\n' "$_up_n" >&2
		return 1
	fi
	tar -xf "$_up_pkg" -C "$S" --keep-directory-symlink \
		--exclude=.PKGINFO --exclude=.FILES --exclude=.INSTALL 2>/dev/null || {
		printf '   %s failed to unpack\n' "$_up_n" >&2; return 1; }
	_up_d="$S/var/lib/alpm/local/$_up_n"
	mkdir -p "$_up_d"
	tar -xOf "$_up_pkg" .PKGINFO >"$_up_d/PKGINFO" 2>/dev/null || :
	tar -xOf "$_up_pkg" .FILES   >"$_up_d/FILES"   2>/dev/null || :
	sed -n 's/^depend = //p' "$_up_d/PKGINFO" >"$_up_d/DEPS" 2>/dev/null || : >"$_up_d/DEPS"
	printf '%s\n' "$_up_reason" >"$_up_d/REASON"
	printf 'activated = yes\n' >"$_up_d/STATE"
	return 0
}

# onetrueawk and xz: alpm calls awk internally, and toybox's tar shells
# out to a real xz binary rather than linking liblzma. libarchive: alpm's
# own untar() prefers bsdtar over plain tar whenever it's present, and it
# has to be here - toybox's tar misreads ordinary regular files in the
# kernel package as symlinks ("bad symlink", extraction fails outright)
# on an archive bsdtar reads correctly. None of the three are provided
# by busybox or toybox. Outside a chroot this all goes unnoticed, since
# the host environment's own copies are still on PATH; every one of
# these failures only shows up once arctic-chroot resets PATH to the
# target's own binaries.
BASE_EXPLICIT="glibc toybox busybox zsh doas e2fsprogs util-linux dosfstools onetrueawk xz libarchive"
BASE_SET=$(pkg_deps $BASE_EXPLICIT)
printf '   %s requested, %s with dependencies\n' \
	"$(printf '%s\n' $BASE_EXPLICIT | wc -l | tr -d ' ')" \
	"$(printf '%s\n' $BASE_SET | wc -l | tr -d ' ')"
mkdir -p "$S/var/lib/alpm/local"
for p in $BASE_SET; do
	reason=dep
	case " $BASE_EXPLICIT " in *" $p "*) reason=explicit ;; esac
	unpack_pkg "$p" "$reason" && ok "$p"
done

if [ "$FLAVOR" = openrc ]; then
	step "adding openrc"
	OPENRC_SET=$(pkg_deps openrc)
	for p in $OPENRC_SET; do
		reason=dep
		[ "$p" = openrc ] && reason=explicit
		unpack_pkg "$p" "$reason" && ok "$p"
	done
fi

# ---------------------------------------------------------------- 2. alpm
step "installing alpm itself"
# Not through the package it just unpacked into var/lib/alpm/local - alpm
# ships pre-installed and ready, the same direct-from-source convention
# build/pkg-tools.sh already uses for it, so the tarball never needs a
# bootstrap step just to get a package manager.
mkdir -p "$S/usr/bin" "$S/usr/lib/alpm" "$S/etc/alpm/repos.d"
install -Dm755 "$SRCTREE/alpm/alpm"       "$S/usr/bin/alpm"
install -Dm755 "$SRCTREE/alpm/alpm-build" "$S/usr/bin/alpm-build"
install -Dm755 "$SRCTREE/alpm/alpm-repo"  "$S/usr/bin/alpm-repo"
install -Dm755 "$SRCTREE/alpm/alpm-strap" "$S/usr/bin/alpm-strap"
install -Dm644 "$SRCTREE/alpm/libalpm.sh" "$S/usr/lib/alpm/libalpm.sh"
install -Dm644 "$SRCTREE/skel/etc/alpm/alpm.conf" "$S/etc/alpm/alpm.conf"
cp -f "$SRCTREE/skel/etc/alpm/repos.d/"*.repo "$S/etc/alpm/repos.d/"
mkdir -p "$S/var/lib/alpm/local" "$S/var/lib/alpm/sync" "$S/var/lib/alpm/hold" \
	"$S/var/lib/alpm/snapshots" "$S/var/cache/alpm/pkg" "$S/var/cache/alpm/src" \
	"$S/var/cache/alpm/build"
mkdir -p "$S/etc/arctic"
install -Dm644 "$SRCTREE/skel/etc/arctic/conf.lib" "$S/etc/arctic/conf.lib"

install -Dm755 "$SRCTREE/skel/usr/bin/arctic-chroot" "$S/usr/bin/arctic-chroot"

# Minimal accounts and NSS config - not part of arctic-base, because
# nothing glibc-based works at all without them, chroot included: with
# no /etc/passwd, getpwuid(0) fails and even `id` inside the chroot says
# "bad uid 0" before a single real command has run.
cp -f "$SRCTREE/skel/etc/nsswitch.conf" "$S/etc/nsswitch.conf"
printf 'root:x:0:0:root:/root:/bin/sh\n' >"$S/etc/passwd"
printf 'root:x:0:\nwheel:x:10:\n' >"$S/etc/group"
printf 'root:!:20000:0:99999:7:::\n' >"$S/etc/shadow"
chmod 600 "$S/etc/shadow"
mkdir -p "$S/root"

ok "alpm, alpm-strap, arctic-chroot in place"

# ---------------------------------------------------------------- 3. init
step "wiring up init ($FLAVOR)"
case "$FLAVOR" in
def)
	# busybox's own init, already unpacked as usr/bin/init above via the
	# busybox package's applet symlinks - nothing further to do.
	ok "busybox init (default)"
	;;
openrc)
	# openrc-init is OpenRC's own PID1, not a script busybox init runs -
	# it replaces /sbin/init outright. arctic-init-setup's setup_openrc()
	# translates /etc/rc.d into /etc/init.d once arctic-base is installed
	# from inside chroot; this only points PID1 at the right binary.
	mkdir -p "$S/sbin"
	if [ -f "$S/usr/sbin/openrc-init" ]; then
		ln -sf ../usr/sbin/openrc-init "$S/sbin/init"
	elif [ -f "$S/sbin/openrc-init" ]; then
		ln -sf openrc-init "$S/sbin/init"
	else
		printf '   warning: openrc-init not found in the unpacked package\n' >&2
	fi
	ok "openrc-init wired as /sbin/init - boot-test before trusting this"
	;;
esac

# ------------------------------------------------------- 4. shared libraries
# Same ELF-driven closure the ISO builder used: read what is actually
# linked, not what the package metadata claims, and pull in whatever is
# missing until nothing is.
step "resolving shared libraries"
close_libs() {
	_cl_sonames="$B/tarball/.sonames.$ARCH"
	if [ ! -s "$_cl_sonames" ]; then
		printf '   indexing what each package provides\n'
		for pkg in "$REPO"/*/"$ARCH"/*.alpmz; do
			[ -f "$pkg" ] || continue
			_cl_n=$(basename "$pkg" | sed 's/-[^-]*-[0-9]*\.[^.]*\.alpmz$//')
			tar -xOf "$pkg" .FILES 2>/dev/null | \
				sed -n 's|.*/\([^/]*\.so[^/]*\)$|\1|p' | \
				while read -r so; do printf '%s\t%s\t%s\n' "$so" "$_cl_n" "$pkg"; done
		done >"$_cl_sonames"
	fi
	_cl_round=0
	while [ "$_cl_round" -lt 8 ]; do
		_cl_round=$((_cl_round+1))
		find "$S/usr/bin" "$S/usr/sbin" "$S/usr/lib" -type f 2>/dev/null | \
		while read -r f; do
			case "$f" in *.so|*.so.*|*/bin/*|*/sbin/*) ;; *) continue ;; esac
			readelf -d "$f" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'
		done | sort -u >"$SCRATCH/needed"
		find "$S/usr/lib" -name '*.so*' 2>/dev/null | \
			while read -r l; do basename "$l"; done | sort -u >"$SCRATCH/have"
		comm -23 "$SCRATCH/needed" "$SCRATCH/have" >"$SCRATCH/missing"
		if [ ! -s "$SCRATCH/missing" ]; then
			printf '   every linked library is present\n'
			return 0
		fi
		_cl_added=""
		while read -r lib; do
			[ -n "$lib" ] || continue
			_cl_hit=$(awk -F'\t' -v l="$lib" '$1==l{print $2"\t"$3; exit}' "$_cl_sonames")
			[ -n "$_cl_hit" ] || continue
			_cl_n=$(printf '%s' "$_cl_hit" | cut -f1)
			pkg=$(printf '%s' "$_cl_hit" | cut -f2)
			case " $_cl_added " in *" $_cl_n "*) continue ;; esac
			_cl_added="$_cl_added $_cl_n"
			printf '   %s -> %s\n' "$lib" "$_cl_n"
			unpack_pkg "$_cl_n" dep || :
		done <"$SCRATCH/missing"
		[ -z "$_cl_added" ] && { printf '   unresolved:\n'; sed 's/^/     /' "$SCRATCH/missing"; return 1; }
	done
	return 0
}
close_libs || printf '   the tarball has unresolved libraries - see above\n' >&2

# ------------------------------------------------------------------ 5. release
step "writing /etc/arctic-release"
BUILD_ID=$(date '+%Y.%m.%d')
cat >"$S/etc/arctic-release" <<EOF
NAME="Arctic Linux"
PRETTY_NAME="Arctic Linux"
ID=arctic
BUILD_ID=$BUILD_ID
FLAVOR=$FLAVOR
LIBC=glibc
LIBC_VERSION=2.44
TOOLCHAIN=llvm
USERLAND=bsd
INIT=$FLAVOR
SHELL=zsh
PACKAGE_MANAGER=alpm
HOME_URL="https://github.com/apiwo/arctic-linux"
EOF
cp -f "$S/etc/arctic-release" "$S/etc/os-release"
ok "release info written"

# --------------------------------------------------------------- 6. the tarball
step "writing the tarball"
mkdir -p "$OUT"
rm -f "$OUT/$TARNAME"
( cd "$S" && tar -cJf "$OUT/$TARNAME" . )
( cd "$OUT" && sha256sum "$TARNAME" >"$TARNAME.sha256" )
rm -rf "$SCRATCH"

printf '\n\033[1;36m=== TARBALL DONE ===\033[0m\n'
printf 'flavor:  %s\n' "$FLAVOR"
printf 'file:    %s\n' "$OUT/$TARNAME"
printf 'size:    %s\n' "$(du -h "$OUT/$TARNAME" | cut -f1)"
printf 'sha256:  %s\n' "$(cut -d' ' -f1 "$OUT/$TARNAME.sha256")"
