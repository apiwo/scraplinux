#!/bin/sh
# Repackage upstream browser binaries into .spz.
#
# Firefox and Chrome from source are hours of compute each and need a Rust and
# Node toolchain on top. Mozilla and Google both publish working x86_64 builds,
# so these are repackaged as-is: same binaries you would get from their website,
# just delivered through scraps so they can be listed, verified and removed like
# anything else.
set -u

if [ "${SCRAPLINUX_SANDBOX:-0}" != "1" ]; then
	echo "refusing to build outside the sandbox - use scraplinux/build/scraplinux-sandbox" >&2
	exit 1
fi

B=/home/apiwo/scraplinux-build
SRC=$B/src
W=$B/work/browsers
R=$B/repo
TREE=/home/apiwo/scraplinux
ARCH=x86_64
DATE=$(date '+%s')

mkdir -p "$W" "$R/base/$ARCH"
step() { printf '\n\033[1;36m:: %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mok\033[0m %s\n' "$*"; }
bad()  { printf '   \033[31mFAILED\033[0m %s\n' "$*"; }

# Same emit() shape mkpkgs.sh uses.
emit() {
	pd=$1 name=$2 ver=$3 repo=$4 desc=$5 lic=$6 url=$7 deps=$8
	isize=$(du -sk "$pd" 2>/dev/null | cut -f1); isize=$(( ${isize:-0} * 1024 ))
	{
		printf '# ScrapLinux package, built %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
		printf 'format = 2\nname = %s\nversion = %s\nrelease = 1\narch = %s\n' \
			"$name" "$ver" "$ARCH"
		printf 'desc = %s\nurl = %s\nlicense = %s\n' "$desc" "$url" "$lic"
		printf 'isize = %s\nbuilddate = %s\nbuilder = build-browsers.sh\nrepo = %s\n' \
			"$isize" "$DATE" "$repo"
		printf 'origin = upstream-binary\n'
		for d in $deps; do printf 'depend = %s\n' "$d"; done
	} >"$pd/.PKGINFO"
	( cd "$pd" && find . -type f -o -type l ) | sed 's|^\.||' \
		| grep -v '^/\.\(PKGINFO\|FILES\|INSTALL\)$' | sort >"$pd/.FILES"
	out="$R/$repo/$ARCH/$name-$ver-1.$ARCH.spz"
	( cd "$pd" && tar -cf - . | xz -T0 -3 >"$out" ) || { bad "$name: tar failed"; return 1; }
	ok "$(basename "$out") ($(du -h "$out" | cut -f1), $(wc -l <"$pd/.FILES") files)"
}

# ------------------------------------------------------------------- firefox
step "packaging Firefox from Mozilla's official build"
if ! ls "$R/base/$ARCH"/firefox-*.spz >/dev/null 2>&1; then
	FF=$SRC/firefox-latest.tar.xz
	[ -s "$FF" ] || curl -fL --retry 3 -o "$FF" \
		'https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64&lang=en-US' \
		>/dev/null 2>&1
	if [ -s "$FF" ]; then
		rm -rf "$W/ff"; mkdir -p "$W/ff"
		tar -xf "$FF" -C "$W/ff" 2>/dev/null
		if [ -d "$W/ff/firefox" ]; then
			ver=$(sed -n 's/^Version=//p' "$W/ff/firefox/application.ini" 2>/dev/null | head -1)
			[ -n "$ver" ] || ver=$(strings "$W/ff/firefox/firefox" 2>/dev/null \
				| grep -oE '^[0-9]{2,3}\.[0-9.]+$' | head -1)
			[ -n "$ver" ] || ver=0
			pd=$W/ffpkg; rm -rf "$pd"
			mkdir -p "$pd/opt" "$pd/usr/bin" "$pd/usr/share/applications" \
			         "$pd/usr/share/icons/hicolor/128x128/apps"
			cp -a "$W/ff/firefox" "$pd/opt/firefox"
			cat >"$pd/usr/bin/firefox" <<'SH'
