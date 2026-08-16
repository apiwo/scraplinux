#!/bin/sh
# publish-fix.sh - assemble the fix repository from the manifest.
#
#   build/arctic-sandbox build/publish-fix.sh
#
# The fix repository is an ordinary binary repository with one extra file in
# it. Every package the manifest names is copied in from the build repository
# at the version the manifest asks for, so "alpm system fix" installs a real
# .alpmz and the system stays binary - there is no patch format and nothing is
# compiled on the machine taking the fix.
#
# Publishing is a copy, never a build: if the manifest names a version that
# has not been built, that is an error worth stopping on rather than quietly
# shipping whatever version happens to be lying around.
# shellcheck shell=sh disable=SC2039

set -eu

if [ "${ARCTIC_SANDBOX:-0}" != "1" ]; then
	echo "$(basename "$0"): refusing to run outside the sandbox." >&2
	echo "  run it as:  build/arctic-sandbox $0 $*" >&2
	exit 1
fi

B=${ARCTIC_BUILD:-/home/apiwo/arctic-build}
TREE=${ARCTIC_TREE:-/home/apiwo/arctic}
ARCH=x86_64
SRC=$TREE/fix/FIXES
DEST=$B/repo/fix/$ARCH

[ -f "$SRC" ] || { echo "publish-fix.sh: no manifest at $SRC" >&2; exit 1; }

mkdir -p "$DEST"

step() { printf '\n:: %s\n' "$*"; }
ok()   { printf '   ok %s\n' "$*"; }

step "reading $SRC"

# Collect the distinct package/version pairs the manifest refers to. Several
# fixes usually ride in the same package, and it only has to be copied once.
want=$(awk -F'	' '$1 !~ /^#/ && NF >= 5 { print $4 "-" $5 }' "$SRC" | sort -u)
[ -n "$want" ] || { echo "publish-fix.sh: manifest names no packages" >&2; exit 1; }

missing=""
copied=0
for pv in $want; do
	# Split on the last dash: package names contain dashes, versions do not.
	ver=${pv##*-}
	name=${pv%-*}
	found=""
	foundrel=0
	# The manifest names a version, not a release, and a version is usually
	# rebuilt several times before the fix is right. The highest release is
	# the one that carries it. Taking the first name a glob produced took
	# the lowest instead - and would have taken -10 over -2 - so a fix could
	# be published as a package that predated it.
	for r in main extra base kernels profile nonfree alt-nonfree multilib; do
		for f in "$B/repo/$r/$ARCH/$name-$ver-"*.alpmz; do
			[ -f "$f" ] || continue
			rel=${f##*-}
			rel=${rel%%.*}
			case $rel in *[!0-9]*) continue ;; esac
			if [ -z "$found" ] || [ "$rel" -gt "$foundrel" ]; then
				found=$f
				foundrel=$rel
			fi
		done
		[ -n "$found" ] && break
	done
	if [ -z "$found" ]; then
		missing="$missing $name-$ver"
		continue
	fi
	# Drop any other release of the same package first, so the fix repository
	# never offers two versions of one package and the index cannot pick the
	# older of them.
	rm -f "$DEST/$name-"*.alpmz
	cp -f "$found" "$DEST/"
	copied=$((copied + 1))
	ok "$(basename "$found")"
done

if [ -n "$missing" ]; then
	echo "publish-fix.sh: not built yet:$missing" >&2
	echo "  build them first, or correct the version in $SRC" >&2
	exit 1
fi

step "writing the manifest"
cp -f "$SRC" "$DEST/FIXES"
ok "$(awk -F'	' '$1 !~ /^#/ && NF >= 5' "$DEST/FIXES" | wc -l | tr -d ' ') fixes"

step "indexing fix"
sh "$TREE/alpm/alpm-repo" gen "$B/repo/fix" "$ARCH" >/dev/null
ok "$copied packages in fix"

printf '\napply on an installed system with:  alpm system fix\n'
