#!/bin/sh
# libalpm.sh - shared runtime for the Arctic Linux Package Manager
# POSIX sh only. Must run under busybox ash with no GNU utilities present.
# shellcheck shell=sh disable=SC2039

ALPM_VERSION="1.1.0"
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
# Recipes are not a repository. repos.d is binary-only - every entry in it
# serves .alpmz files and nothing else - and the ports tree is a separate
# host with its own layout (ALL/<repo>/<name>/recipe), reached only through
# this setting. Keeping the two apart is what stops "what can be installed"
# and "what can be compiled" from being the same list.
: "${ALPM_PORTS:=https://ports-arctic.apiwow.net/ALL}"

# How an install reports itself. The mechanics are identical in all three -
# same resolver, same fetch, same progress driven by real byte counts - only
# the wording and layout change.
#
#   arctic  the default - apt's wording inside aeryn's frame
#   apt     Debian's shape
#   aeryn   Aeryn OS's shape: a boxed summary, fetch and install phases
#   pacman  Arch's shape
#   void    XBPS's shape: a columnar table and "[*]" phase markers
#   solus   eopkg's shape
: "${ALPM_STYLE:=arctic}"

# ------------------------------------------------------------------- theming
#
# ALPM_STYLE names either one of the built-in styles or a theme file. A theme
# is a POSIX sh fragment in /etc/alpm/themes/<name>.theme (or
# ~/.config/alpm/themes/<name>.theme, which wins) that sets any of the T_*
# variables below. Everything it does not set keeps the default, so a theme
# can be three lines long.
#
# What a theme controls: the palette, the glyphs, and the wording. Fonts are
# the terminal's business, not the package manager's - alpm writes text and
# escape sequences, and has no way to choose a typeface.
#
#   colours   T_ACCENT T_OK T_WARN T_ERR T_DIM T_TEXT   (bare SGR numbers,
#             e.g. T_ACCENT=44, or an empty string for no colour)
#   glyphs    T_MARK_INFO T_MARK_OK T_MARK_FETCH T_MARK_ADD T_MARK_HELD
#   wording   T_READING T_CALC T_CALC_DONE T_CONFIRM T_FETCHING T_INSTALLING
#             T_MET T_DONE T_SYNCING
#
# A theme file is sourced, so it can also set ALPM_JOBS or anything else -
# it runs as whoever runs alpm, and lives under /etc like the rest of alpm's
# configuration.
alpm_theme_defaults() {
	: "${T_ACCENT:=44}" ; : "${T_OK:=49}"  ; : "${T_WARN:=215}"
	: "${T_ERR:=203}"   ; : "${T_DIM:=245}"; : "${T_TEXT:=231}"
	: "${T_MARK_INFO:=*}"  ; : "${T_MARK_OK:=✓}" ; : "${T_MARK_FETCH:=◈}"
	: "${T_MARK_ADD:=+}"   ; : "${T_MARK_HELD:==}"
	: "${T_READING:=Reading package lists}"
	: "${T_CALC:=Calculating dependencies...}"
	: "${T_CALC_DONE:=Done!}"
	: "${T_CONFIRM:=Proceed with installation?}"
	: "${T_FETCHING:=Fetching}"
	: "${T_INSTALLING:=Installing}"
	: "${T_MET:=already satisfied, skipping}"
	: "${T_DONE:=installed}"
	: "${T_SYNCING:=Synchronizing repositories}"
}

