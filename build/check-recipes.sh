#!/bin/sh
# check-recipes.sh - read every recipe and refuse the mistakes that only show
# up hours into a build.
#
#   build/check-recipes.sh [recipe ...]     default: the whole ports tree
#
# A recipe is shell, and the expensive failures are not the ones the shell
# reports. mesa's meson line lost every option after a comment that had been
# put between two backslash-continued lines - the shell joined them, the `#`
# turned the rest of the command into a comment, and mesa quietly configured
# itself with the defaults instead. It configured, it built, and what came
# out was not what the recipe said. Nothing about that is a syntax error.
#
# Exit status is 1 if anything failed, so it can gate a publish.
# shellcheck shell=sh disable=SC2039

set -u

TREE=${ARCTIC_TREE:-/home/apiwo/arctic}
PORTS=$TREE/ports

if [ $# -gt 0 ]; then
	RECIPES=$*
else
	RECIPES=$(find "$PORTS" -mindepth 3 -maxdepth 3 -name recipe | sort)
fi

fail=0
checked=0

note() { printf '  %s\n' "$*"; }
bad()  { printf '%s: %s\n' "$1" "$2"; fail=$((fail + 1)); }

for r in $RECIPES; do
	[ -f "$r" ] || continue
	checked=$((checked + 1))
	rel=${r#"$PORTS"/}
	dir=$(dirname "$r")
	want=$(basename "$dir")

	# 1. It has to be valid shell before anything else is worth checking.
	if ! err=$(sh -n "$r" 2>&1); then
		bad "$rel" "will not parse: $(printf '%s' "$err" | head -1)"
		continue
	fi

	# 2. A comment on the line after a continued one. The shell removes the
	#    backslash-newline first, so the comment starts mid-command and eats
	#    everything to the end of the joined line - options, arguments, the
	#    lot. Silent, and the build usually still succeeds.
	if awk '
		prev ~ /\\$/ && $0 ~ /^[ \t]*#/ { print NR; found = 1 }
		{ prev = $0 }
		END { exit !found }
	' "$r" >/dev/null 2>&1; then
		lines=$(awk 'prev ~ /\\$/ && $0 ~ /^[ \t]*#/ { printf "%s ", NR } { prev = $0 }' "$r")
		bad "$rel" "comment inside a continued command (line(s): $lines) - it swallows the rest of the command"
	fi

	# 3. A continued line that continues into nothing: the last line of a
	#    command ends in a backslash and the next line is blank or closes the
	#    block, so the command runs with an argument missing.
	if awk '
		prev ~ /\\$/ && ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*}[ \t]*$/) { print NR; found = 1 }
		{ prev = $0 }
		END { exit !found }
	' "$r" >/dev/null 2>&1; then
		lines=$(awk 'prev ~ /\\$/ && ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*}[ \t]*$/) { printf "%s ", NR } { prev = $0 }' "$r")
		bad "$rel" "a continued line runs into nothing (line(s): $lines)"
	fi

	# 4. The fields a package cannot be built without.
	for f in name version release desc; do
		grep -q "^$f=" "$r" || bad "$rel" "no $f="
	done

	# 5. The name has to match the directory, or alpm installs a package
	#    under one name from a port everything else calls another.
	got=$(sed -n 's/^name=//p' "$r" | head -1 | tr -d '"')
	[ "$got" = "$want" ] || bad "$rel" "name=$got but the directory is $want"

	# 6. A source with no checksum field at all cannot be fetched.
	if grep -q '^source="' "$r" && ! grep -q '^sha256=' "$r"; then
		bad "$rel" "has source= but no sha256="
	fi

	# 7. A generated recipe with hand edits in it and no recipe.local beside
	#    it is a change waiting to be reverted by the next gen-ports run.
	if grep -q 'Generated from manifest.tsv' "$r" && [ ! -f "$dir/recipe.local" ]; then
		if grep -qE '^replaces=|^provides=' "$r" || grep -q 'rm -rf "\$pkgdir' "$r"; then
			bad "$rel" "hand-edited but has no recipe.local - gen-ports.py will revert it"
		fi
	fi
done

printf '\n%s recipe(s) checked, %s problem(s)\n' "$checked" "$fail"
[ "$fail" -eq 0 ]
