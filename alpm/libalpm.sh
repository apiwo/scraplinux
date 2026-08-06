#!/bin/sh
# libalpm.sh - shared runtime for the Arctic Linux Package Manager
# POSIX sh only. Must run under busybox ash with no GNU utilities present.
# shellcheck shell=sh disable=SC2039

ALPM_VERSION="1.0.0"
ALPM_FORMAT="2"

: "${ALPM_ROOT:=/}"
# ALPM_CONF/ALPM_REPOD stay host-absolute on purpose even under --root: they
# are the *tool's* configuration (which repos exist, how many jobs, color),
# read from wherever alpm itself is actually running - during a target_alpm
# install that is still the live session, since the target's own /etc/alpm
# may not even have anything in it yet. ALPM_DB/ALPM_CACHE/ALPM_LOG describe
# the state of a specific root's own filesystem instead (what is installed
# there, what is cached there), so they follow ALPM_ROOT by default. Getting
# this wrong meant `ALPM_ROOT=$TARGET alpm ins ...` recorded every install
# into the *caller's* /var/lib/alpm instead of the target's - the target
# filesystem would boot with a completely empty package database despite
# every file actually being there.
: "${ALPM_CONF:=/etc/alpm/alpm.conf}"
: "${ALPM_REPOD:=/etc/alpm/repos.d}"
: "${ALPM_DB:=${ALPM_ROOT%/}/var/lib/alpm}"
: "${ALPM_CACHE:=${ALPM_ROOT%/}/var/cache/alpm}"
: "${ALPM_LOG:=${ALPM_ROOT%/}/var/log/alpm.log}"
: "${ALPM_JOBS:=$(nproc 2>/dev/null || echo 1)}"

# ---------------------------------------------------------------- presentation

# Arctic palette, lifted from the logo gradient: violet -> ice -> teal.
if [ -t 1 ] && [ "${ALPM_COLOR:-auto}" != "never" ]; then
	C_R=$(printf '\033[0m')      ; C_B=$(printf '\033[1m')
	C_DIM=$(printf '\033[2m')    ; C_IT=$(printf '\033[3m')
	A_VIO=$(printf '\033[38;5;99m')  ; A_IND=$(printf '\033[38;5;69m')
	A_ICE=$(printf '\033[38;5;81m')  ; A_TEAL=$(printf '\033[38;5;44m')
	A_MINT=$(printf '\033[38;5;49m') ; A_SNOW=$(printf '\033[38;5;231m')
	A_GREY=$(printf '\033[38;5;245m'); A_RED=$(printf '\033[38;5;203m')
	A_AMB=$(printf '\033[38;5;215m')
else
	C_R= ; C_B= ; C_DIM= ; C_IT=
	A_VIO= ; A_IND= ; A_ICE= ; A_TEAL= ; A_MINT= ; A_SNOW= ; A_GREY= ; A_RED= ; A_AMB=
fi

msg()   { printf '%s::%s %s%s%s\n' "$A_TEAL$C_B" "$C_R$C_B" "$*" "$C_R" ""; }
msg2()  { printf '  %s->%s %s\n' "$A_ICE$C_B" "$C_R" "$*"; }
info()  { printf '  %s*%s  %s\n' "$A_IND" "$C_R" "$*"; }
warn()  { printf '%s::%s %s%s\n' "$A_AMB$C_B" "$C_B" "$*" "$C_R" >&2; }
# tux says what went wrong. Not a real cowsay bubble - some of these
# messages span several lines (a checksum mismatch prints three), which a
# fixed-width bubble does not degrade well for.
tux_say() {
	{
		printf '%s\n' "$*"
		cat <<'EOF'
   \
    \
        .--.
       |o_o |
       |:_/ |
      //   \ \
     (|     | )
    /'\_   _/`\
    \___)=(___/
EOF
	} >&2
}

err()   { tux_say "error: $*"; }
die()   { err "$*"; exit 1; }
ok()    { printf '  %sok%s  %s\n' "$A_MINT$C_B" "$C_R" "$*"; }

# Every privileged entry point funnels through here. The wording is deliberate:
# it never names a specific privilege tool.
need_root() {
	[ "$(id -u)" = "0" ] || die "Must be run as root."
}

alpm_log() {
	[ -w "$(dirname "$ALPM_LOG")" ] 2>/dev/null || return 0
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$ALPM_LOG" 2>/dev/null || :
}