alpm_load_theme() {
	case "$ALPM_STYLE" in
	arctic|apt|aeryn|pacman|void|solus) alpm_theme_defaults; return 0 ;;
	esac
	# Not a built-in: it names a theme file.
	case "$ALPM_STYLE" in
	""|.|..|*/*) ALPM_STYLE=arctic; alpm_theme_defaults; return 0 ;;
	esac
	for _t in "${XDG_CONFIG_HOME:-$HOME/.config}/alpm/themes/$ALPM_STYLE.theme" \
	          "/etc/alpm/themes/$ALPM_STYLE.theme"; do
		if [ -r "$_t" ]; then
			# shellcheck disable=SC1090
			. "$_t"
			ALPM_THEME_NAME=$ALPM_STYLE
			ALPM_STYLE=custom
			alpm_theme_defaults
			return 0
		fi
	done
	printf 'alpm: no theme named %s - using the default\n' "$ALPM_STYLE" >&2
	ALPM_STYLE=arctic
	alpm_theme_defaults
}

# ---------------------------------------------------------------- presentation

# Arctic palette, lifted from the logo gradient: violet -> ice -> teal.
#
# A function, not a straight-line block: ALPM_STYLE (and any theme it names)
# is only known after alpm.conf has been read, which happens well after this
# file is sourced. Computed once at the bottom of this file for tools that
# never load a config, and again by alpm_load_conf once a theme has had its
# say.
alpm_palette() {
	# Arctic palette, lifted from the logo gradient: violet -> ice -> teal.
	if [ -t 1 ] && [ "${ALPM_COLOR:-auto}" != "never" ]; then
		C_R=$(printf '\033[0m')      ; C_B=$(printf '\033[1m')
		C_DIM=$(printf '\033[2m')    ; C_IT=$(printf '\033[3m')
		# A theme sets the numbers; these are the Arctic palette by default,
		# lifted from the logo gradient: violet -> ice -> teal.
		_sgr() { [ -n "$1" ] && printf '\033[38;5;%sm' "$1" || printf ''; }
		A_VIO=$(_sgr 99)          ; A_IND=$(_sgr 69)
		A_ICE=$(_sgr 81)          ; A_TEAL=$(_sgr "$T_ACCENT")
		A_MINT=$(_sgr "$T_OK")    ; A_SNOW=$(_sgr "$T_TEXT")
		A_GREY=$(_sgr "$T_DIM")   ; A_RED=$(_sgr "$T_ERR")
		A_AMB=$(_sgr "$T_WARN")
	else
		C_R= ; C_B= ; C_DIM= ; C_IT=
		A_VIO= ; A_IND= ; A_ICE= ; A_TEAL= ; A_MINT= ; A_SNOW= ; A_GREY= ; A_RED= ; A_AMB=
	fi

	# The four everyday output levels. Each knows all three styles, so a style is
	# not something the install path has to remember to honour - "::" and "->" are
	# the default style's markers, and they used to leak into apt and aeryn output
	# from every helper that had not been converted.
}
alpm_theme_defaults
alpm_palette

msg() {
	case "$ALPM_STYLE" in
	apt|solus) printf '%s\n' "$*" ;;
	void)      printf '%s[*]%s %s\n' "$A_TEAL$C_B" "$C_R" "$*" ;;
	aeryn)     printf '  %s%s%s\n' "$A_TEAL$C_B" "$*" "$C_R" ;;
	*)         printf '%s::%s %s%s\n' "$A_TEAL$C_B" "$C_R$C_B" "$*" "$C_R" ;;
	esac
}
msg2() {
	case "$ALPM_STYLE" in
	apt|solus) printf '%s\n' "$*" ;;
	pacman)    printf '%s...\n' "$*" ;;
	void)      printf '%s[*]%s %s\n' "$A_TEAL$C_B" "$C_R" "$*" ;;
	aeryn)     printf '  %s·%s %s%s%s\n' "$A_GREY" "$C_R" "$A_GREY" "$*" "$C_R" ;;
	*)         printf '  %s->%s %s\n' "$A_ICE$C_B" "$C_R" "$*" ;;
	esac
}
info() {
	case "$ALPM_STYLE" in
	apt|solus|pacman) printf '%s\n' "$*" ;;
	void)             printf '%s[*]%s %s\n' "$A_TEAL$C_B" "$C_R" "$*" ;;
	aeryn)            printf '  %s%s%s\n' "$A_GREY" "$*" "$C_R" ;;
	*)                printf '  %s*%s  %s\n' "$A_IND" "$C_R" "$*" ;;
	esac
}
warn()  { printf '%s::%s %s%s\n' "$A_AMB$C_B" "$C_B" "$*" "$C_R" >&2; }
err()   { printf '%sE:%s %s\n' "$A_RED$C_B" "$C_R" "$*" >&2; }
die()   { err "$*"; exit 1; }
ok() {
	case "$ALPM_STYLE" in
	apt|solus|pacman) printf '%s\n' "$*" ;;
	void)             printf '%s[*]%s %s\n' "$A_MINT$C_B" "$C_R" "$*" ;;
	aeryn)            printf '  %s✓%s %s\n' "$A_MINT" "$C_R" "$*" ;;
	*)                printf '  %s✓%s  %s\n' "$A_MINT$C_B" "$C_R" "$*" ;;
	esac
}

# Every privileged entry point funnels through here. The wording is deliberate:
# it never names a specific privilege tool.
need_root() {
	[ "$(id -u)" = "0" ] || die "Must be run as root."
}

alpm_log() {
	[ -w "$(dirname "$ALPM_LOG")" ] 2>/dev/null || return 0
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$ALPM_LOG" 2>/dev/null || :
}

# --------------------------------------------------------------------- helpers

have() { command -v "$1" >/dev/null 2>&1; }

# A package/version/release/arch field is safe to drop straight into a
# filesystem path (ALPM_CACHE/pkg/<name>-<ver>-<rel>.<arch>.alpmz,
# ALPM_DB/local/<name>, ...) only if it cannot itself contain a path
# separator. name/ver/rel/arch normally come from this machine's own repo
# index or from a package's .PKGINFO - both are effectively remote input
# (a compromised mirror, a MITM'd http:// repo, a hand-crafted .alpmz), and
# nothing upstream of fetch_pkg()/install_one() checks them. A version field
# of "1.0/../../../etc/cron.d/x" would otherwise be free to walk the
# resulting path anywhere a root-run alpm can write.
safe_component() {
	case "$1" in
	""|.|..) return 1 ;;
	*/*) return 1 ;;
	esac
	return 0
}

