#!/bin/sh
# publish-big.sh - publish the packages that are too large for the git mirror.
#
#   build/publish-big.sh            (needs gh, and network; not sandboxed)
#
# A mirror served out of a git host has a ceiling: GitHub refuses any file
# over 100 MB. The packages that cross it are not the optional ones - the
# kernel is at 95 MB and climbing, linux-firmware is 169 MB, a packaged LLVM
# is larger still - and publish-pkgs.sh was quietly skipping them, so a
# machine could not install firmware or a compiler at all and nothing said
# why.
#
# Release assets have the room and no directory structure: everything lives
# flat under one tag. So the packages go there, their index stays in the git
# tree where it is small, and the repository definition points the two apart
# with "pkgurl". alpm fetches the index from one place and the packages from
# the other.
set -eu

B=${ARCTIC_BUILD:-/home/apiwo/arctic-build}
TREE=${ARCTIC_TREE:-/home/apiwo/arctic}
SITE=${1:-$B/src-extra/arctic-linux-pkgs}
ARCH=x86_64
REPO_SLUG=apiwo/arctic-linux-pkgs
TAG=pkgs-$ARCH
MINSIZE=104857600          # the same ceiling publish-pkgs.sh refuses to cross
STAGE=$B/.bigstage/$ARCH

command -v gh >/dev/null 2>&1 || { echo "publish-big.sh: needs the gh CLI" >&2; exit 1; }

step() { printf '\n:: %s\n' "$*"; }
ok()   { printf '   ok %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

step "collecting packages over $((MINSIZE / 1048576)) MiB"
rm -rf "$STAGE"; mkdir -p "$STAGE"
n=0
for f in "$B"/repo/*/"$ARCH"/*.alpmz; do
	[ -f "$f" ] || continue
	sz=$(wc -c <"$f")
	[ "$sz" -ge "$MINSIZE" ] || continue
	# A hard link, so the index is generated over the identical bytes that
	# get uploaded and the checksum in it cannot describe a different file.
	ln -f "$f" "$STAGE/$(basename "$f")" 2>/dev/null || cp -f "$f" "$STAGE/"
	note "$(basename "$f") ($((sz / 1048576)) MiB)"
	n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "   nothing that large; nothing to do"; exit 0; }

step "indexing"
sh "$TREE/alpm/alpm-repo" gen "$B/.bigstage" "$ARCH" >/dev/null
ok "$(grep -vc '^#' "$STAGE/INDEX") packages"

step "release $TAG"
if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
	ok "exists"
else
	gh release create "$TAG" --repo "$REPO_SLUG" \
		--title "Binary packages ($ARCH)" \
		--notes "Packages too large for the git mirror: the kernel, firmware and the toolchain. Fetched by alpm through the 'big' repository; not meant to be downloaded by hand." \
		>/dev/null
	ok "created"
fi

step "uploading"
for f in "$STAGE"/*.alpmz; do
	[ -f "$f" ] || continue
	# --clobber: a rebuilt package keeps its name when only its contents
	# changed, and the asset has to follow it rather than the upload failing.
	gh release upload "$TAG" "$f" --repo "$REPO_SLUG" --clobber >/dev/null 2>&1 \
		&& ok "$(basename "$f")" \
		|| { echo "   failed: $(basename "$f")" >&2; exit 1; }
done

step "index into the site"
d=$SITE/ALL/big/$ARCH
mkdir -p "$d"
cp -f "$STAGE/INDEX" "$d/INDEX"
[ -f "$STAGE/INDEX.sha256" ] && cp -f "$STAGE/INDEX.sha256" "$d/INDEX.sha256"
ok "$d/INDEX"

printf '\npackages: https://github.com/%s/releases/download/%s/\n' "$REPO_SLUG" "$TAG"
printf 'commit and push %s to finish.\n' "$SITE"
