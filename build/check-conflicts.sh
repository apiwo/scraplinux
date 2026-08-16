#!/bin/sh
# check-conflicts.sh - find file conflicts between packages before an install does.
#
#   build/check-conflicts.sh [dir ...]      default: the published site tree
#
# alpm refuses to install a package whose files another package already owns,
# unless the two files are byte-for-byte identical or the incoming recipe says
# it `replaces` the owner. The refusal is correct, but it lands on the machine
# being installed, part way through the base system, and every path is found
# one twenty-minute QEMU run at a time: busybox and toybox disagreed about
# twenty-two applets and the installer stopped at the first of them.
#
# This reads the archives instead and applies the same three rules, so the
# whole set of collisions is on screen in a couple of minutes.
#
# Exit status is 1 when a real conflict remains, so it can gate a publish.
# shellcheck shell=sh disable=SC2039

set -eu

B=${ARCTIC_BUILD:-/home/apiwo/arctic-build}
SITE=${ARCTIC_SITE:-$B/src-extra/arctic-linux-pkgs}
ARCH=x86_64
WORK=$B/tmp/conflicts

if [ $# -gt 0 ]; then
	DIRS=$*
else
	DIRS=$(find "$SITE/ALL" -type d -name "$ARCH" | sort | tr '\n' ' ')
fi

rm -rf "$WORK"
mkdir -p "$WORK/x"
OWNERS=$WORK/owners
REPLACES=$WORK/replaces
: >"$OWNERS"
: >"$REPLACES"

sha() { sha256sum "$1" | cut -d' ' -f1; }

# One package at a time: extract, record a signature per path, throw the
# extraction away. Keeping every package unpacked at once would need the whole
# distribution on disk twice over, kernels included.
scan_one() {
	archive=$1
	rm -rf "$WORK/x"
	mkdir -p "$WORK/x"
	tar -xf "$archive" -C "$WORK/x" 2>/dev/null || {
		printf 'unreadable: %s\n' "$archive" >&2
		return 0
	}
	[ -f "$WORK/x/.PKGINFO" ] || return 0
	name=$(sed -n 's/^[ 	]*name[ 	]*=[ 	]*//p' "$WORK/x/.PKGINFO" | head -1)
	[ -n "$name" ] || return 0
	sed -n 's/^[ 	]*replaces[ 	]*=[ 	]*//p' "$WORK/x/.PKGINFO" | \
		while read -r r; do
			for one in $r; do
				printf '%s\t%s\n' "$name" "$one" >>"$REPLACES"
			done
		done

	( cd "$WORK/x" && find . \( -type f -o -type l \) ) | sed 's|^\.||' | \
	while read -r f; do
		case "$f" in /.PKGINFO|/.INSTALL|/.FILES) continue ;; esac
		if [ -L "$WORK/x$f" ]; then
			sig="L:$(readlink "$WORK/x$f")"
		else
			sig="F:$(sha "$WORK/x$f")"
		fi
		printf '%s\t%s\t%s\n' "$f" "$name" "$sig" >>"$OWNERS"
	done
}

total=0
for d in $DIRS; do
	[ -d "$d" ] || continue
	for a in "$d"/*.alpmz; do
		[ -f "$a" ] || continue
		total=$((total + 1))
		printf '\r  scanned %s packages' "$total" >&2
		scan_one "$a"
	done
done
rm -rf "$WORK/x"
printf '\r  scanned %s packages\n' "$total" >&2

# A conflict is a path claimed by two packages with different content. The
# `replaces` escape is honoured in either direction: which of the two is
# installed second decides whether alpm needs it, and the resolver - not this
# script - decides that order.
replaced() {
	grep -qx "$1	$2" "$REPLACES" 2>/dev/null || grep -qx "$2	$1" "$REPLACES" 2>/dev/null
}

sort -u "$OWNERS" >"$WORK/owners.sorted"
cut -f1 "$WORK/owners.sorted" | uniq -d >"$WORK/paths"

conflicts=0
covered=0
while read -r path; do
	[ -n "$path" ] || continue
	pkgs=$(awk -F'\t' -v p="$path" '$1 == p { print $2 }' "$WORK/owners.sorted" | sort -u)
	sigs=$(awk -F'\t' -v p="$path" '$1 == p { print $3 }' "$WORK/owners.sorted" | sort -u)
	# Identical content everywhere: alpm hands the path over and moves on.
	[ "$(printf '%s\n' "$sigs" | wc -l)" -gt 1 ] || continue
	first=$(printf '%s\n' "$pkgs" | head -1)
	rest=$(printf '%s\n' "$pkgs" | tail -n +2)
	unresolved=""
	for other in $rest; do
		replaced "$first" "$other" || unresolved="${unresolved:+$unresolved }$other"
	done
	if [ -z "$unresolved" ]; then
		covered=$((covered + 1))
		continue
	fi
	conflicts=$((conflicts + 1))
	printf '%s\n  %s\n' "$path" "$(printf '%s' "$pkgs" | tr '\n' ' ')"
done <"$WORK/paths"

printf '\n%s unresolved, %s covered by replaces\n' "$conflicts" "$covered"
[ "$conflicts" -eq 0 ]