# A progress bar that degrades gracefully on a dumb tty.
#
# Every local here is prefixed _bar_: this is POSIX sh with no real variable
# scoping, and the plain name "i" used to double as this function's own
# fill-loop counter *and* leak back into whatever loop variable the caller
# happened to also call "i" - which alpm's own package-fetch loop does
# ("for p in $todo; do i=$((i+1)); bar "$i" "$n" "$p"; ...; done"). bar()
# would run its drawing loop up to $width and leave the caller's "i" sitting
# there instead of at the package index, so the next call's percentage was
# computed from that leaked value - cur*100/tot growing to several thousand
# percent by the second or third package, and the stray '#'/'-' fill string
# growing long enough to wrap the whole screen with it.
bar() {
	_bar_cur=$1 _bar_tot=$2 _bar_label=$3
	[ -t 1 ] || return 0
	[ "$_bar_tot" -gt 0 ] 2>/dev/null || return 0
	_bar_width=$(( ${COLUMNS:-80} - 34 )); [ "$_bar_width" -lt 10 ] && _bar_width=10
	_bar_fill=$(( _bar_cur * _bar_width / _bar_tot ))
	_bar_pct=$(( _bar_cur * 100 / _bar_tot ))
	_bar_b=""; _bar_i=0
	while [ "$_bar_i" -lt "$_bar_fill" ]; do _bar_b="$_bar_b#"; _bar_i=$((_bar_i+1)); done
	while [ "$_bar_i" -lt "$_bar_width" ]; do _bar_b="$_bar_b-"; _bar_i=$((_bar_i+1)); done
	printf '\r  %s%-22.22s%s %s[%s]%s %3d%%' \
		"$A_SNOW" "$_bar_label" "$C_R" "$A_TEAL" "$_bar_b" "$C_R" "$_bar_pct"
	[ "$_bar_cur" -ge "$_bar_tot" ] && printf '\n'
}

# --------------------------------------------------------------------- helpers

have() { command -v "$1" >/dev/null 2>&1; }

# True on a musl root (a musl-edition install, or ALPM_ROOT pointed at one) -
# Arctic's own binary repo is always built against glibc regardless of which
# root alpm is pointed at, so a binary install there would just fail at
# runtime with an unresolvable dynamic linker.
is_musl_root() {
	[ -e "$ALPM_ROOT/lib/ld-musl-x86_64.so.1" ] && [ ! -e "$ALPM_ROOT/usr/lib/libc.so.6" ]
}

musl_binary_warning() {
	cat >&2 <<'EOF'
 _______________________________________
/ Musl libc can only use source pkgs on \
| Arctic. Binaries are compiled via     |
\ glibc.                                /
 ---------------------------------------
   \
    \
        .--.
       |o_o |
       |:_/ |
      //   \ \
     (|     | )
    /'\_   _/`\
    \___)=(___/
EOF
}

sha256() {
	if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
	elif have sha256; then sha256 -q "$1"
	elif have openssl; then openssl dgst -sha256 "$1" | sed 's/.*= //'
	else echo "nohash"; fi
}

