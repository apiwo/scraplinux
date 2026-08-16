#!/bin/sh
# publish-pkgs.sh - copy the built binary repositories into the pkg-arctic
# checkout, reindex them, and regenerate the directory listings.
#
#   build/publish-pkgs.sh [checkout]     default /home/apiwo/arctic-build/src-extra/arctic-linux-pkgs
#
# The site is a plain static tree: ALL/<repo>/<arch>/<pkg>.alpmz plus an
# INDEX alpm fetches, and an index.html per directory because GitHub Pages
# does not generate listings of its own. Both are written from what is
# actually in the tree, never from a list kept somewhere else - a repository
# advertising a package it does not host is worse than not advertising it,
# because it resolves and then 404s halfway through an install.
#
# Binaries only. Recipes live in the ports tree, on its own host, and this
# script will not create a source area here whatever is lying around in the
# build repo.
# shellcheck shell=sh disable=SC2039

set -eu

B=${ARCTIC_BUILD:-/home/apiwo/arctic-build}
TREE=${ARCTIC_TREE:-/home/apiwo/arctic}
SITE=${1:-$B/src-extra/arctic-linux-pkgs}
ARCH=x86_64

# GitHub rejects any file of 100 MiB or more. Rather than pushing a tree that
# will be refused, skip those here - and because the INDEX is generated from
# the files that actually landed, the result stays honest about what can be
# downloaded.
MAXSIZE=104857600

REPOS="main extra base kernels profile nonfree alt-nonfree multilib fix"

# The index is signed when the publishing machine holds the key. It is not in
# any repository and never will be - see skel/etc/alpm/keys/README. Publishing
# without it is allowed, because a mirror can be rebuilt on a machine that has
# no business holding the key, but it says so rather than quietly shipping an
# index nobody can check.
ALPM_SIGN_KEY=${ALPM_SIGN_KEY:-/home/apiwo/arctic-keys/arctic-pkg.sec}
if [ -f "$ALPM_SIGN_KEY" ]; then
	export ALPM_SIGN_KEY
else
	echo "$(basename "$0"): no signing key at $ALPM_SIGN_KEY - indexes will be unsigned" >&2
	unset ALPM_SIGN_KEY
fi


# The large-package repository is not synced or reindexed here. Its packages
# are release assets, published by publish-big.sh, and its index describes
# files that are deliberately not in this tree - regenerating it from an empty
# directory would replace a correct index with an empty one. It is listed
# below so the directory listing still shows it.
BIGREPO=big

[ -d "$SITE/ALL" ] || { echo "publish-pkgs: no checkout at $SITE" >&2; exit 1; }

