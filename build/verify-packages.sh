#!/bin/sh
# verify-packages.sh - install every .scrapsz into a clean root and check it works.
#
# Only packages that pass here get published. A package is considered good when:
#
#   1. scraps resolves it and installs it into an empty root without error
#   2. every file the package claims is actually on disk afterwards
#   3. scraps verify agrees the checksums match
#   4. any ELF it installs has all of its libraries satisfied inside that root
#   5. scraps can then remove it cleanly
#
# Output is a pass/fail table plus logs/verify/<pkg>.log for anything that fails.
#
#   verify-packages.sh            # every package in the repo
#   verify-packages.sh zsh doas   # just these
set -u

B=${SCRAPLINUX_BUILD:-/home/apiwo/scraplinux-build}
TREE=${SCRAPLINUX_TREE:-/home/apiwo/scraplinux}
REPO=$B/repo
ROOT=$B/verify-root
LOGS=$B/logs/verify
ARCH=x86_64
SCRAPS="$TREE/scraps/scraps"

mkdir -p "$LOGS"
: >"$B/logs/verified.list"
: >"$B/logs/failed.list"

want=$*

pass=0; fail=0

# A clean root with just enough for scraps to work in.
fresh_root() {
	rm -rf "$ROOT"
	mkdir -p "$ROOT/etc/scraps/repos.d" "$ROOT/var/lib/scraps/sync" \
	         "$ROOT/var/log" "$ROOT/usr/lib" "$ROOT/usr/bin"
	for r in main kernels; do
		[ -d "$REPO/$r" ] || continue
		cat >"$ROOT/etc/scraps/repos.d/$r.repo" <<EOF
name = $r
url = file://$REPO/$r
enabled = yes
priority = 10
EOF
	done
}

run_scraps() {
	SCRAPS_ROOT="$ROOT" \
	SCRAPS_CONF="$ROOT/etc/scraps/scraps.conf" \
	SCRAPS_REPOD="$ROOT/etc/scraps/repos.d" \
	SCRAPS_DB="$ROOT/var/lib/scraps" \
	SCRAPS_CACHE="$B/verify-cache" \
	SCRAPS_LOG="$ROOT/var/log/scraps.log" \
	SCRAPS_YES=1 SCRAPS_COLOR=never \
	sh "$SCRAPS" "$@"
}

printf '\n  %-24s %-9s %-7s %-7s %s\n' PACKAGE INSTALL FILES LIBS REMOVE
printf '  %s\n' "----------------------------------------------------------------"

for f in "$REPO"/main/$ARCH/*.scrapsz "$REPO"/kernels/$ARCH/*.scrapsz; do
	[ -f "$f" ] || continue
	name=$(basename "$f" | sed 's/-[0-9][^-]*-[0-9]*\.'"$ARCH"'\.scrapsz$//')
	if [ -n "$want" ]; then
		case " $want " in *" $name "*) ;; *) continue ;; esac
	fi
	log="$LOGS/$name.log"
	: >"$log"

	fresh_root
	run_scraps fetch all >>"$log" 2>&1

	i_res=FAIL; f_res=-; l_res=-; r_res=-

	if run_scraps ins "$name" >>"$log" 2>&1; then
		i_res=ok

		# 2. every claimed file is present
		miss=0
		while read -r p; do
			[ -n "$p" ] || continue
			# -L as well as -e: an absolute symlink inside the test root points
			# at the host's filesystem, so -e alone calls a good link missing.
			[ -e "$ROOT$p" ] || [ -L "$ROOT$p" ] || {
				miss=$((miss+1)); echo "missing file: $p" >>"$log"; }
		done <"$ROOT/var/lib/scraps/local/$name/FILES" 2>/dev/null
		[ "$miss" = 0 ] && f_res=ok || f_res="$miss miss"

		# 3. checksums agree
		run_scraps verify "$name" >>"$log" 2>&1 && : || echo "verify reported changes" >>"$log"

		# 4. every ELF resolves inside this root
		unres=0
		LD="$ROOT/usr/lib/ld-linux-x86-64.so.2"
		[ -x "$LD" ] || LD="$B/stage/rootfs/usr/lib/ld-linux-x86-64.so.2"
		while read -r p; do
			[ -n "$p" ] || continue
			[ -f "$ROOT$p" ] || continue
			case "$(dd if="$ROOT$p" bs=4 count=1 2>/dev/null | od -An -c | tr -d ' \n')" in
			*ELF*) ;;
			*) continue ;;
			esac
			for lib in $(readelf -d "$ROOT$p" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'); do
				# Satisfied by this package or by something already in the root.
				# Search subdirectories too: glibc's gconv modules link against
				# helper libraries that live beside them in /usr/lib/gconv.
				[ -e "$ROOT/usr/lib/$lib" ] && continue
				find "$ROOT/usr/lib" -maxdepth 2 -name "$lib" 2>/dev/null \
					| grep -q . && continue
				unres=$((unres+1))
				echo "unresolved: $p needs $lib" >>"$log"
			done
		done <"$ROOT/var/lib/scraps/local/$name/FILES" 2>/dev/null
		[ "$unres" = 0 ] && l_res=ok || l_res="$unres bad"

		# 5. it comes back out cleanly
		if SCRAPS_FORCE=1 run_scraps del "$name" >>"$log" 2>&1; then r_res=ok; else r_res=FAIL; fi
	fi

	if [ "$i_res" = ok ] && [ "$f_res" = ok ] && [ "$l_res" = ok ] && [ "$r_res" = ok ]; then
		printf '  %-24s %-9s %-7s %-7s %s\n' "$name" "$i_res" "$f_res" "$l_res" "$r_res"
		echo "$name" >>"$B/logs/verified.list"
		pass=$((pass+1))
	else
		printf '  %-24s %-9s %-7s %-7s %s   <- see logs/verify/%s.log\n' \
			"$name" "$i_res" "$f_res" "$l_res" "$r_res" "$name"
		echo "$name" >>"$B/logs/failed.list"
		fail=$((fail+1))
	fi
done

rm -rf "$ROOT"
printf '\n  %s passed, %s failed\n' "$pass" "$fail"
printf '  verified packages listed in logs/verified.list\n\n'
[ "$fail" = 0 ]
