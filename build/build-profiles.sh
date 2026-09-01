#!/bin/sh
# Build the profile packages into repo/profile.
set -u
[ "${SCRAPLINUX_SANDBOX:-0}" = "1" ] || { echo "run through scraplinux-sandbox" >&2; exit 1; }
B=/home/apiwo/scraplinux-build
TREE=/home/apiwo/scraplinux
# Same fix as build-batch.sh: $TREE/ports is an empty leftover from before
# the ports tree moved into its own scraplinux-ports repo.
PORTS=${SCRAPLINUX_PORTS:-/home/apiwo/scraplinux-build/arctic-build/src-extra/arctic-linux-ports/ALL}
export SCRAPS_CACHE="$B/profile-cache"
export SCRAPS_BUILDROOT="$B/profile-build"
export SCRAPS_COLOR=never
mkdir -p "$B/repo/profile/x86_64"

ok=0; bad=0
for d in "$PORTS"/profile/*/; do
	[ -f "$d/recipe" ] || continue
	n=$(basename "$d")
	if sh "$TREE/scraps/scraps-build" "$d/recipe" >"$B/logs/profile-$n.log" 2>&1; then
		f=$(ls -t "$SCRAPS_BUILDROOT/out/$n"-*.spz 2>/dev/null | head -1)
		if [ -n "$f" ]; then
			cp -f "$f" "$B/repo/profile/x86_64/"
			printf '   ok   %s\n' "$(basename "$f")"; ok=$((ok+1))
		else
			printf '   FAIL %s (no package produced)\n' "$n"; bad=$((bad+1))
		fi
	else
		printf '   FAIL %s (see logs/profile-%s.log)\n' "$n" "$n"; bad=$((bad+1))
	fi
done
sh "$TREE/scraps/scraps-repo" gen "$B/repo/profile" x86_64 >/dev/null 2>&1
printf '\n   %s built, %s failed\n' "$ok" "$bad"
