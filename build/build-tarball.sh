#!/bin/sh
# build-tarball.sh - build an ScrapLinux base tarball.
#
#   build-tarball.sh def       busybox init (default)
#   build-tarball.sh openrc    OpenRC wired up as init instead
#   build-tarball.sh wayland   busybox init, SDDM + a Wayland compositor
#                              lineup bundled directly (dwl, labwc, tinywl,
#                              wio, niri - pick one at the SDDM login screen)
#
# No ISO, no guided installer - see the main site's install guide.
# Bundled raw: glibc, toybox, busybox, zsh, doas, e2fsprogs, util-linux,
# scraps (pre-installed), scraps-strap, scraplinux-chroot. Not bundled:
# scraplinux-base, any kernel, limine/grub, genfstab - `scraps add` after
# scraps-strap has synced real repo indexes.
#
# shellcheck shell=sh disable=SC2039

set -eu

FLAVOR=${1:-def}
B=${SCRAPLINUX_BUILD:-/home/apiwo/scraplinux-build}
SRCTREE=${SCRAPLINUX_TREE:-/home/apiwo/scraplinux}
REPO=$B/repo
WORK=$B/tarball/$FLAVOR
SCRATCH=$B/tarball/.scratch-$FLAVOR
OUT=$B/tarball-out
ARCH=x86_64

