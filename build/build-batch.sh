#!/bin/sh
# build-batch.sh - build a list of ports into .scrapsz binaries.
#
# Feeds each recipe through scraps-build and files whatever succeeds into the
# repository. Failures are expected and fine: a package that will not build
# stays source-only, and scraps offers to compile it on the user's machine
# instead ("WARN: This package has no binary. Proceed to compile Y/n?").
#
#   build-batch.sh                 build the default candidate list
#   build-batch.sh zlib vim ...    build only these
set -u

if [ "${SCRAPLINUX_SANDBOX:-0}" != "1" ]; then
	echo "refusing to build outside the sandbox - use scraplinux/build/scraplinux-sandbox" >&2
	exit 1
fi

B=/home/apiwo/scraplinux-build
TREE=/home/apiwo/scraplinux
L=$B/logs/batch
mkdir -p "$L"

export SCRAPS_CACHE="$B/batch-cache"
export SCRAPS_BUILDROOT="$B/batch-build"
export SCRAPS_COLOR=never
export SCRAPS_JOBS=$(nproc)

# Candidates chosen for two reasons: their source URL was verified reachable,
# and they need little beyond what ScrapLinux already has. Anything needing a
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
	for f in "$B/repo/$1/x86_64/"*.scrapsz; do
		[ -f "$f" ] || continue
		n=$(basename "$f" | sed 's/-[^-]*-[0-9]*\.[^.]*\.scrapsz$//')
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
	# "<name>-*.scrapsz": that glob makes every package a prefix of another
	# one's name look built. wayland-protocols-1.48-1.x86_64.scrapsz answered
	# for wayland, so wayland was reported "already built" and skipped on
	# every run - while nothing in any repository provided it and every
	# package that depended on it stayed uninstallable.
	if have_binary "$repo" "$pkg"; then
		printf '  %-22s %-9s %s\n' "$pkg" "have" "already built"
		continue
	fi

	if sh "$TREE/scraps/scraps-build" "$recipe" >"$L/$pkg.log" 2>&1; then
		f=$(ls -t "$SCRAPS_BUILDROOT/out/$pkg"-*.scrapsz 2>/dev/null | head -1)
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
	ls "$B/repo/$r/x86_64"/*.scrapsz >/dev/null 2>&1 || continue
	sh "$TREE/scraps/scraps-repo" gen "$B/repo/$r" x86_64 >/dev/null 2>&1 || :
done

printf '\n  %s built, %s failed, %s skipped\n' "$built" "$failed" "$skipped"
[ -n "$FAILED_LIST" ] && printf '  still source-only:%s\n' "$FAILED_LIST"
printf '\n'
for r in main extra base kernels profile; do
	c=$(ls -1 "$B/repo/$r/x86_64"/*.scrapsz 2>/dev/null | wc -l | tr -d ' ')
	printf '  %-12s %s binaries\n' "$r" "$c"
done
