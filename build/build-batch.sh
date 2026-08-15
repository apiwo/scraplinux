#!/bin/sh
# build-batch.sh - build a list of ports into .alpmz binaries.
#
# Feeds each recipe through alpm-build and files whatever succeeds into the
# repository. Failures are expected and fine: a package that will not build
# stays source-only, and alpm offers to compile it on the user's machine
# instead ("WARN: This package has no binary. Proceed to compile Y/n?").
#
#   build-batch.sh                 build the default candidate list
#   build-batch.sh zlib vim ...    build only these
set -u

if [ "${ARCTIC_SANDBOX:-0}" != "1" ]; then
	echo "refusing to build outside the sandbox - use arctic/build/arctic-sandbox" >&2
	exit 1
fi

B=/home/apiwo/arctic-build
TREE=/home/apiwo/arctic
L=$B/logs/batch
mkdir -p "$L"

export ALPM_CACHE="$B/batch-cache"
export ALPM_BUILDROOT="$B/batch-build"
export ALPM_COLOR=never
export ALPM_JOBS=$(nproc)

# Candidates chosen for two reasons: their source URL was verified reachable,
# and they need little beyond what Arctic already has. Anything needing a
# desktop stack, rust, go or a browser toolchain is deliberately absent - those
# are hours to days each and stay source-only for now.
DEFAULT="bzip2 lz4 expat libffi pcre2 attr libcap libedit sqlite less
	nghttp2 c-ares json-c libyaml libpsl brotli libressl openssl curl
	rsync libevent tmux htop vim lua libpng libjpeg-turbo freetype
	libuuid-stub pciutils usbutils libusb wireless-regdb dhcpcd
	libmnl libnftnl iproute2 nftables openssh git"

TARGETS=${*:-$DEFAULT}

find_recipe() {
	for r in main extra base kernels nonfree alt-nonfree multilib profile; do
		[ -f "$TREE/ports/$r/$1/recipe" ] && { printf '%s|%s' "$r" "$TREE/ports/$r/$1/recipe"; return 0; }
	done
	return 1
}

have_binary() {
	for f in "$B/repo/$1/x86_64/"*.alpmz; do
		[ -f "$f" ] || continue
		n=$(basename "$f" | sed 's/-[^-]*-[0-9]*\.[^.]*\.alpmz$//')
		[ "$n" = "$2" ] && return 0
	done
	return 1
}

built=0; failed=0; skipped=0
FAILED_LIST=""

printf '\n  %-22s %-9s %s\n' PACKAGE RESULT NOTE
printf '  %s\n' "--------------------------------------------------------------"

for pkg in $TARGETS; do
	info=$(find_recipe "$pkg") || {
		printf '  %-22s %-9s %s\n' "$pkg" "skip" "no recipe"
		skipped=$((skipped+1)); continue
	}
	repo=${info%%|*}; recipe=${info#*|}

	# Already built and current? Leave it alone.
	#
	# Matched on the name a filename actually decodes to, not on
	# "<name>-*.alpmz": that glob makes every package a prefix of another
	# one's name look built. wayland-protocols-1.48-1.x86_64.alpmz answered
	# for wayland, so wayland was reported "already built" and skipped on
	# every run - while nothing in any repository provided it and every
	# package that depended on it stayed uninstallable.
	if have_binary "$repo" "$pkg"; then
		printf '  %-22s %-9s %s\n' "$pkg" "have" "already built"
		continue
	fi

	if sh "$TREE/alpm/alpm-build" "$recipe" >"$L/$pkg.log" 2>&1; then
		f=$(ls -t "$ALPM_BUILDROOT/out/$pkg"-*.alpmz 2>/dev/null | head -1)
		if [ -n "$f" ]; then
			mkdir -p "$B/repo/$repo/x86_64"
			cp -f "$f" "$B/repo/$repo/x86_64/"
			printf '  %-22s %-9s %s\n' "$pkg" "ok" "$(du -h "$f" | cut -f1) -> $repo"
			built=$((built+1))
		else
			printf '  %-22s %-9s %s\n' "$pkg" "FAIL" "no package produced"
			failed=$((failed+1)); FAILED_LIST="$FAILED_LIST $pkg"
		fi
	else
		why=$(grep -m1 -iE 'error:|No such file|cannot find|not found|checksum' \
			"$L/$pkg.log" 2>/dev/null | cut -c1-38)
		printf '  %-22s %-9s %s\n' "$pkg" "FAIL" "${why:-see logs/batch/$pkg.log}"
		failed=$((failed+1)); FAILED_LIST="$FAILED_LIST $pkg"
	fi
done

# Reindex everything we touched.
for r in main extra base kernels nonfree alt-nonfree multilib profile; do
	[ -d "$B/repo/$r/x86_64" ] || continue
	ls "$B/repo/$r/x86_64"/*.alpmz >/dev/null 2>&1 || continue
	sh "$TREE/alpm/alpm-repo" gen "$B/repo/$r" x86_64 >/dev/null 2>&1 || :
done

printf '\n  %s built, %s failed, %s skipped\n' "$built" "$failed" "$skipped"
[ -n "$FAILED_LIST" ] && printf '  still source-only:%s\n' "$FAILED_LIST"
printf '\n'
for r in main extra base kernels profile; do
	c=$(ls -1 "$B/repo/$r/x86_64"/*.alpmz 2>/dev/null | wc -l | tr -d ' ')
	printf '  %-12s %s binaries\n' "$r" "$c"
done
