#!/bin/sh
# publish-pkgs.sh - copy the built binary repositories into the pkg-scraplinux
# checkout, reindex them, and regenerate the directory listings.
#
#   build/publish-pkgs.sh [checkout]     default /home/apiwo/scraplinux-build/src-extra/scraplinux-pkgs
#
# The site is a plain static tree: ALL/<repo>/<arch>/<pkg>.spz plus an
# INDEX scraps fetches, and an index.html per directory because GitHub Pages
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

B=${SCRAPLINUX_BUILD:-/home/apiwo/scraplinux-build}
TREE=${SCRAPLINUX_TREE:-/home/apiwo/scraplinux}
SITE=${1:-$B/src-extra/scraplinux-pkgs}
ARCH=x86_64

# The binding constraint here is not GitHub's raw 100 MiB push limit - this
# repo is also deployed as a Cloudflare Pages site, and Pages refuses the
# whole deploy if a single asset is 25 MiB or more ("Error: Pages only
# supports files up to 25 MiB in size"). A file under 100 MiB pushes to git
# fine and then breaks every deploy after it, silently: the site keeps
# serving whatever it last deployed successfully while looking like nothing
# is wrong. Use Pages' limit (in MiB, not the decimal-MB "25000000" an
# earlier version of this used - that was tight enough to also exclude
# glibc's real ~24.3 MiB package for no reason), with a little headroom
# under the exact boundary.
MAXSIZE=$((25*1024*1024))

REPOS="main extra base kernels profile nonfree alt-nonfree multilib fix"

# The index is signed when the publishing machine holds the key. It is not in
# any repository and never will be - see skel/etc/scraps/keys/README. Publishing
# without it is allowed, because a mirror can be rebuilt on a machine that has
# no business holding the key, but it says so rather than quietly shipping an
# index nobody can check.
SCRAPS_SIGN_KEY=${SCRAPS_SIGN_KEY:-/home/apiwo/scraplinux-keys/scraplinux-pkg.sec}
if [ -f "$SCRAPS_SIGN_KEY" ]; then
	export SCRAPS_SIGN_KEY
