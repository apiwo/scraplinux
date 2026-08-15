#!/bin/sh
# mirror-codeberg.sh - push every Arctic repository to Codeberg as well as GitHub.
#
#   build/mirror-codeberg.sh              push them all
#   build/mirror-codeberg.sh arctic-docs  push one
#
# Everything Arctic lives in two places: github.com/apiwo/<name> and
# codeberg.org/apiwo/<name>. GitHub stays the working remote; Codeberg is
# pushed the same commits so the project does not live on one host's
# goodwill.
#
# Codeberg has push-to-create disabled ("Push to create is not enabled for
# users"), so a repository has to exist there before its first push - create
# it empty, with no README or licence, or the first push is rejected as a
# non-fast-forward.
# shellcheck shell=sh disable=SC2039

set -u

B=${ARCTIC_BUILD:-/home/apiwo/arctic-build}
TREE=${ARCTIC_TREE:-/home/apiwo/arctic}

# Set CODEBERG_KEY to an ssh private key if the one ssh would pick on its own
# is not the right one - running this as root is the usual reason, since ~ then
# resolves to /root and any per-user ssh config is not read. Left unset, ssh
# uses its normal agent and config.
if [ -n "${CODEBERG_KEY:-}" ]; then
	export GIT_SSH_COMMAND="ssh -i $CODEBERG_KEY -o IdentitiesOnly=yes -o BatchMode=yes"
fi

# repo-name:checkout
REPOS="arctic-linux:$TREE
arctic-kernel:$B/src-extra/arctic-kernel
arctic-docs:$B/src-extra/arctic-docs
arctic-linux-site:$B/src-extra/arctic-linux-site
arctic-linux-pkgs:$B/src-extra/arctic-linux-pkgs
arctic-linux-ports:$B/src-extra/arctic-linux-ports"

only=${1:-}
fail=0

for entry in $REPOS; do
	name=${entry%%:*}
	dir=${entry#*:}
	[ -n "$only" ] && [ "$only" != "$name" ] && continue
	printf '\n:: %s\n' "$name"
	if [ ! -d "$dir/.git" ]; then
		printf '   no checkout at %s - skipped\n' "$dir"
		continue
	fi
	url="git@codeberg.org:apiwo/$name.git"
	if ! git -C "$dir" remote get-url codeberg >/dev/null 2>&1; then
		git -C "$dir" remote add codeberg "$url"
		printf '   added codeberg remote\n'
	fi
	branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo main)
	if git -C "$dir" push codeberg "HEAD:$branch" 2>&1 | sed 's/^/   /'; then
		:
	else
		fail=$((fail+1))
	fi
done

printf '\n'
if [ "$fail" = 0 ]; then
	printf 'mirrored to codeberg.\n'
else
	printf '%s repository(s) failed - if the message was "Push to create is not\n' "$fail"
	printf 'enabled", create the repository on Codeberg first and run this again.\n'
	exit 1
fi
