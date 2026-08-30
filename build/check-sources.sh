#!/bin/sh
# Check that every source URL in the manifest actually resolves.
#
# The manifest was written from knowledge of what these projects release, so some
# versions are guesses. This finds the wrong ones before a build wastes time on a
# 404, and the report tells us which recipes are worth trying.
set -u
PORTS=/home/apiwo/scraplinux/ports
OUT=/home/apiwo/scraplinux-build/logs/sources
mkdir -p "$OUT"; : >"$OUT/ok"; : >"$OUT/bad"; : >"$OUT/skip"

# One package per line: repo name ver url
grep -v '^#' "$PORTS/manifest.tsv" | while IFS='	' read -r repo name ver bs lic deps mdeps url src desc; do
	[ -n "$name" ] || continue
	if [ "$src" = "-" ] || [ -z "$src" ]; then
		printf '%s\t%s\tmeta\n' "$repo" "$name" >>"$OUT/skip"; continue
	fi
	first=$(printf '%s' "$src" | tr ' ' '\n' | head -1)
	case "$first" in *::*) u=${first#*::} ;; *) u=$first ;; esac
	u=$(printf '%s' "$u" | sed "s/{version}/$ver/g; s/{V_}/$(printf '%s' "$ver" | tr . _)/g")
	case "$u" in
	git+*) printf '%s\t%s\t%s\tgit\n' "$repo" "$name" "$u" >>"$OUT/skip"; continue ;;
	esac
	printf '%s\t%s\t%s\t%s\n' "$repo" "$name" "$ver" "$u"
done >"$OUT/todo"

probe() {
	repo=$1 name=$2 ver=$3 u=$4
	code=$(curl -sIL --max-time 25 -o /dev/null -w '%{http_code}' "$u" 2>/dev/null)
	case "$code" in
	200|206) ;;
	*) code=$(curl -sL --max-time 25 -r 0-0 -o /dev/null -w '%{http_code}' "$u" 2>/dev/null) ;;
	esac
	case "$code" in
	200|206) printf '%s\t%s\t%s\n' "$repo" "$name" "$ver" >>"$OUT/ok" ;;
	*)       printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$name" "$ver" "$code" "$u" >>"$OUT/bad" ;;
	esac
}

export OUT
# 24 at a time; these are all tiny HEAD requests.
awk -F'\t' '{print}' "$OUT/todo" | xargs -P 24 -I{} sh -c '
	IFS="	"; set -- {}
	OUT=/home/apiwo/scraplinux-build/logs/sources
	u=$4
	code=$(curl -sIL --max-time 25 -o /dev/null -w "%{http_code}" "$u" 2>/dev/null)
	case "$code" in 200|206) ;; *) code=$(curl -sL --max-time 25 -r 0-0 -o /dev/null -w "%{http_code}" "$u" 2>/dev/null) ;; esac
	case "$code" in
	200|206) printf "%s\t%s\t%s\n" "$1" "$2" "$3" >>"$OUT/ok" ;;
	*)       printf "%s\t%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "$code" "$u" >>"$OUT/bad" ;;
	esac
'
printf '\nreachable:   %s\n' "$(wc -l <"$OUT/ok" | tr -d ' ')"
printf 'unreachable: %s\n' "$(wc -l <"$OUT/bad" | tr -d ' ')"
printf 'skipped:     %s (meta and git sources)\n' "$(wc -l <"$OUT/skip" | tr -d ' ')"