else
	echo "$(basename "$0"): no signing key at $SCRAPS_SIGN_KEY - indexes will be unsigned" >&2
	unset SCRAPS_SIGN_KEY
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
	# withdrawn package does not linger on the mirror. Also remove ones that
	# are still in the build repo but now too large: the copy loop below
	# only ever skips *copying* an oversized file, so a package that was
	# small enough to publish once and then grew past MAXSIZE (or was
	# published before MAXSIZE existed at all - this is exactly how two
	# ~90-99 MiB kernel packages ended up committed and broke every
	# Cloudflare Pages deploy afterward, silently, since nothing here ever
	# went back and removed them) would otherwise sit in the tree forever.
	for f in "$dst"/*.spz; do
		[ -f "$f" ] || continue
		b=$(basename "$f")
		if [ ! -f "$src/$b" ]; then
			rm -f "$f"; note "$r: withdrew $b"
		elif [ "$(wc -c <"$f")" -ge "$MAXSIZE" ]; then
			rm -f "$f"; note "$r: withdrew $b (now over the size limit)"
		fi
	done
	n=0; big=0
	for f in "$src"/*.spz; do
		[ -f "$f" ] || continue
		sz=$(wc -c <"$f")
		if [ "$sz" -ge "$MAXSIZE" ]; then
			big=$((big+1))
			note "$r: $(basename "$f") is too large for the mirror ($((sz/1048576)) MiB) - skipped"
			continue
		fi
		# A published name-version-release is a promise about specific bytes.
		# Rebuilding one and pushing it under the same name breaks every
		# client holding the older index: it fetches the new package, checks
		# it against the old checksum and refuses to install it - which is
		# exactly how an install died halfway through the base system after
		# scraps was rebuilt twice as 1.2.5-1. Bump the release instead.
		# SCRAPLINUX_REPUBLISH=yes is for a mirror being rebuilt from scratch,
		# where nothing has been handed out yet.
		if [ -f "$dst/$(basename "$f")" ] && ! cmp -s "$f" "$dst/$(basename "$f")"; then
			if [ "${SCRAPLINUX_REPUBLISH:-no}" != yes ]; then
				echo "publish-pkgs.sh: $(basename "$f") has already been published with different contents." >&2
				echo "  A release is what a client's index refers to; changing what it points at" >&2
				echo "  makes every stale index fatal. Bump the release and build again, or set" >&2
				echo "  SCRAPLINUX_REPUBLISH=yes if this mirror has never been handed out." >&2
				exit 1
			fi
			note "$r: republished $(basename "$f") with different contents"
		fi
		cmp -s "$f" "$dst/$(basename "$f")" 2>/dev/null || cp -f "$f" "$dst/"
		n=$((n+1))
	done
	# The fix repository carries one file that is not a package and not an
	# index: without FIXES beside them, its .spz files are just two ordinary
	# packages and "scraps system fix" has nothing to read.
	if [ -f "$src/FIXES" ]; then
		cmp -s "$src/FIXES" "$dst/FIXES" 2>/dev/null || cp -f "$src/FIXES" "$dst/"
	fi
	printf '   %-12s %s package(s)%s\n' "$r" "$n" \
		"$( [ "$big" -gt 0 ] && printf ', %s skipped' "$big" )"
done

step "reindexing"
for r in $REPOS; do
	d="$SITE/ALL/$r"
	if ls "$d/$ARCH"/*.spz >/dev/null 2>&1; then
		sh "$TREE/scraps/scraps-repo" gen "$d" "$ARCH" >/dev/null
		printf '   %-12s %s package(s) indexed\n' "$r" "$(grep -vc '^#' "$d/$ARCH/INDEX")"
	else
		{
			printf '# ScrapLinux %s repository index\n' "$r"
			printf '# format\t2\n# generated\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
			printf '# fields\tname version release arch dlsize isize sha256 deps desc\n'
		} >"$d/$ARCH/INDEX"
		sha256sum "$d/$ARCH/INDEX" | cut -d' ' -f1 >"$d/$ARCH/INDEX.sha256"
		# An empty repository is still a repository, and it was the only
		# kind shipping an index nobody could check - which is exactly what
		# a machine with sig = required would refuse.
		if [ -n "${SCRAPS_SIGN_KEY:-}" ]; then
			rm -f "$d/$ARCH/INDEX.sig"
			signify -S -s "$SCRAPS_SIGN_KEY" -m "$d/$ARCH/INDEX" \
				-x "$d/$ARCH/INDEX.sig" >/dev/null
		fi
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
  <a href="https://scraplinux.apiwow.net">main</a>
  <a href="https://scraplinux-docs.apiwow.net">docs</a>
  <a href="https://pkg-scraplinux.apiwow.net">packages</a>
  <a href="https://ports-scraplinux.apiwow.net">ports</a>
  <a href="https://scraplinux-releases.apiwow.net">releases</a>
  <a href="https://github.com/apiwo/scraplinux">github</a>
  <a href="https://codeberg.org/apiwo/scraplinux">codeberg</a>
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
    <p>ScrapLinux — <a href="https://github.com/apiwo/scraplinux">source on GitHub</a></p>
  </footer>
</div>
</body>
</html>
EOF
	} >"$dir/index.html"
}

step "writing directory listings"
listing "$SITE/ALL" "scraplinux/ALL/"
for r in $REPOS $BIGREPO; do
	[ -d "$SITE/ALL/$r" ] || continue
	listing "$SITE/ALL/$r" "scraplinux/ALL/$r/"
	[ -d "$SITE/ALL/$r/$ARCH" ] && listing "$SITE/ALL/$r/$ARCH" "scraplinux/ALL/$r/$ARCH/"
done
note "listings written"

step "done"
printf '   %s\n' "$(du -sh "$SITE/ALL" | cut -f1) in $SITE/ALL"
printf '   review with: git -C %s status\n' "$SITE"