# Are two paths the same file as far as a package is concerned? Symlinks
# compare by target, everything else by content. Used to tell a real file
# conflict from two packages shipping identical bytes at the same path.
same_file() {
	if [ -L "$1" ] || [ -L "$2" ]; then
		[ -L "$1" ] && [ -L "$2" ] || return 1
		[ "$(readlink "$1")" = "$(readlink "$2")" ]
		return $?
	fi
	[ -f "$1" ] && [ -f "$2" ] || return 1
	[ "$(sha256 "$1")" = "$(sha256 "$2")" ]
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
# _dl_file/dl/dlq's own variables are prefixed _dl_: both are called directly
# (not via a subshell) from sync_repo, fetch_pkg and others that use plain
# "url"/"out"/"src" names of their own for the very same call - dl() used to
# assign those as bare globals and stomp the caller's variable of the same
# name the moment it returned. sync_repo() was the one place this actually
# bit: it keeps its repo's base url in "$url", calls dl() with
# "$url/$ARCH/INDEX", and used "$url" again afterward to record the repo's
# url in sync/<repo>.url - which then got the fetch path written into it
# instead, silently, every successful sync.
_dl_file() {
	_dl_src=${1#file://}
	[ -f "$_dl_src" ] || return 1
	mkdir -p "$(dirname "$2")"
	cp -f "$_dl_src" "$2" 2>/dev/null
}

# The transfer itself, no progress and no output. Never call this directly -
# dl/dlq/dl_bar handle file://, the .part file and the rename.
#
# The wget branch takes -O and nothing else on purpose. toybox's wget is the
# only one a freshly installed Arctic system has, and it implements exactly
# --max-redirect, -d, -O and -p: "wget -q" is a hard "Unknown option 'q'"
# there, which is what every source-build fetch died with. -O is the one
# output flag toybox, busybox and GNU wget all agree on, so quietness comes
# from a redirect rather than a flag no one can rely on.
_dl_run() {
	if have curl; then
		curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"
	elif have wget; then
		wget -O "$2" "$1" >/dev/null 2>&1
	else
		return 127
	fi
}

dl() {
	_dl_url=$1 _dl_out=$2
	mkdir -p "$(dirname "$_dl_out")" 2>/dev/null || :
	case "$_dl_url" in
	file://*) _dl_file "$_dl_url" "$_dl_out"; return $? ;;
	esac
	have curl || have wget || { err "no downloader available (need curl or wget)"; return 1; }
	_dl_run "$_dl_url" "$_dl_out.part" || { rm -f "$_dl_out.part"; return 1; }
	mv "$_dl_out.part" "$_dl_out"
}

# Silent variant for index files.
dlq() {
	_dl_url=$1 _dl_out=$2
	mkdir -p "$(dirname "$_dl_out")" 2>/dev/null || :
	case "$_dl_url" in
	file://*) _dl_file "$_dl_url" "$_dl_out"; return $? ;;
	esac
	_dl_run "$_dl_url" "$_dl_out.part" || { rm -f "$_dl_out.part"; return 1; }
	mv "$_dl_out.part" "$_dl_out"
}

# ------------------------------------------------------------------- progress
#
# Everything below redraws its line with a carriage return and nothing else.
# No terminal clear, no cursor addressing: an install has to stay readable
# scrolled back in a log, over a serial console, and in a terminal that was
# already full of other output when it started.

# The file being polled does not exist yet for the first frame or two, and a
# failed input redirection is reported by the shell itself - redirecting only
# wc's stderr would still leave "No such file or directory" printed over the
# bar. The braces put the redirection inside what gets silenced.
_bytes() { { wc -c <"$1"; } 2>/dev/null || echo 0; }

_rate() {
	_r_b=${1:-0}
	if   [ "$_r_b" -ge 1048576 ] 2>/dev/null; then
		printf '%s.%sMB/s' $((_r_b/1048576)) $(( (_r_b%1048576)*10/1048576 ))
	elif [ "$_r_b" -ge 1024 ] 2>/dev/null; then
		printf '%s.%skB/s' $((_r_b/1024)) $(( (_r_b%1024)*10/1024 ))
	else
		printf '%sB/s' "$_r_b"
	fi
}

_clock() {
	_c_s=${1:-0}
	[ "$_c_s" -ge 0 ] 2>/dev/null || _c_s=0
	[ "$_c_s" -gt 359999 ] && _c_s=359999
	printf '%d:%02d:%02d' $((_c_s/3600)) $(( (_c_s%3600)/60 )) $((_c_s%60))
}

# One frame of a download bar. cur/total in bytes, rate in bytes/s, eta in
# seconds. A total of 0 means the size is not known ahead of time, in which
# case there is no percentage to show and the bar stays empty rather than
# inventing a position.
_bar_line() {
	_bl_label=$1 _bl_cur=$2 _bl_total=$3 _bl_rate=$4 _bl_eta=$5
	_bl_w=$(( ${COLUMNS:-80} - 54 )); [ "$_bl_w" -lt 10 ] && _bl_w=10
	if [ "${_bl_total:-0}" -gt 0 ] 2>/dev/null; then
		_bl_pct=$(( _bl_cur * 100 / _bl_total ))
		[ "$_bl_pct" -gt 100 ] && _bl_pct=100
		_bl_fill=$(( _bl_pct * _bl_w / 100 ))
	else
		_bl_pct=-1; _bl_fill=0
	fi
	_bl_s=""; _bl_i=0
	while [ "$_bl_i" -lt "$_bl_fill" ]; do _bl_s="$_bl_s#"; _bl_i=$((_bl_i+1)); done
	while [ "$_bl_i" -lt "$_bl_w" ];    do _bl_s="$_bl_s "; _bl_i=$((_bl_i+1)); done
	if [ "$_bl_pct" -lt 0 ]; then
		printf '\r  %s%-18.18s%s [%s]  ---   %9s %8s' \
			"$A_SNOW" "$_bl_label" "$C_R" "$_bl_s" "$(_rate "$_bl_rate")" "$(_clock "$_bl_eta")"
	else
		printf '\r  %s%-18.18s%s [%s%s%s] %3d%%  %9s %8s' \
			"$A_SNOW" "$_bl_label" "$C_R" "$A_TEAL" "$_bl_s" "$C_R" "$_bl_pct" \
			"$(_rate "$_bl_rate")" "$(_clock "$_bl_eta")"
	fi
}

# Download with a live bar: the file grows on disk, so the bar is driven by
# the real byte count rather than a timer pretending to be one. $3 is the
# size the repository index says to expect.
dl_bar() {
	_dlb_url=$1 _dlb_out=$2 _dlb_total=${3:-0} _dlb_label=$4
	mkdir -p "$(dirname "$_dlb_out")" 2>/dev/null || :
	case "$_dlb_url" in
	file://*)
		_dl_file "$_dlb_url" "$_dlb_out" || return 1
		if [ -t 1 ]; then
			_dlb_got=$(_bytes "$_dlb_out")
			_bar_line "$_dlb_label" "$_dlb_got" "${_dlb_total:-0}" 0 0
			printf '\n'
		fi
		return 0 ;;
	esac
	have curl || have wget || { err "no downloader available (need curl or wget)"; return 1; }
	rm -f "$_dlb_out.part"
	if [ ! -t 1 ]; then
		_dl_run "$_dlb_url" "$_dlb_out.part" || { rm -f "$_dlb_out.part"; return 1; }
		mv "$_dlb_out.part" "$_dlb_out"; return 0
	fi
	_dl_run "$_dlb_url" "$_dlb_out.part" &
	_dlb_pid=$!
	_dlb_t0=$(date '+%s')
	while kill -0 "$_dlb_pid" 2>/dev/null; do
		_dlb_got=$(_bytes "$_dlb_out.part")
		_dlb_el=$(( $(date '+%s') - _dlb_t0 )); [ "$_dlb_el" -lt 1 ] && _dlb_el=1
		_dlb_rate=$(( _dlb_got / _dlb_el ))
		if [ "${_dlb_total:-0}" -gt 0 ] && [ "$_dlb_rate" -gt 0 ]; then
			_dlb_eta=$(( (_dlb_total - _dlb_got) / _dlb_rate ))
			[ "$_dlb_eta" -lt 0 ] && _dlb_eta=0
		else
			_dlb_eta=0
		fi
		_bar_line "$_dlb_label" "$_dlb_got" "${_dlb_total:-0}" "$_dlb_rate" "$_dlb_eta"
		sleep 1
	done
	wait "$_dlb_pid" || { rm -f "$_dlb_out.part"; printf '\n'; return 1; }
	_dlb_got=$(_bytes "$_dlb_out.part")
	_dlb_el=$(( $(date '+%s') - _dlb_t0 )); [ "$_dlb_el" -lt 1 ] && _dlb_el=1
	_bar_line "$_dlb_label" "$_dlb_got" "${_dlb_got:-0}" $(( _dlb_got / _dlb_el )) 0
	printf '\n'
	mv "$_dlb_out.part" "$_dlb_out"
}

# "Calculating dependencies... [====      ]", advanced by the resolver itself
# as each package's index entry is actually read. calc_begin resets it,
# calc_step redraws it from done/total, calc_done replaces the whole line
# with the finished form. total grows as the graph opens up, so the bar can
# sit still for a while - it never runs backwards, and it is never a timer.
# ----------------------------------------------------------------- ui styles
#
# One function per thing an install has to say, with the wording for each
# style inside it. Nothing here changes what alpm does - the resolver, the
# fetch and the progress bars are the same in all three - so a style can
# never be more optimistic than the transaction actually is.

ui_reading() {
	case "$ALPM_STYLE" in
	apt)    printf 'Reading package lists... Done\n'
	        printf 'Building dependency tree... ' ;;
	pacman) msg "Synchronizing package databases" ;;
	void)   printf '%s[*]%s Collecting packages\n' "$A_TEAL$C_B" "$C_R" ;;
	solus)  printf 'Reading repository index\n' ;;
	custom) msg "$T_READING" ;;
	aeryn)  printf '\n  %s%s%s\n' "$A_TEAL$C_B" "Resolving transaction" "$C_R" ;;
	*)      msg "Reading package lists" ;;
	esac
}