# Downloader abstraction. Arctic ships busybox wget on the ISO and curl in base.
#
# file:// is handled here rather than passed to a downloader. The installation
# medium serves its repositories over file://, curl is not on the ISO, and
# busybox wget rejects the scheme outright ("not an http or ftp url") - so
# without this the offline install could never reach the packages sitting on the
# disc it booted from.
_dl_file() {
	src=${1#file://}
	[ -f "$src" ] || return 1
	mkdir -p "$(dirname "$2")"
	cp -f "$src" "$2" 2>/dev/null
}

dl() {
	url=$1 out=$2
	mkdir -p "$(dirname "$out")" 2>/dev/null || :
	case "$url" in
	file://*) _dl_file "$url" "$out"; return $? ;;
	esac
	if have curl; then
		curl -fL --retry 3 --retry-delay 2 -# -o "$out.part" "$url" || return 1
	elif have wget; then
		wget -q -O "$out.part" "$url" || return 1
	else
		err "no downloader available (need curl or wget)"; return 1
	fi
	mv "$out.part" "$out"
}

# Silent variant for index files.
dlq() {
	url=$1 out=$2
	mkdir -p "$(dirname "$out")" 2>/dev/null || :
	case "$url" in
	file://*) _dl_file "$url" "$out"; return $? ;;
	esac
	if have curl; then curl -fsSL -o "$out.part" "$url" || return 1
	elif have wget; then wget -q -O "$out.part" "$url" || return 1
	else return 1; fi
	mv "$out.part" "$out"
}

# .alpmz is a plain tar.xz, so bsdtar or busybox tar both work.
#
# Deliberately does not call fix_usrmerge itself: this also extracts a
# package into a bare staging directory before the file-conflict check and
# FILES list get computed from what is actually there (see alpm's own
# install path), and a package's real archive usually does not contain
# bin/sbin/lib/lib64 at all - it relies on the merged-/usr symlinks already
# existing on the real target from glibc/the base package. Fixing it up here
# would inject symlinks into the staging dir that were never part of this
# package's own content, get counted as this package's files, and collide
# with whichever package legitimately already owns them. fix_usrmerge only
# ever runs against the real $ALPM_ROOT, after everything has merged.
untar() {
	archive=$1 dest=$2
	mkdir -p "$dest"
	if have bsdtar; then bsdtar -xpf "$archive" -C "$dest"
	else tar -xpf "$archive" -C "$dest"; fi
}

# A package archive that contains a bare directory entry for bin/, sbin/,
# lib/, lib64/ or usr/sbin/ makes tar (GNU or bsdtar - neither extraction path
# above is immune) replace Arctic's merged-/usr symlink with a real directory
# instead of extracting into whatever it pointed at. GNU tar has
# --keep-directory-symlink for this; bsdtar has no equivalent flag at all
# (confirmed: it errors out if you pass that GNU-only flag to it, and its own
# default behaviour has the exact same bug). So this repairs it after the
# fact instead of trying to prevent it during extraction - same fixup
# build-rootfs.sh already does once for usr/sbin when it first lays out the
# rootfs, generalised to every merged path and run after every single
# package, since any one of them can retrigger it.
fix_usrmerge() {
	root=$1
	_um_fix() {
		p=$1 real=$2 tgt=$3
		if [ -d "$p" ] && [ ! -L "$p" ]; then
			for f in "$p"/* "$p"/.[!.]*; do
				[ -e "$f" ] || [ -L "$f" ] || continue
				mv -f "$f" "$real/" 2>/dev/null || :
			done
			rmdir "$p" 2>/dev/null || :
		fi
		[ -e "$p" ] || ln -sfn "$tgt" "$p"
	}
	[ -d "$root/usr/bin" ] || return 0
	[ -d "$root/usr/lib" ] && \
		_um_fix "$root/lib"     "$root/usr/lib" "usr/lib"
	[ -d "$root/usr/lib" ] && \
		_um_fix "$root/lib64"   "$root/usr/lib" "usr/lib"
	_um_fix "$root/bin"     "$root/usr/bin" "usr/bin"
	_um_fix "$root/sbin"    "$root/usr/bin" "usr/bin"
	_um_fix "$root/usr/sbin" "$root/usr/bin" "bin"
}

tarlist() {
	if have bsdtar; then bsdtar -tf "$1"; else tar -tf "$1"; fi
}

# ------------------------------------------------------------------- meta i/o

# Read one key out of a .PKGINFO-style key = value file.
meta() {
	local file key
	file=$1 key=$2
	[ -f "$file" ] || return 1
	sed -n "s/^[ 	]*$key[ 	]*=[ 	]*//p" "$file" | head -1
}

metaall() {
	local file key
	file=$1 key=$2
	[ -f "$file" ] || return 1
	sed -n "s/^[ 	]*$key[ 	]*=[ 	]*//p" "$file"
}

# ------------------------------------------------------------------ repo state

alpm_load_conf() {
	[ -f "$ALPM_CONF" ] || return 0
	# A caller's explicit environment override must never lose to a plain
	# assignment sitting in the config file - target_alpm's
	# ALPM_ROOT="$TARGET", or anything else scratch-rooting an install, has
	# to win over alpm.conf's own "ALPM_ROOT=/" line. Sourcing the file
	# unconditionally used to let the file silently reassert the real root
	# even when a caller had deliberately pointed elsewhere, which is
	# exactly how a scratch-root install once ended up writing over the
	# host's own /usr/lib/libc.so.6. Preserve anything already set, source
	# the file, then put the caller's values straight back.
	for _v in ALPM_ROOT ALPM_DB ALPM_CACHE ALPM_BUILDROOT ALPM_REPOD; do
		eval "_was_${_v}=\${${_v}+set}"
		eval "_val_${_v}=\${${_v}:-}"
	done
	# shellcheck disable=SC1090
	. "$ALPM_CONF"
	for _v in ALPM_ROOT ALPM_DB ALPM_CACHE ALPM_BUILDROOT ALPM_REPOD; do
		eval "[ \"\$_was_${_v}\" = set ] && ${_v}=\$_val_${_v}"
	done
	:
}

# Emits "name<TAB>url" for every configured repo, in priority order.
alpm_repos() {
	[ -d "$ALPM_REPOD" ] || return 0
	for f in "$ALPM_REPOD"/*.repo; do
		[ -f "$f" ] || continue
		n=$(meta "$f" name); u=$(meta "$f" url); e=$(meta "$f" enabled)
		[ -n "$n" ] || n=$(basename "$f" .repo)
		[ "$e" = "no" ] && continue
		[ -n "$u" ] && printf '%s\t%s\n' "$n" "$u"
	done
}

alpm_repo_url() {
	alpm_repos | while IFS='	' read -r n u; do
		[ "$n" = "$1" ] && { printf '%s\n' "$u"; break; }
	done
}

# Index line format (tab separated, one package per line):
#   name  version  release  arch  size  isize  sha256  deps  desc
idx_lookup() {
	local want f line
	want=$1
	for f in "$ALPM_DB"/sync/*.idx; do
		[ -f "$f" ] || continue
		# arch "src" marks a source-repo entry: a recipe, not an installable
		# package. Binary resolution must skip those or it will try to download
		# a .src.alpmz that was never built.
		line=$(awk -F'\t' -v p="$want" '$1==p && $4!="src"{print; exit}' "$f") || :
		if [ -n "$line" ]; then
			printf '%s\t%s\n' "$(basename "$f" .idx)" "$line"
			return 0
		fi
	done
	return 1
}

# The mirror of idx_lookup: find a package that exists ONLY as a recipe. Used to
# distinguish "no such package" from "we have the recipe but nobody built it".
idx_lookup_src() {
	local want f line
	want=$1
	for f in "$ALPM_DB"/sync/*.idx; do
		[ -f "$f" ] || continue
		line=$(awk -F'\t' -v p="$want" '$1==p && $4=="src"{print; exit}' "$f") || :
		if [ -n "$line" ]; then
			printf '%s\t%s\n' "$(basename "$f" .idx)" "$line"
			return 0
		fi
	done
	return 1
}

idx_field() { printf '%s' "$1" | cut -f"$2"; }

is_installed() { [ -d "$ALPM_DB/local/$1" ]; }

installed_version() {
	[ -f "$ALPM_DB/local/$1/PKGINFO" ] || return 1
	v=$(meta "$ALPM_DB/local/$1/PKGINFO" version)
	r=$(meta "$ALPM_DB/local/$1/PKGINFO" release)
	[ -n "$r" ] && printf '%s-%s\n' "$v" "$r" || printf '%s\n' "$v"
}

is_held() { [ -f "$ALPM_DB/hold/$1" ]; }

# Compare two version strings. Returns 0 if $1 is newer than $2.
vgt() {
	[ "$1" = "$2" ] && return 1
	newest=$(printf '%s\n%s\n' "$1" "$2" | sort -V 2>/dev/null | tail -1) || {
		# sort -V is absent on some busybox builds; fall back to string compare.
		[ "$1" \> "$2" ] && return 0 || return 1
	}
	[ "$newest" = "$1" ]
}

alpm_init_db() {
	for d in local sync hold snapshots; do
		mkdir -p "$ALPM_DB/$d"
	done
	mkdir -p "$ALPM_CACHE/pkg" "$ALPM_CACHE/src" "$ALPM_CACHE/build"
	mkdir -p "$ALPM_ROOT/usr/lib/alpm/staged" 2>/dev/null || :
}

human() {
	b=${1:-0}
	if [ "$b" -ge 1073741824 ] 2>/dev/null; then
		printf '%s.%s GiB\n' $((b/1073741824)) $(( (b%1073741824)*10/1073741824 ))
	elif [ "$b" -ge 1048576 ] 2>/dev/null; then
		printf '%s.%s MiB\n' $((b/1048576)) $(( (b%1048576)*10/1048576 ))
	elif [ "$b" -ge 1024 ] 2>/dev/null; then
		printf '%s KiB\n' $((b/1024))
	else
		printf '%s B\n' "$b"
	fi
}

confirm() {
	[ "${ALPM_YES:-0}" = "1" ] && return 0
	printf '%s::%s %s %s[Y/n]%s ' "$A_TEAL$C_B" "$C_R$C_B" "$1$C_R" "$A_GREY" "$C_R"
	read -r a || return 1
	case "$a" in n|N|no|NO|No) return 1 ;; *) return 0 ;; esac
}
