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
# with "pkgurl". scraps fetches the index from one place and the packages from
# the other.
set -eu

B=${SCRAPLINUX_BUILD:-/home/apiwo/scraplinux-build}
TREE=${SCRAPLINUX_TREE:-/home/apiwo/scraplinux}
SITE=${1:-$B/src-extra/scraplinux-pkgs}
ARCH=x86_64
REPO_SLUG=apiwo/scraplinux-pkgs
TAG=pkgs-$ARCH
MINSIZE=$((25*1024*1024))  # publish-pkgs.sh's own MAXSIZE (Cloudflare Pages'
                            # real per-asset ceiling, not GitHub's git-commit
                            # one) - this used to be 100 MiB, matching what
                            # publish-pkgs.sh's threshold *used* to be before
                            # it was corrected to the real Cloudflare limit.
                            # Left at the old value, anything from 25-100 MiB
                            # (rust's rustc+std package: 69 MiB) fell through
                            # both channels - too big for the git mirror,
                            # not big enough to trigger this one.
STAGE=$B/.bigstage/$ARCH

command -v gh >/dev/null 2>&1 || { echo "publish-big.sh: needs the gh CLI" >&2; exit 1; }

step() { printf '\n:: %s\n' "$*"; }

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

ok()   { printf '   ok %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

step "collecting packages over $((MINSIZE / 1048576)) MiB"
rm -rf "$STAGE"; mkdir -p "$STAGE"
n=0
for f in "$B"/repo/*/"$ARCH"/*.scrapsz; do
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
sh "$TREE/scraps/scraps-repo" gen "$B/.bigstage" "$ARCH" >/dev/null
ok "$(grep -vc '^#' "$STAGE/INDEX") packages"

step "release $TAG"
if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
	ok "exists"
else
	gh release create "$TAG" --repo "$REPO_SLUG" \
		--title "Binary packages ($ARCH)" \
		--notes "Packages too large for the git mirror: the kernel, firmware and the toolchain. Fetched by scraps through the 'big' repository; not meant to be downloaded by hand." \
		>/dev/null
	ok "created"
fi

step "uploading"
for f in "$STAGE"/*.scrapsz; do
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
# The signature belongs beside the index it signs. Left behind in the staging
# directory, this repository was the one scraps could not verify.
if [ -f "$STAGE/INDEX.sig" ]; then
	cp -f "$STAGE/INDEX.sig" "$d/INDEX.sig"
else
	rm -f "$d/INDEX.sig"
fi
ok "$d/INDEX"

printf '\npackages: https://github.com/%s/releases/download/%s/\n' "$REPO_SLUG" "$TAG"
printf 'commit and push %s to finish.\n' "$SITE"