#!/bin/sh
# Mozilla's own build, launched from /opt/firefox.
exec /opt/firefox/firefox "$@"
SH
			chmod 755 "$pd/usr/bin/firefox"
			cat >"$pd/usr/share/applications/firefox.desktop" <<'DESK'
[Desktop Entry]
Name=Firefox
Comment=Browse the web
Exec=/opt/firefox/firefox %u
Icon=firefox
Terminal=false
Type=Application
Categories=Network;WebBrowser;
MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;
DESK
			[ -f "$pd/opt/firefox/browser/chrome/icons/default/default128.png" ] && \
				cp -f "$pd/opt/firefox/browser/chrome/icons/default/default128.png" \
					"$pd/usr/share/icons/hicolor/128x128/apps/firefox.png"
			emit "$pd" firefox "$ver" base \
				"Mozilla Firefox (upstream build)" "MPL-2.0" \
				"https://mozilla.org/firefox/" \
				"glibc gtk3 libx11 libxcb alsa-lib pipewire dbus fontconfig freetype"
		else bad "firefox (archive did not contain firefox/)"; fi
	else bad "firefox (download failed)"; fi
else
	ok "firefox already packaged"
fi

# -------------------------------------------------------------------- chrome
step "packaging Google Chrome from Google's official build"
if ! ls "$R/base/$ARCH"/google-chrome-*.spz >/dev/null 2>&1; then
	CH=$SRC/google-chrome-stable.deb
	[ -s "$CH" ] || curl -fL --retry 3 -o "$CH" \
		'https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb' \
		>/dev/null 2>&1
	if [ -s "$CH" ]; then
		rm -rf "$W/ch"; mkdir -p "$W/ch"
		# A .deb is an ar archive holding data.tar.xz.
		( cd "$W/ch" && ar x "$CH" 2>/dev/null && \
		  tar -xf data.tar.xz 2>/dev/null || tar -xf data.tar.zst 2>/dev/null )
		if [ -d "$W/ch/opt/google/chrome" ]; then
			ver=$( "$W/ch/opt/google/chrome/chrome" --version 2>/dev/null \
				| grep -oE '[0-9]+\.[0-9.]+' | head -1 )
			[ -n "$ver" ] || ver=$(grep -aoE '[0-9]{3}\.0\.[0-9]{4}\.[0-9]+' \
				"$W/ch/opt/google/chrome/chrome" 2>/dev/null | head -1)
			[ -n "$ver" ] || ver=0
			pd=$W/chpkg; rm -rf "$pd"
			mkdir -p "$pd/opt/google" "$pd/usr/bin" "$pd/usr/share"
			cp -a "$W/ch/opt/google/chrome" "$pd/opt/google/chrome"
			[ -d "$W/ch/usr/share/applications" ] && \
				cp -a "$W/ch/usr/share/applications" "$pd/usr/share/"
			[ -d "$W/ch/usr/share/icons" ] && cp -a "$W/ch/usr/share/icons" "$pd/usr/share/"
			cat >"$pd/usr/bin/google-chrome" <<'SH'
#!/bin/sh
# Google's own build, launched from /opt/google/chrome.
exec /opt/google/chrome/chrome "$@"
SH
			chmod 755 "$pd/usr/bin/google-chrome"
			ln -sf google-chrome "$pd/usr/bin/chrome"
			emit "$pd" google-chrome "$ver" base \
				"Google Chrome (upstream build)" "Google-Chrome-ToS" \
				"https://www.google.com/chrome/" \
				"glibc gtk3 libx11 libxcb alsa-lib nss dbus fontconfig"
		else bad "chrome (deb did not contain opt/google/chrome)"; fi
	else bad "chrome (download failed)"; fi
else
	ok "chrome already packaged"
fi

sh "$TREE/scraps/scraps-repo" gen "$R/base" "$ARCH" >/dev/null 2>&1 || :
printf '\n  base now has %s binaries\n' \
	"$(ls -1 "$R/base/$ARCH"/*.spz 2>/dev/null | wc -l | tr -d ' ')"