case "$FLAVOR" in
def)     TARNAME="scraplinux-def-tarball.tar.xz" ;;
openrc)  TARNAME="scraplinux-openrc-tarball.tar.xz" ;;
wayland) TARNAME="scraplinux-wayland-tarball.tar.xz" ;;
*) echo "build-tarball.sh: unknown flavor '$FLAVOR' (def, openrc or wayland)" >&2; exit 1 ;;
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
# usr/lib64 -> usr/lib too, not just the top-level /lib64 - a handful of
# packages (libffi's own ./configure, xorg-server's compiled-in DRI driver
# search path) end up looking for /usr/lib64 specifically regardless of an
# explicit --libdir=/usr/lib at their own build time. Found the hard way:
# Xorg's AIGLX/GLX loader hardcodes /usr/lib64/dri and never falls back to
# /usr/lib/dri, so a real, correctly-placed swrast_dri.so at /usr/lib/dri
# was invisible to it ("cannot open shared object file") until this existed.
ln -s lib "$S/usr/lib64" 2>/dev/null || :
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
	# filename glob: "busybox-*.spz" also matches
	# "busybox-musl-1.38.0-1...spz" as a prefix, and sort -V ranked
	# that fake match above the real busybox build it was actually
	# after - a completely different, wrong package silently installed
	# in its place. The INDEX is also the fix for the mtime trap glob+
	# sort had on its own: a full repo repackaging run can regenerate an
	# older release with a fresh timestamp, and only the INDEX's own
	# version/release fields (kept unique per name by scraps-repo gen) say
	# which one is actually current.
	_up_n=$1 _up_reason=${2:-dep}
	_up_pkg=""
	for _up_i in "$REPO"/*/"$ARCH"/INDEX; do
		[ -f "$_up_i" ] || continue
		_up_e=$(awk -F'\t' -v n="$_up_n" '$1==n{print $2"-"$3; exit}' "$_up_i")
		[ -n "$_up_e" ] || continue
		_up_pkg="$(dirname "$_up_i")/$_up_n-$_up_e.$ARCH.spz"
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
	_up_d="$S/var/lib/scraps/local/$_up_n"
	mkdir -p "$_up_d"
	tar -xOf "$_up_pkg" .PKGINFO >"$_up_d/PKGINFO" 2>/dev/null || :
	tar -xOf "$_up_pkg" .FILES   >"$_up_d/FILES"   2>/dev/null || :
	sed -n 's/^depend = //p' "$_up_d/PKGINFO" >"$_up_d/DEPS" 2>/dev/null || : >"$_up_d/DEPS"
	printf '%s\n' "$_up_reason" >"$_up_d/REASON"
	printf 'activated = yes\n' >"$_up_d/STATE"
	return 0
}

# onetrueawk and xz: scraps calls awk internally, and toybox's tar shells
# out to a real xz binary rather than linking liblzma. libarchive: scraps's
# own untar() prefers bsdtar over plain tar whenever it's present, and it
# has to be here - toybox's tar misreads ordinary regular files in the
# kernel package as symlinks ("bad symlink", extraction fails outright)
# on an archive bsdtar reads correctly. None of the three are provided
# by busybox or toybox. Outside a chroot this all goes unnoticed, since
# the host environment's own copies are still on PATH; every one of
# these failures only shows up once scraplinux-chroot resets PATH to the
# target's own binaries.
# eudev, not mdev+libudev-zero: eudev ships real hwdb device classification
# (60-input-id.hwdb, 70-mouse.hwdb, 70-touchpad.hwdb, ...), which is what
# X's udev-based InputClass matching actually expects - libudev-zero derives
# device type from raw /sys capability bits with no hwdb at all, a bare-
# minimum shim built for mdev-only setups.
# curl + ca-certificates: scraps's own downloader shells out to curl for
# every https:// fetch (toybox/busybox wget answer "unsupported protocol"
# or, worse, silently send a plaintext request on the TLS port and read
# the connection reset as a generic failure) - and curl itself refuses
# every handshake with no CA bundle to check the server certificate
# against. Neither was ever in this list, so a fresh install had no way
# to bootstrap itself at all: `scraps-strap` and `genfstab` ran fine
# because both are invoked from *outside* the chroot, on the live
# environment's own curl - but every `scraps add` after `scraplinux-chroot`,
# starting with scraplinux-base itself, failed on the very first package
# with a bare "download failed", no interface, no mirror, no proxy
# involved. Confirmed end to end: extracting the tarball fresh, entering
# the chroot with no other network tooling pre-staged, `scraps add
# scraplinux-base` now fetches and installs on the first try.
# bmake: `scraps add -s <pkg>` (a source build - the primary way this package
# manager is meant to be used, binaries being the fallback) refuses outright
# with "this system cannot build from source yet - missing: bmake" on a
# completely fresh install. bmake was documented in this file's own header
# and in docs/STATUS.md's "Core system" list as part of the base image the
# whole time; it was just never actually in BASE_EXPLICIT, so no fresh
# install has ever been able to build a single package from source without
# first fetching bmake by hand from a binary repo it also could not yet
# reach for the same reason curl couldn't (see above) - a fresh install with
# no other network tooling staged had no path to a working source build at
# all, not even a degraded one. byacc/mandoc: same "documented as core,
# never actually bundled" gap for the other two tools this file's own header
# names as always-present - byacc for any recipe needing yacc/bison-shaped
# grammar generation, mandoc for anything that generates a man page as part
# of its own install step.
# gmake: bmake is deliberately ScrapLinux's /usr/bin/make (see the comment in
# gen-ports.py's autotools template), but that same template just as
# deliberately calls a *separate* `gmake` for the actual build/install steps
# - bmake cannot drive automake's dependency-tracking .deps fragments, which
# need nested variable expansion bmake does not have. A real, packaged
# `gmake` (GNU Make 4.4.1) already existed in the repo the whole time; it
# simply had no manifest entry and was never in this list either, so every
# autotools recipe - the large majority of the ports tree - failed at the
# first `gmake -j"$JOBS"` on a fresh install with "gmake: not found", not
# from any actual problem with the package being built.
BASE_EXPLICIT="glibc toybox busybox zsh doas e2fsprogs util-linux dosfstools onetrueawk xz libarchive eudev iw wpa_supplicant ca-certificates curl bmake byacc mandoc gmake"
BASE_SET=$(pkg_deps $BASE_EXPLICIT)
# e2fsprogs depends on util-linux-libs, which BASE_EXPLICIT's own util-linux
# already replaces (same libmount/libblkid/libuuid, see its recipe) - this
# walk has no idea what replaces= means, so both ended up in the set and
# both got unpacked, each claiming ownership of the same files in the
# tarball's own scraps database. Drop the one util-linux already covers.
# BASE_SET is newline-separated (pkg_deps prints one name per line), not
# space-separated - grep -x, not a case glob built on spaces.
if printf '%s\n' $BASE_SET | grep -qx util-linux && \
   printf '%s\n' $BASE_SET | grep -qx util-linux-libs; then
	BASE_SET=$(printf '%s\n' $BASE_SET | grep -vx util-linux-libs)
fi
printf '   %s requested, %s with dependencies\n' \
	"$(printf '%s\n' $BASE_EXPLICIT | wc -l | tr -d ' ')" \
	"$(printf '%s\n' $BASE_SET | wc -l | tr -d ' ')"
mkdir -p "$S/var/lib/scraps/local"
for p in $BASE_SET; do
	reason=dep
	case " $BASE_EXPLICIT " in *" $p "*) reason=explicit ;; esac
	unpack_pkg "$p" "$reason" && ok "$p"
done

# Enable eudev at boot the same way rc.boot's own device-manager check
# expects (existence in /etc/scraplinux/services/udev, content unchecked) -
# without this the marker is absent and rc.boot falls back to mdev even
# with eudev's binary sitting right there unused.
mkdir -p "$S/etc/scraplinux/services"
: >"$S/etc/scraplinux/services/udev"
ok "eudev enabled at boot"

if [ "$FLAVOR" = openrc ]; then
	step "adding openrc"
	OPENRC_SET=$(pkg_deps openrc)
	# openrc depends on util-linux-libs too - same fix as BASE_SET above,
	# same reason: util-linux (already bundled via BASE_EXPLICIT) replaces
	# it, and this walk still has no idea what replaces= means.
	if printf '%s\n' $BASE_SET | grep -qx util-linux && \
	   printf '%s\n' $OPENRC_SET | grep -qx util-linux-libs; then
		OPENRC_SET=$(printf '%s\n' $OPENRC_SET | grep -vx util-linux-libs)
	fi
	for p in $OPENRC_SET; do
		reason=dep
		[ "$p" = openrc ] && reason=explicit
		unpack_pkg "$p" "$reason" && ok "$p"
	done
fi

if [ "$FLAVOR" = wayland ]; then
	step "adding SDDM + the Wayland compositor lineup (dwl/labwc/tinywl/wio/niri)"
	# Every compositor's own -dms profile package pulls in that compositor
	# plus a real session around it - see ports/profile/*-dms. dwl/dms is
	# deliberately not here: the published dwl binary needs
	# libwlroots-0.19.so, which this tree no longer ships, and a rebuild
	# hits a second, unresolved wayland-scanner codegen issue - see
	# ports/base/dwl/recipe.local. kiwmi is deliberately not here either:
	# real wlroots API drift going back to its last 2022 commit, documented
	# in ports/base/kiwmi/recipe.local - it does not build against ScrapLinux's
	# wlroots. "fluxland" from the original ask never matched a real
	# compositor and was dropped. labwc/tinywl/wio/niri is a complete,
	# working four-compositor lineup without either.
	WAYLAND_SET=$(pkg_deps labwc-dms tinywl-dms wio-dms niri-dms sddm sddm-scraplinux-theme)
	# Same util-linux/util-linux-libs collision as openrc above.
	if printf '%s\n' $BASE_SET | grep -qx util-linux && \
	   printf '%s\n' $WAYLAND_SET | grep -qx util-linux-libs; then
		WAYLAND_SET=$(printf '%s\n' $WAYLAND_SET | grep -vx util-linux-libs)
	fi
	for p in $WAYLAND_SET; do
		reason=dep
		case " labwc-dms tinywl-dms wio-dms niri-dms " in *" $p "*) reason=explicit ;; esac
		unpack_pkg "$p" "$reason" && ok "$p"
	done
	# sddm's own package ships the binary, not a boot-time service - wire
	# it up the same way lightdm's rc.d script does, and mark it enabled
	# the same way rc.boot's own service loop expects (existence in
	# /etc/scraplinux/services/, content unchecked - see rc.boot's `for s in
	# /etc/scraplinux/services/*` loop, `[ -e "$s" ]` is the entire test).
	install -Dm755 "$SRCTREE/skel/etc/rc.d/sddm" "$S/etc/rc.d/sddm"
	# start-stop-daemon --background (which rc.d/sddm's svc_main uses)
	# redirects the daemonized child's stdout/stderr to /dev/null before it
	# ever runs - discarding any crash message sddm prints before it gets
	# far enough to open its own /var/log/sddm.log. This wrapper sits in
	# front of it so that output lands in /var/log/sddm-raw.log instead of
	# vanishing, which is the difference between an empty log and an actual
	# reason the next time sddm dies before writing anything itself.
	install -Dm755 "$SRCTREE/skel/usr/bin/sddm-logwrap" "$S/usr/bin/sddm-logwrap"
	mkdir -p "$S/etc/scraplinux/services"
	: >"$S/etc/scraplinux/services/sddm"
	ok "sddm enabled at boot, session picker offers dwl/labwc/tinywl/wio/niri"
fi

# ---------------------------------------------------------------- 2. scraps
step "installing scraps itself"
# Not through the package it just unpacked into var/lib/scraps/local - scraps
# ships pre-installed and ready, the same direct-from-source convention
# build/pkg-tools.sh already uses for it, so the tarball never needs a
# bootstrap step just to get a package manager.
mkdir -p "$S/usr/bin" "$S/usr/lib/scraps" "$S/etc/scraps/repos.d"
install -Dm755 "$SRCTREE/scraps/scraps"       "$S/usr/bin/scraps"
install -Dm755 "$SRCTREE/scraps/scraps-build" "$S/usr/bin/scraps-build"
install -Dm755 "$SRCTREE/scraps/scraps-repo"  "$S/usr/bin/scraps-repo"
install -Dm755 "$SRCTREE/scraps/scraps-strap" "$S/usr/bin/scraps-strap"
install -Dm644 "$SRCTREE/scraps/libscraps.sh" "$S/usr/lib/scraps/libscraps.sh"
install -Dm644 "$SRCTREE/skel/etc/scraps/scraps.conf" "$S/etc/scraps/scraps.conf"
cp -f "$SRCTREE/skel/etc/scraps/repos.d/"*.repo "$S/etc/scraps/repos.d/"
mkdir -p "$S/var/lib/scraps/local" "$S/var/lib/scraps/sync" "$S/var/lib/scraps/hold" \
	"$S/var/lib/scraps/snapshots" "$S/var/cache/scraps/pkg" "$S/var/cache/scraps/src" \
	"$S/var/cache/scraps/build"
mkdir -p "$S/etc/scraplinux"
install -Dm644 "$SRCTREE/skel/etc/scraplinux/conf.lib" "$S/etc/scraplinux/conf.lib"
# svc.lib: every rc.d service script (lightdm, dbus, crond, sddm, ...)
# sources this for start/stop/status - without it here, none of them
# have worked in any tarball flavor at all, pre-existing and unrelated
# to any one flavor.
install -Dm644 "$SRCTREE/skel/etc/scraplinux/svc.lib" "$S/etc/scraplinux/svc.lib"

install -Dm755 "$SRCTREE/skel/usr/bin/scraplinux-chroot" "$S/usr/bin/scraplinux-chroot"

# Minimal accounts and NSS config - not part of scraplinux-base, because
# nothing glibc-based works at all without them, chroot included: with
# no /etc/passwd, getpwuid(0) fails and even `id` inside the chroot says
# "bad uid 0" before a single real command has run.
cp -f "$SRCTREE/skel/etc/nsswitch.conf" "$S/etc/nsswitch.conf"
printf 'root:x:0:0:root:/root:/bin/sh\n' >"$S/etc/passwd"
printf 'root:x:0:\nwheel:x:10:\n' >"$S/etc/group"
printf 'root:!:20000:0:99999:7:::\n' >"$S/etc/shadow"
chmod 600 "$S/etc/shadow"
# login.defs: UID/GID ranges and ENCRYPT_METHOD - without it here, chpasswd/
# useradd fall back to whatever default their own build assumed, and
# toybox's chpasswd defaults to a hash scheme its own login cannot verify
# (see the ENCRYPT_METHOD comment in the file itself). Was created but never
# wired into any tarball flavor's bundling list until now.
install -Dm644 "$SRCTREE/skel/etc/login.defs" "$S/etc/login.defs"
# ld.so.conf: LLVM's runtimes build (libc++/libc++abi/libunwind) installs
# into a target-triple subdirectory by CMake's own default, not straight
# into /usr/lib like every other ScrapLinux package - glibc's dynamic linker
# only trusts /lib and /usr/lib by default, so without this, clang itself
# (and anything linked against libc++, rust/cargo included, since both are
# built with LLVM_USE_LIBCXX=1) fails on a freshly installed system:
# "error while loading shared libraries: libc++.so.1: cannot open shared
# object file". This exact bug and fix are already documented in
# docs/STATUS.md ("Alpha 3 SS") from the old mkiso/skel-copy install
# path - it silently stopped applying when the tarball flavors took over
# with their own curated file list, since ld.so.conf was never added to
# it. scraps already runs ldconfig after every transaction; this just gives
# it something to find.
install -Dm644 "$SRCTREE/skel/etc/ld.so.conf" "$S/etc/ld.so.conf"
mkdir -p "$S/root"

ok "scraps, scraps-strap, scraplinux-chroot in place"

# ---------------------------------------------------------------- 3. init
step "wiring up init ($FLAVOR)"
case "$FLAVOR" in
def|wayland)
	# busybox's own init, already unpacked as usr/bin/init above via the
	# busybox package's applet symlinks - nothing further to do. wayland
	# bundles a desktop on top, but stays busybox init throughout - sddm
	# itself is what actually starts the graphical session, from a
	# regular getty-driven login same as any other busybox-init service.
	ok "busybox init"
	;;
openrc)
	# openrc-init is OpenRC's own PID1, not a script busybox init runs -
	# it replaces /sbin/init outright. scraplinux-init-setup's setup_openrc()
	# translates /etc/rc.d into /etc/init.d once scraplinux-base is installed
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
	# Always rebuilt, never cached across runs: a persistent cache here
	# went stale the moment a single new package was published to the
	# repo, and stayed stale silently - close_libs() itself has no way
	# to notice a cache built hours ago no longer reflects the repo, so
	# newly-built packages (icu, double-conversion, md4c, ...) never got
	# pulled in even though the packages providing them existed on disk
	# the whole time. Re-indexing ~360 packages costs seconds, not
	# minutes; a desktop that silently ships without libicui18n.so does
	# not.
	_cl_sonames="$B/tarball/.sonames.$ARCH"
	printf '   indexing what each package provides\n'
	for pkg in "$REPO"/*/"$ARCH"/*.spz; do
		[ -f "$pkg" ] || continue
		_cl_n=$(basename "$pkg" | sed 's/-[^-]*-[0-9]*\.[^.]*\.spz$//')
		tar -xOf "$pkg" .FILES 2>/dev/null | \
			sed -n 's|.*/\([^/]*\.so[^/]*\)$|\1|p' | \
			while read -r so; do printf '%s\t%s\t%s\n' "$so" "$_cl_n" "$pkg"; done
	done >"$_cl_sonames"
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
		# Every unmatched lib in this round used to just `continue` silently -
		# as long as at least one OTHER lib in the same round resolved,
		# _cl_added stayed non-empty and the round was treated as fully
		# successful, permanently hiding anything with no providing package
		# at all (libxcvt.so.0 - Xorg's own hard dependency, no package ever
		# built for it - was silently dropped this way while libtirpc.so.3
		# resolved in the same round and masked it; only surfaced by an
		# actual boot test, not by this script's own output).
		: >"$SCRATCH/unmatched"
		while read -r lib; do
			[ -n "$lib" ] || continue
			_cl_hit=$(awk -F'\t' -v l="$lib" '$1==l{print $2"\t"$3; exit}' "$_cl_sonames")
			if [ -z "$_cl_hit" ]; then
				printf '%s\n' "$lib" >>"$SCRATCH/unmatched"
				continue
			fi
			_cl_n=$(printf '%s' "$_cl_hit" | cut -f1)
			pkg=$(printf '%s' "$_cl_hit" | cut -f2)
			case " $_cl_added " in *" $_cl_n "*) continue ;; esac
			_cl_added="$_cl_added $_cl_n"
			printf '   %s -> %s\n' "$lib" "$_cl_n"
			unpack_pkg "$_cl_n" dep || :
		done <"$SCRATCH/missing"
		if [ -s "$SCRATCH/unmatched" ]; then
			printf '   no package provides:\n'
			sed 's/^/     /' "$SCRATCH/unmatched"
			return 1
		fi
		[ -z "$_cl_added" ] && { printf '   unresolved:\n'; sed 's/^/     /' "$SCRATCH/missing"; return 1; }
	done
	return 0
}
close_libs || printf '   the tarball has unresolved libraries - see above\n' >&2

# ------------------------------------------------------------------ 5. release
step "writing /etc/scraplinux-release"
BUILD_ID=$(date '+%Y.%m.%d')
cat >"$S/etc/scraplinux-release" <<EOF
NAME="ScrapLinux"
PRETTY_NAME="ScrapLinux"
ID=scraplinux
BUILD_ID=$BUILD_ID
FLAVOR=$FLAVOR
LIBC=glibc
LIBC_VERSION=2.44
TOOLCHAIN=llvm
USERLAND=bsd
INIT=$FLAVOR
SHELL=zsh
PACKAGE_MANAGER=scraps
HOME_URL="https://github.com/apiwo/scraplinux"
EOF
cp -f "$S/etc/scraplinux-release" "$S/etc/os-release"
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