step() { printf '\n:: %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

# Anything that is not a binary repository has no business on this host.
step "removing non-binary areas"
for dead in source musl; do
	if [ -d "$SITE/ALL/$dead" ]; then
		rm -rf "$SITE/ALL/$dead"
		note "dropped ALL/$dead"
	fi
done

step "syncing packages"
for r in $REPOS; do
	src="$B/repo/$r/$ARCH"
	dst="$SITE/ALL/$r/$ARCH"
	mkdir -p "$dst"
	# Remove packages that are no longer in the build repo, so a renamed or
	# withdrawn package does not linger on the mirror.
	for f in "$dst"/*.alpmz; do
		[ -f "$f" ] || continue
		[ -f "$src/$(basename "$f")" ] || { rm -f "$f"; note "$r: withdrew $(basename "$f")"; }
	done
	n=0; big=0
	for f in "$src"/*.alpmz; do
		[ -f "$f" ] || continue
		sz=$(wc -c <"$f")
		if [ "$sz" -ge "$MAXSIZE" ]; then
			big=$((big+1))
			note "$r: $(basename "$f") is too large for the mirror ($((sz/1048576)) MiB) - skipped"
			continue
		fi
		cmp -s "$f" "$dst/$(basename "$f")" 2>/dev/null || cp -f "$f" "$dst/"
		n=$((n+1))
	done
	# The fix repository carries one file that is not a package and not an
	# index: without FIXES beside them, its .alpmz files are just two ordinary
	# packages and "alpm system fix" has nothing to read.
	if [ -f "$src/FIXES" ]; then
		cmp -s "$src/FIXES" "$dst/FIXES" 2>/dev/null || cp -f "$src/FIXES" "$dst/"
	fi
	printf '   %-12s %s package(s)%s\n' "$r" "$n" \
		"$( [ "$big" -gt 0 ] && printf ', %s skipped' "$big" )"
done

step "reindexing"
for r in $REPOS; do
	d="$SITE/ALL/$r"
	if ls "$d/$ARCH"/*.alpmz >/dev/null 2>&1; then
		sh "$TREE/alpm/alpm-repo" gen "$d" "$ARCH" >/dev/null
		printf '   %-12s %s package(s) indexed\n' "$r" "$(grep -vc '^#' "$d/$ARCH/INDEX")"
	else
		{
			printf '# Arctic Linux %s repository index\n' "$r"
			printf '# format\t2\n# generated\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
			printf '# fields\tname version release arch dlsize isize sha256 deps desc\n'
		} >"$d/$ARCH/INDEX"
		sha256sum "$d/$ARCH/INDEX" | cut -d' ' -f1 >"$d/$ARCH/INDEX.sha256"
		printf '   %-12s empty\n' "$r"
	fi
done

# ---------------------------------------------------------------- listings
# One index.html per directory, listing what is in it. Written from the
# directory itself for the same reason the INDEX is.
human() {
	b=$1
	if   [ "$b" -ge 1048576 ]; then printf '%s.%s MiB' $((b/1048576)) $(( (b%1048576)*10/1048576 ))
	elif [ "$b" -ge 1024 ];    then printf '%s KiB' $((b/1024))
	else printf '%s B' "$b"; fi
}

listing() {
	dir=$1 title=$2
	{
		cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<link rel="stylesheet" href="/style.css">
</head>
<body>
<nav class="topbar">
  <div class="wrap" style="padding:0;">
    <a href="/">arctic-linux</a>
    <a href="/ALL/">packages</a>
    <a href="https://ports-arctic.apiwow.net">ports</a>
    <a href="https://arctic-docs.apiwow.net">docs</a>
    <a href="https://github.com/apiwo/arctic-linux">github</a>
  </div>
</nav>
<div class="wrap">
  <header class="hero" style="padding:28px 0 8px;">
    <h1 style="font-size:28px;">$title</h1>
  </header>
  <section>
    <table class="listing">
      <tr><th>name</th><th>size</th></tr>
      <tr><td><a href="../">../</a></td><td></td></tr>
EOF
		for e in "$dir"/*; do
			[ -e "$e" ] || continue
			n=$(basename "$e")
			[ "$n" = "index.html" ] && continue
			if [ -d "$e" ]; then
				printf '      <tr><td><a href="%s/">%s/</a></td><td></td></tr>\n' "$n" "$n"
			else
				printf '      <tr><td><a href="%s">%s</a></td><td>%s</td></tr>\n' \
					"$n" "$n" "$(human "$(wc -c <"$e")")"
			fi
		done
		cat <<EOF
    </table>
  </section>
  <footer>
    <p>Arctic Linux — <a href="https://github.com/apiwo/arctic-linux">source on GitHub</a></p>
  </footer>
</div>
</body>
</html>
EOF
	} >"$dir/index.html"
}

step "writing directory listings"
listing "$SITE/ALL" "arctic-linux/ALL/"
for r in $REPOS $BIGREPO; do
	[ -d "$SITE/ALL/$r" ] || continue
	listing "$SITE/ALL/$r" "arctic-linux/ALL/$r/"
	[ -d "$SITE/ALL/$r/$ARCH" ] && listing "$SITE/ALL/$r/$ARCH" "arctic-linux/ALL/$r/$ARCH/"
done
note "listings written"

step "done"
printf '   %s\n' "$(du -sh "$SITE/ALL" | cut -f1) in $SITE/ALL"
printf '   review with: git -C %s status\n' "$SITE"