ui_reading_done() {
	case "$ALPM_STYLE" in
	apt) printf 'Done\n' ;;
	esac
}

# The transaction summary. $1 packages to install, $2 already satisfied,
# $3 download bytes, $4 count, $5 installed bytes.
ui_summary() {
	_ui_todo=$1 _ui_met=$2 _ui_bytes=$3 _ui_n=$4 _ui_isize=${5:-0}
	_ui_nmet=0
	for _u in $_ui_met; do _ui_nmet=$((_ui_nmet+1)); done
	case "$ALPM_STYLE" in
	apt)
		printf 'The following NEW packages will be installed:\n '
		for _u in $_ui_todo; do printf ' %s' "$_u"; done
		printf '\n'
		printf '%s upgraded, %s newly installed, 0 to remove and 0 not upgraded.\n' \
			0 "$_ui_n"
		printf 'Need to get %s of archives.\n' "$(human "$_ui_bytes")"
		printf 'After this operation, %s of additional disk space will be used.\n' \
			"$(human "$_ui_isize")"
		[ "$_ui_nmet" -gt 0 ] && \
			printf '%s package(s) are already the newest version.\n' "$_ui_nmet"
		;;
	pacman)
		printf '\nPackages (%s)' "$_ui_n"
		for _u in $_ui_todo; do
			_ue=$(idx_lookup "$_u") || continue
			printf ' %s-%s-%s' "$_u" \
				"$(printf '%s' "$_ue" | cut -f3)" "$(printf '%s' "$_ue" | cut -f4)"
		done
		printf '\n\n'
		printf 'Total Download Size:   %s\n' "$(human "$_ui_bytes")"
		printf 'Total Installed Size:  %s\n' "$(human "$_ui_isize")"
		[ "$_ui_nmet" -gt 0 ] && \
			printf 'Already satisfied:     %s package(s)\n' "$_ui_nmet"
		printf '\n'
		;;
	void)
		printf '\n%-24s %-9s %-16s %s\n' "Name" "Action" "Version" "Download size"
		for _u in $_ui_todo; do
			_ue=$(idx_lookup "$_u") || continue
			printf '%-24s %-9s %-16s %s\n' "$_u" "install" \
				"$(printf '%s' "$_ue" | cut -f3)_$(printf '%s' "$_ue" | cut -f4)" \
				"$(human "$(printf '%s' "$_ue" | cut -f6)")"
		done
		for _u in $_ui_met; do
			printf '%-24s %-9s %-16s %s\n' "$_u" "hold" "$(installed_version "$_u")" "-"
		done
		printf '\nSize to download:       %s\n' "$(human "$_ui_bytes")"
		printf 'Size required on disk:  %s\n\n' "$(human "$_ui_isize")"
		;;
	solus)
		printf '\nFollowing packages will be installed:\n'
		for _u in $_ui_todo; do printf ' %s' "$_u"; done
		printf '\n\nTotal size of package(s): %s\n' "$(human "$_ui_bytes")"
		printf 'Total size on disk:       %s\n\n' "$(human "$_ui_isize")"
		;;
	aeryn|arctic|*)
		# arctic is apt's wording inside aeryn's frame: the box says what is
		# about to happen at a glance, the lines below it read as prose.
		_ui_w=57
		_ui_bar=""; _ui_i=0
		while [ "$_ui_i" -lt "$_ui_w" ]; do _ui_bar="$_ui_bar─"; _ui_i=$((_ui_i+1)); done
		_ui_head="─ Transaction "
		_ui_i=14
		while [ "$_ui_i" -lt "$_ui_w" ]; do _ui_head="$_ui_head─"; _ui_i=$((_ui_i+1)); done
		printf '\n  %s┌%s┐%s\n' "$A_TEAL" "$_ui_head" "$C_R"
		for _u in $_ui_todo; do
			_ue=$(idx_lookup "$_u") || continue
			printf '  %s│%s  %s+%s %-24.24s %-15.15s %11s %s│%s\n' \
				"$A_TEAL" "$C_R" "$A_MINT" "$C_R" "$_u" \
				"$(printf '%s' "$_ue" | cut -f3)-$(printf '%s' "$_ue" | cut -f4)" \
				"$(human "$(printf '%s' "$_ue" | cut -f6)")" "$A_TEAL" "$C_R"
		done
		for _u in $_ui_met; do
			printf '  %s│%s  %s=%s %-24.24s %-15.15s %11s %s│%s\n' \
				"$A_TEAL" "$C_R" "$A_GREY" "$C_R" "$_u" \
				"$(installed_version "$_u")" "held" "$A_TEAL" "$C_R"
		done
		printf '  %s├%s┤%s\n' "$A_TEAL" "$_ui_bar" "$C_R"
		_ui_sum=$(printf '  %s new, %s already satisfied, %s to download' \
			"$_ui_n" "$_ui_nmet" "$(human "$_ui_bytes")")
		_ui_i=${#_ui_sum}
		while [ "$_ui_i" -lt "$_ui_w" ]; do _ui_sum="$_ui_sum "; _ui_i=$((_ui_i+1)); done
		printf '  %s│%s%s%s│%s\n' "$A_TEAL" "$C_R" "$_ui_sum" "$A_TEAL" "$C_R"
		printf '  %s└%s┘%s\n' "$A_TEAL" "$_ui_bar" "$C_R"
		if [ "$ALPM_STYLE" != aeryn ]; then
			printf '\n  %safter this, %s of disk space will be used%s\n' \
				"$A_GREY" "$(human "$_ui_isize")" "$C_R"
		fi
		;;
	esac
}

