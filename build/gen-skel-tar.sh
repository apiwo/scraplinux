#!/bin/sh
# gen-skel-tar.sh - regenerate the frozen skel.tar/branding.tar that
# scraplinux-base packages, from the actual current skel/ and branding/ trees.
#
# scraplinux-base does not build these from the live source tree - it can't:
# a real `scraps add -s scraplinux-base` on someone else's machine only has the
# recipe and its declared source= files, never this whole monorepo. So
# skel.tar/branding.tar are real, committed source archives that travel
# with the recipe - and that means they go stale the moment skel/ changes
# and nobody remembers to run this. Every skel/ fix in this cycle (the
# rc.boot coldplug fix, the removed live-image wifi-connect greeting)
# never reached a single real install, only the live ISO, because scraplinux-
# base's own skel.tar predated all of them. Run this before every release,
# not just when someone notices.
set -eu

TREE=${SCRAPLINUX_TREE:-/home/apiwo/scraplinux}
# $TREE/ports is an empty leftover from before the ports tree moved into
# its own scraplinux-ports repo - point at where it actually lives now.
PORTS=${SCRAPLINUX_PORTS:-/home/apiwo/scraplinux-build/arctic-build/src-extra/arctic-linux-ports/ALL}
DEST=${1:-$PORTS/main/scraplinux-base}

mkdir -p "$DEST"
( cd "$TREE/skel" && tar -cf "$DEST/skel.tar" . )
( cd "$TREE/branding" && tar --exclude=gen-branding.py --exclude=scraplinux-logo-master.png \
	-cf "$DEST/branding.tar" . )

echo "wrote $DEST/skel.tar $(wc -c <"$DEST/skel.tar") bytes"
echo "wrote $DEST/branding.tar $(wc -c <"$DEST/branding.tar") bytes"
