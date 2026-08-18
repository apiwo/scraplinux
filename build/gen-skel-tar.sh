#!/bin/sh
# gen-skel-tar.sh - regenerate the frozen skel.tar/branding.tar that
# arctic-base packages, from the actual current skel/ and branding/ trees.
#
# arctic-base does not build these from the live source tree - it can't:
# a real `alpm add -s arctic-base` on someone else's machine only has the
# recipe and its declared source= files, never this whole monorepo. So
# skel.tar/branding.tar are real, committed source archives that travel
# with the recipe - and that means they go stale the moment skel/ changes
# and nobody remembers to run this. Every skel/ fix in this cycle (the
# rc.boot coldplug fix, the removed live-image wifi-connect greeting)
# never reached a single real install, only the live ISO, because arctic-
# base's own skel.tar predated all of them. Run this before every release,
# not just when someone notices.
set -eu

TREE=${ARCTIC_TREE:-/home/apiwo/arctic}
DEST=${1:-$TREE/ports/main/arctic-base}

mkdir -p "$DEST"
( cd "$TREE/skel" && tar -cf "$DEST/skel.tar" . )
( cd "$TREE/branding" && tar --exclude=gen-branding.py --exclude=arctic-logo-master.png \
	-cf "$DEST/branding.tar" . )

echo "wrote $DEST/skel.tar $(wc -c <"$DEST/skel.tar") bytes"
echo "wrote $DEST/branding.tar $(wc -c <"$DEST/branding.tar") bytes"