ui_confirm_text() {
	case "$ALPM_STYLE" in
	apt)    printf 'Do you want to continue?' ;;
	pacman) printf 'Proceed with installation?' ;;
	void)   printf 'Do you want to continue?' ;;
	solus)  printf 'Would you like to continue?' ;;
	aeryn)  printf 'Apply this transaction?' ;;
	custom) printf '%s' "$T_CONFIRM" ;;
	*)      printf 'Proceed with installation?' ;;
	esac
}

# $1 role (package|dependency)  $2 name  $3 url  $4 size  $5 index
ui_fetch() {
	case "$ALPM_STYLE" in
	apt|arctic)
		printf 'Get:%s %s [%s]\n' "$5" "$3" "$(human "$4")" ;;
	pacman)
		printf ' %s...\n' "$2" ;;
	void)
		printf '%s[*]%s Downloading %s %s\n' "$A_TEAL$C_B" "$C_R" "$2" "$(human "$4")" ;;
	solus)
		printf 'Downloading %s\n' "$2" ;;
	custom)
		printf '  %s%s%s %-28s %s%s%s\n' "$A_ICE" "$T_MARK_FETCH" "$C_R" "$2" \
			"$A_GREY" "$T_FETCHING" "$C_R" ;;
	aeryn)
		printf '  %s◈%s %-28s %sfetching%s\n' "$A_ICE" "$C_R" "$2" "$A_GREY" "$C_R" ;;
	*)
		if [ "$1" = dependency ]; then printf '  Fetching dependency %s\n' "$3"
		else printf "  Fetching package '%s'\n" "$2"; fi ;;
	esac
}

