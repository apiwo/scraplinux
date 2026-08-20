#!/bin/sh
# publish-ports.sh - copy the ports tree into the ports-arctic checkout and
# regenerate its directory listings.
#
#   build/publish-ports.sh [checkout]   default /home/apiwo/arctic-build/src-extra/arctic-linux-ports
#
# Recipes only, and every recipe: this host is the one place a source build
# ever fetches from (alpm's ALPM_PORTS), and the binary mirror carries no
# recipes at all. The layout it serves is ALL/<repo>/<name>/recipe, which is
# what alpm's ports_repo_of() looks a package up in manifest.tsv to build.
# shellcheck shell=sh disable=SC2039

set -eu

B=${ARCTIC_BUILD:-/home/apiwo/arctic-build}
TREE=${ARCTIC_TREE:-/home/apiwo/arctic}
SITE=${1:-$B/src-extra/arctic-linux-ports}

REPOS="main extra base kernels profile nonfree alt-nonfree multilib"

[ -d "$SITE/ALL" ] || { echo "publish-ports: no checkout at $SITE" >&2; exit 1; }

step() { printf '\n:: %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

step "regenerating recipes from the manifest"
python3 "$TREE/ports/gen-ports.py" >/dev/null
note "$(grep -vc '^#' "$TREE/ports/manifest.tsv") packages in the manifest"

step "syncing the ports tree"
cp -f "$TREE/ports/manifest.tsv" "$SITE/ALL/manifest.tsv"
cp -f "$TREE/ports/gen-ports.py" "$SITE/ALL/gen-ports.py"
for r in $REPOS; do
	src="$TREE/ports/$r"
	dst="$SITE/ALL/$r"
	if [ ! -d "$src" ]; then
		# A category that no longer exists in the manifest must not stay
		# served: a recipe nothing can build is a trap, not an archive.
		[ -d "$dst" ] && { rm -rf "$dst"; note "dropped ALL/$r"; }
		continue
	fi
	mkdir -p "$dst"
	for d in "$dst"/*/; do
		[ -d "$d" ] || continue
		p=$(basename "$d")
		[ -d "$src/$p" ] || { rm -rf "$d"; note "$r: withdrew $p"; }
	done
	n=0
	for d in "$src"/*/; do
		[ -f "$d/recipe" ] || continue
		p=$(basename "$d")
		mkdir -p "$dst/$p"
		# The whole directory, not a fixed filename list: a recipe's
		# local (non-URL) source= entries can be anything - busybox's
		# arctic.config and busybox.conf, genfstab's own script, a
		# profile package's session.sh. A named whitelist here missed
		# every one of those, so `alpm add -s <pkg>` on any recipe with
		# a local source file downloaded the recipe fine and then died
		# with "local source missing" against the real published host,
		# while working the whole time against a local checkout that
		# still had the file sitting right there. index.html is the one
		# thing excluded - the listing step below writes its own.
		for f in "$d"*; do
			[ -f "$f" ] || continue
			bn=$(basename "$f")
			[ "$bn" = index.html ] && continue
			cp -f "$f" "$dst/$p/$bn"
		done
		n=$((n+1))
	done
	printf '   %-12s %s recipe(s)\n' "$r" "$n"
done

# Also drop any category the site still serves that this build knows nothing
# about at all - the musl and source areas were exactly that.
for d in "$SITE/ALL"/*/; do
	[ -d "$d" ] || continue
	n=$(basename "$d")
	case " $REPOS " in *" $n "*) continue ;; esac
	rm -rf "$d"; note "dropped ALL/$n"
done

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
    <a href="https://arctic-linux.apiwow.net">main page</a>
    <a href="https://pkg-arctic.apiwow.net">pkg</a>
    <a href="https://ports-arctic.apiwow.net">ports</a>
    <a href="https://arctic-docs.apiwow.net">docs</a>
    <a href="https://arctic-releases.apiwow.net">releases</a>
    <a href="https://github.com/apiwo/arctic-linux">github</a>
    <a href="https://codeberg.org/apiwo/arctic-linux">codeberg</a>
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

# The landing page's category list is generated from the categories that
# actually exist. Hand-maintained, it drifted: it still offered a musl area
# long after musl was removed - a dead link on the front page - and an
# "everything" entry that was just /ALL/ under another name.
step "updating the landing page"
if [ -f "$SITE/index.html" ]; then
	{
		for r in $REPOS; do
			[ -d "$SITE/ALL/$r" ] || continue
			printf '        <li><a href="/ALL/%s/">%s</a></li>\n' "$r" "$r"
		done
		printf '        <li><a href="/ALL/">browse all</a></li>\n'
	} >"$SITE/.repolist"
	awk -v list="$SITE/.repolist" '
		/<p>Repos<\/p>/ { print; inlist=1; next }
		inlist && /<ul>/  { print; while ((getline l < list) > 0) print l; skip=1; next }
		skip && /<\/ul>/  { print; skip=0; inlist=0; next }
		skip { next }
		{ print }
	' "$SITE/index.html" >"$SITE/index.html.new" && mv -f "$SITE/index.html.new" "$SITE/index.html"
	rm -f "$SITE/.repolist"
	note "front page lists $(printf '%s' "$REPOS" | wc -w) categories"
fi

step "writing directory listings"
listing "$SITE/ALL" "arctic-linux/ALL/"
for r in $REPOS; do
	[ -d "$SITE/ALL/$r" ] || continue
	listing "$SITE/ALL/$r" "arctic-linux/ALL/$r/"
	for d in "$SITE/ALL/$r"/*/; do
		[ -d "$d" ] || continue
		listing "${d%/}" "arctic-linux/ALL/$r/$(basename "$d")/"
	done
done
note "listings written"

step "done"
printf '   review with: git -C %s status\n' "$SITE"
