#!/bin/sh
# check-sources.sh - probe every recipe's first source url
set -u
PORTS=${SCRAPLINUX_PORTS:-/home/apiwo/scraplinux-build/arctic-build/src-extra/arctic-linux-ports/ALL}
OUT=${SCRAPLINUX_BUILD:-/home/apiwo/scraplinux-build}/logs/sources
mkdir -p "$OUT"; : >"$OUT/ok"; : >"$OUT/bad"; : >"$OUT/skip"

for r in "$PORTS"/*/*/recipe; do
	# subshell so one recipe's vars never leak into the next
	(
		source="" version=""
		. "$r" 2>/dev/null
		repo=$(basename "$(dirname "$(dirname "$r")")")
		first=$(printf '%s' "$source" | tr ' ' '\n' | sed -n '1p')
		case "$first" in *::*) first=${first#*::} ;; esac
		case "$first" in
		http://*|https://*|ftp://*) printf '%s\t%s\t%s\t%s\n' "$repo" "$name" "$version" "$first" ;;
		"") printf '%s\t%s\tno source\n' "$repo" "$name" >>"$OUT/skip" ;;
		*) printf '%s\t%s\tlocal or vcs source\n' "$repo" "$name" >>"$OUT/skip" ;;
		esac
	)
done >"$OUT/todo"

export OUT
xargs -P 24 -I{} sh -c '
	IFS="	"; set -- {}
	code=$(curl -sIL --max-time 25 -o /dev/null -w "%{http_code}" "$4" 2>/dev/null)
	case "$code" in 200|206) ;; *) code=$(curl -sL --max-time 25 -r 0-0 -o /dev/null -w "%{http_code}" "$4" 2>/dev/null) ;; esac
	case "$code" in
	200|206) printf "%s\t%s\t%s\n" "$1" "$2" "$3" >>"$OUT/ok" ;;
	*)       printf "%s\t%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "$code" "$4" >>"$OUT/bad" ;;
	esac
' <"$OUT/todo"

printf '\nreachable:   %s\n' "$(wc -l <"$OUT/ok" | tr -d ' ')"
printf 'unreachable: %s\n' "$(wc -l <"$OUT/bad" | tr -d ' ')"
printf 'skipped:     %s\n' "$(wc -l <"$OUT/skip" | tr -d ' ')"