ui_cached() {
	case "$ALPM_STYLE" in
	apt|arctic) printf 'Get:%s %s [cached]\n' "${3:-1}" "$2" ;;
	pacman)     printf ' %s is up to date\n' "$2" ;;
	void)       printf '%s[*]%s %s (cached)\n' "$A_TEAL$C_B" "$C_R" "$2" ;;
	solus)      printf '%s [cached]\n' "$2" ;;
	aeryn)      printf '  %s◈%s %-28s %scached%s\n' "$A_GREY" "$C_R" "$2" "$A_GREY" "$C_R" ;;
	*)
		if [ "$1" = dependency ]; then printf "  Dependency '%s' is already in the cache\n" "$2"
		else printf "  Package '%s' is already in the cache\n" "$2"; fi ;;
	esac
}

ui_phase_install() {
	case "$ALPM_STYLE" in
	apt)    : ;;
	pacman) printf '\n'; msg "Processing package changes" ;;
	void)   printf '\n%s[*]%s Unpacking packages\n' "$A_TEAL$C_B" "$C_R" ;;
	solus)  printf '\n' ;;
	*)      printf '\n' ;;
	esac
}

# $1 role  $2 name  $3 version-release  $4 index  $5 total
ui_install() {
	case "$ALPM_STYLE" in
	apt|arctic) printf 'Setting up %s (%s)\n' "$2" "$3" ;;
	pacman)     printf '(%s/%s) installing %s\n' "${4:-1}" "${5:-1}" "$2" ;;
	void)       printf '%s: unpacking ...\n' "$2-$3" ;;
	solus)      printf 'Installing %s, version %s\n' "$2" "$3" ;;
	custom)     printf '  %s%s%s %-28s %s%s %s%s\n' "$A_MINT" "$T_MARK_OK" "$C_R" "$2" \
			"$A_GREY" "$T_INSTALLING" "$3" "$C_R" ;;
	aeryn)      printf '  %s✓%s %-28s %s%s%s\n' "$A_MINT" "$C_R" "$2" "$A_GREY" "$3" "$C_R" ;;
	*)
		if [ "$1" = dependency ]; then printf "  Installing dependency '%s'\n" "$2"
		else printf "  Installing package '%s'\n" "$2"; fi ;;
	esac
}

ui_met() {
	case "$ALPM_STYLE" in
	apt)        printf '%s is already the newest version.\n' "$1" ;;
	pacman)     printf ' %s is up to date -- skipping\n' "$1" ;;
	void|solus) : ;;
	custom)     printf '  %s%s: %s%s\n' "$A_GREY" "$1" "$T_MET" "$C_R" ;;
	aeryn)      : ;;
	*)          printf "  Dependency met '%s', skipping...\n" "$1" ;;
	esac
}

# $1 name  $2 dependency count  $3 transaction id
ui_done() {
	case "$ALPM_STYLE" in
	apt)
		printf 'Processing triggers ...\n'
		printf "Done. Undo with 'alpm rollback %s'.\n" "$3" ;;
	pacman)
		printf '\n'
		msg "Done. Undo with 'alpm rollback $3'" ;;
	void)
		printf '\n%s[*]%s Done - undo with: alpm rollback %s\n' \
			"$A_TEAL$C_B" "$C_R" "$3" ;;
	solus)
		printf '\nInstall completed. Undo with: alpm rollback %s\n' "$3" ;;
	custom)
		printf '\n  %s%s%s %s '"'"'%s'"'"' %s\n' "$A_MINT" "$T_MARK_OK" "$C_R" "Package" "$1" "$T_DONE"
		printf '  %sundo with: alpm rollback %s%s\n' "$A_GREY" "$3" "$C_R" ;;
	aeryn)
		printf '\n  %s%s applied%s  %s\n' "$A_MINT$C_B" "Transaction" "$C_R" "$3"
		printf '  %sundo with: alpm rollback %s%s\n' "$A_GREY" "$3" "$C_R" ;;
	*)
		case "$2" in
		0) ok "Package '$1' installed" ;;
		1) ok "Package '$1' installed with 1 dependency" ;;
		*) ok "Package '$1' installed with $2 dependencies" ;;
		esac ;;
	esac
}

case "$ALPM_STYLE" in
apt)    CALC_LABEL="Building dependency tree..." ;;
custom) CALC_LABEL="$T_CALC" ;;
pacman) CALC_LABEL="resolving dependencies..." ;;
void)   CALC_LABEL="[*] Resolving dependencies..." ;;
solus)  CALC_LABEL="Resolving dependencies..." ;;
aeryn)  CALC_LABEL="Resolving..." ;;
*)      CALC_LABEL="Calculating dependencies..." ;;
esac

calc_begin() { _calc_last=-1; [ -t 1 ] && printf '  %s' "$CALC_LABEL"; return 0; }

calc_step() {
	[ -t 1 ] || return 0
	_calc_done=$1 _calc_tot=$2
	[ "${_calc_tot:-0}" -gt 0 ] 2>/dev/null || return 0
	_calc_w=20
	_calc_f=$(( _calc_done * _calc_w / _calc_tot ))
	[ "$_calc_f" = "${_calc_last}" ] && return 0
	_calc_last=$_calc_f
	_calc_s=""; _calc_i=0
	while [ "$_calc_i" -lt "$_calc_f" ]; do _calc_s="$_calc_s="; _calc_i=$((_calc_i+1)); done
	while [ "$_calc_i" -lt "$_calc_w" ]; do _calc_s="$_calc_s "; _calc_i=$((_calc_i+1)); done
	printf '\r  %s %s[%s]%s' "$CALC_LABEL" "$A_TEAL" "$_calc_s" "$C_R"
}

calc_done() {
	[ -t 1 ] || return 0
	# The trailing run of spaces is what wipes the bar this replaces - there
	# is deliberately no clear-line escape anywhere in here.
	printf '\r  %s %s%s%s                    \n' "$CALC_LABEL" "$A_MINT" \
		"${T_CALC_DONE:-Done!}" "$C_R"
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
	# Reject a member path that would land outside $dest before anything is
	# extracted - neither tar implementation this ships against (bsdtar,
	# busybox tar) can be assumed to refuse a ".." or absolute entry on its
	# own, and a package's payload is otherwise trusted enough to unpack
	# straight onto $ALPM_ROOT (see install_one). Checked against the listing
	# rather than during extraction so nothing is written before the whole
	# archive has been looked at.
	_ut_bad="" _ut_oldifs=$IFS
	IFS='
'
	for _ut_ent in $(tarlist "$archive" 2>/dev/null); do
		case "$_ut_ent" in
		/*|../*|*/../*|*/..) _ut_bad=$_ut_ent; break ;;
		esac
	done
	IFS=$_ut_oldifs
	if [ -n "$_ut_bad" ]; then
		err "refusing to unpack $archive: unsafe path entry '$_ut_bad'"
		return 1
	fi
	mkdir -p "$dest"
	if have bsdtar; then bsdtar -xpf "$archive" -C "$dest"
	else tar -xpf "$archive" -C "$dest"; fi
}

# Unpacking an upstream source tarball, as opposed to installing a package.
#
# -o (no-same-owner, spelled the same way by bsdtar, busybox tar and GNU tar)
# instead of -p. An upstream tarball carries whatever uid the maintainer
# happened to roll it as, and restoring that needs CAP_CHOWN - which the
# build sandbox drops along with every other capability, so bsdtar failed
# every single file with "Can't set user=1000/group=1000" and then exited
# non-zero, taking the whole build with it. Nothing in a build needs those
# uids: the package's own ownership comes from what package() installs into
# $pkgdir, not from who shipped the tarball.
untar_src() {
	archive=$1 dest=$2
	mkdir -p "$dest"
	if have bsdtar; then bsdtar -xof "$archive" -C "$dest"
	else tar -xof "$archive" -C "$dest"; fi
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
# Every name in here is prefixed _um_. This is called from install_one, which
# is called from a plain "for p in ..." loop over package names - and the
# inner helper used a bare "p" for the path it was fixing up, so the caller
# came back from fix_usrmerge with its package name replaced by
# "/usr/sbin". A single-package install only showed it in the closing line
# ("/usr/sbin built from source and installed"); installing two from source
# in one command operated on the wrong name entirely for the second.
fix_usrmerge() {
	_um_root=$1
	_um_fix() {
		_um_p=$1 _um_real=$2 _um_tgt=$3
		if [ -d "$_um_p" ] && [ ! -L "$_um_p" ]; then
			for _um_f in "$_um_p"/* "$_um_p"/.[!.]*; do
				[ -e "$_um_f" ] || [ -L "$_um_f" ] || continue
				mv -f "$_um_f" "$_um_real/" 2>/dev/null || :
			done
			rmdir "$_um_p" 2>/dev/null || :
		fi
		[ -e "$_um_p" ] || ln -sfn "$_um_tgt" "$_um_p"
	}
	[ -d "$_um_root/usr/bin" ] || return 0
	[ -d "$_um_root/usr/lib" ] && \
		_um_fix "$_um_root/lib"     "$_um_root/usr/lib" "usr/lib"
	[ -d "$_um_root/usr/lib" ] && \
		_um_fix "$_um_root/lib64"   "$_um_root/usr/lib" "usr/lib"
	_um_fix "$_um_root/bin"      "$_um_root/usr/bin" "usr/bin"
	_um_fix "$_um_root/sbin"     "$_um_root/usr/bin" "usr/bin"
	_um_fix "$_um_root/usr/sbin" "$_um_root/usr/bin" "bin"
	return 0
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
	# ALPM_STYLE may have just been set (or changed) by the config, and a
	# theme file can replace the whole palette - so the colours are worked
	# out here rather than when this file was sourced.
	alpm_load_theme
	alpm_palette
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

# ----------------------------------------------------------------- ports tree

# The ports manifest, cached. Columns are
# "repo name version buildsystem license deps makedeps url source desc".
# Refetched when it is missing; kept otherwise, so a source build does not
# need the network twice.
ports_manifest() {
	_pm_f="$ALPM_CACHE/ports/manifest.tsv"
	if [ ! -s "$_pm_f" ]; then
		mkdir -p "$ALPM_CACHE/ports"
		dlq "$ALPM_PORTS/manifest.tsv" "$_pm_f" || return 1
		# A missing file on a static host is answered with the site's own
		# HTML rather than a 404, so "the download worked" is not enough -
		# check it actually looks like the manifest before caching it.
		if ! grep -q '^[a-z-]*	[a-zA-Z0-9]' "$_pm_f" 2>/dev/null; then
			rm -f "$_pm_f"; return 1
		fi
	fi
	printf '%s\n' "$_pm_f"
}

# The ports repo a package's recipe lives under, or nothing if it has no
# recipe at all. This is what tells "we never heard of it" apart from "we
# have the recipe but nobody built a binary".
ports_repo_of() {
	_pr_m=$(ports_manifest) || return 1
	_pr_r=$(awk -F'\t' -v p="$1" '$1!~/^#/ && $2==p {print $1; exit}' "$_pr_m")
	[ -n "$_pr_r" ] || return 1
	safe_component "$_pr_r" || return 1
	printf '%s\n' "$_pr_r"
}

ports_have() { ports_repo_of "$1" >/dev/null 2>&1; }

# A recipe is shell that alpm-build sources. A static host answers a missing
# file with its own index page, so an unchecked download lands an HTML
# document in the recipe's place and the build dies somewhere much stranger.
looks_like_recipe() {
	[ -s "$1" ] || return 1
	grep -q '^name=' "$1" 2>/dev/null
}

# How stale the repository indexes are, in days, or 999 when there are none.
# Used to decide whether "package not found" is worth blaming on an old
# index: telling someone to run 'alpm fetch all' when they synced ten minutes
# ago sends them to do it again for nothing, and the real answer is that the
# package does not exist.
idx_age_days() {
	_ia_new=""
	for _ia_f in "$ALPM_DB"/sync/*.idx; do
		[ -f "$_ia_f" ] || continue
		if [ -z "$_ia_new" ] || [ "$_ia_f" -nt "$_ia_new" ]; then _ia_new=$_ia_f; fi
	done
	[ -n "$_ia_new" ] || { echo 999; return; }
	_ia_now=$(date '+%s' 2>/dev/null || echo 0)
	_ia_then=$(date -r "$_ia_new" '+%s' 2>/dev/null || \
		stat -c %Y "$_ia_new" 2>/dev/null || echo "$_ia_now")
	echo $(( (_ia_now - _ia_then) / 86400 ))
}

# "not found", plus the sync hint only when a sync could plausibly help.
not_found_hint() {
	_nf_age=$(idx_age_days)
	if [ "${_nf_age:-999}" -ge 1 ]; then
		printf " - the package lists are %s day(s) old, try 'alpm fetch all'" "$_nf_age"
	fi
}

idx_field() { printf '%s' "$1" | cut -f"$2"; }

# PKGINFO is the last file install_one writes, so it is the only thing in a
# package's database directory that proves the install ran to the end. The
# directory existing proves nothing: an install interrupted (or died) between
# "mkdir $ALPM_DB/local/$p" and the end of the transaction left a directory
# with no DEPS and no PKGINFO behind, and this said "installed" for it
# forever after - `alpm ins vim` would report vim was already there while
# `alpm deps vim` died on the missing DEPS file, and the dependency tree
# marked it satisfied for everything that needed it.
is_installed() { [ -f "$ALPM_DB/local/$1/PKGINFO" ]; }

# Directories under local/ that is_installed() rejects: an interrupted
# install, or one from before PKGINFO was written last. Nothing reads them
# and they only confuse the resolver.
alpm_partials() {
	for _pt_d in "$ALPM_DB"/local/*/; do
		[ -d "$_pt_d" ] || continue
		[ -f "$_pt_d/PKGINFO" ] && continue
		printf '%s\n' "${_pt_d%/}"
	done
}

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
	case "$ALPM_STYLE" in
	apt|void) printf '%s [Y/n] ' "$1" ;;
	solus)    printf '%s [yes/no] ' "$1" ;;
	aeryn)    printf '\n  %s?%s %s %s[Y/n]%s ' "$A_ICE$C_B" "$C_R" "$1" "$A_GREY" "$C_R" ;;
	*)        printf '%s::%s %s %s[Y/n]%s ' "$A_TEAL$C_B" "$C_R$C_B" "$1$C_R" "$A_GREY" "$C_R" ;;
	esac
	read -r a || { printf '\n'; return 1; }
	# Without this the answer and whatever is printed next share a line -
	# ":: Proceed with installation? [Y/n] :: aborted" - whenever the reply
	# came from a pipe rather than a terminal, where the user's own Enter
	# would have supplied the newline.
	[ -t 0 ] || printf '\n'
	case "$a" in n|N|no|NO|No) return 1 ;; *) return 0 ;; esac
}
