#!/bin/sh
# Arctic Linux - package the components built by build-rootfs.sh into .alpmz
# binaries and lay out the repositories.
#
# Everything here was genuinely compiled from source by build-rootfs.sh. The
# install steps are re-run into a per-package DESTDIR, which costs nothing
# because the objects are already built.
set -u

# Refuse to run outside the sandbox. Arctic's glibc installs to /usr/lib by
# design, so a recipe that forgets DESTDIR would overwrite the host's libc and
# take the machine down - which is exactly what happened once. Run through
# arctic-sandbox, where the host filesystem is read-only.
if [ "${ARCTIC_SANDBOX:-0}" != "1" ]; then
	echo "$(basename "$0"): refusing to build outside the sandbox." >&2
	echo "  run it as:  arctic/build/arctic-sandbox $0 $*" >&2
	echo "  (set ARCTIC_SANDBOX=1 only if you know the host is protected)" >&2
	exit 1
fi

B=/home/apiwo/arctic-build
W=$B/work
R=$B/stage/rootfs
DEPS=$B/stage/deps
SRCTREE=/home/apiwo/arctic
REPO=$B/repo
PKGDIRS=$B/stage/pkgs
J=$(nproc)
ARCH=x86_64
DATE=$(date '+%s')
SRC_EXTRA=$B/src

mkdir -p "$PKGDIRS" "$REPO"
for r in main extra base kernels nonfree alt-nonfree multilib; do
	mkdir -p "$REPO/$r/$ARCH"
done

step() { printf '\n\033[1;36m:: %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mok\033[0m %s\n' "$*"; }
bad()  { printf '   \033[31mfail\033[0m %s\n' "$*"; }

# Write a .PKGINFO and roll the tarball. $1=pkgdir $2=name $3=ver $4=repo
# $5=desc $6=license $7=url $8=deps
emit() {
	pd=$1 name=$2 ver=$3 repo=$4 desc=$5 lic=$6 url=$7 deps=$8
	[ -d "$pd" ] || { bad "$name: nothing staged"; return 1; }
	isize=$(du -sk "$pd" 2>/dev/null | cut -f1); isize=$(( ${isize:-0} * 1024 ))

	{
		printf '# Arctic Linux package, built %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
		printf 'format = 2\nname = %s\nversion = %s\nrelease = 1\narch = %s\n' \
			"$name" "$ver" "$ARCH"
		printf 'desc = %s\nurl = %s\nlicense = %s\n' "$desc" "$url" "$lic"
		printf 'isize = %s\nbuilddate = %s\nbuilder = mkpkgs.sh\nrepo = %s\n' \
			"$isize" "$DATE" "$repo"
		for d in $deps; do printf 'depend = %s\n' "$d"; done
	} >"$pd/.PKGINFO"

	( cd "$pd" && find . -type f -o -type l ) | sed 's|^\.||' \
		| grep -v '^/\.\(PKGINFO\|FILES\|INSTALL\)$' | sort >"$pd/.FILES"

	out="$REPO/$repo/$ARCH/$name-$ver-1.$ARCH.alpmz"
	( cd "$pd" && tar -cf - . | xz -T0 -6 >"$out" ) || { bad "$name: tar failed"; return 1; }
	ok "$(basename "$out") ($(du -h "$out" | cut -f1), $(wc -l <"$pd/.FILES") files)"
}

# Re-run an autotools/cmake install into a fresh DESTDIR. $1=name $2=builddir
reinstall() {
	name=$1 bdir=$2
	pd=$PKGDIRS/$name
	rm -rf "$pd"; mkdir -p "$pd"
	[ -d "$bdir" ] || { bad "$name: no build dir $bdir"; return 1; }
	( cd "$bdir" && make DESTDIR="$pd" install ) >"$B/logs/pkg-$name.log" 2>&1 \
		|| { bad "$name: install failed (see logs/pkg-$name.log)"; return 1; }
	printf '%s' "$pd"
}

# ------------------------------------------------------------------ main repo
step "packaging glibc"
if pd=$(reinstall glibc "$W/glibc-build"); then
	# glibc ships ldd(1) as a #!/bin/bash script, and Arctic has no bash - it
	# simply cannot run. arctic-base provides a POSIX ldd instead, so drop
	# glibc's copy rather than leaving a broken tool and a file conflict.
	rm -f "$pd/usr/bin/ldd"
	emit "$pd" glibc 2.44 main "The GNU C library" "LGPL-2.1-or-later" \
		"https://www.gnu.org/software/libc/" "linux-headers"
fi

step "packaging the compression libraries"
if pd=$(reinstall zlib "$W/zlib-1.3.1"); then
	emit "$pd" zlib 1.3.1 main "Compression library" "Zlib" "https://zlib.net/" "glibc"
fi
if pd=$(reinstall xz "$W/xz-5.8.3"); then
	emit "$pd" xz 5.8.3 main "liblzma and the xz tools" "0BSD" \
		"https://tukaani.org/xz/" "glibc"
fi
pd=$PKGDIRS/zstd; rm -rf "$pd"; mkdir -p "$pd"
if ( cd "$W/zstd-1.5.7" && make PREFIX=/usr HAVE_LZ4=0 HAVE_LZMA=0 DESTDIR="$pd" install ) \
	>"$B/logs/pkg-zstd.log" 2>&1; then
	emit "$pd" zstd 1.5.7 main "Fast real-time compression" "BSD-3-Clause" \
		"https://facebook.github.io/zstd/" "glibc zlib"
else bad zstd; fi
if pd=$(reinstall libmd "$W/libmd-1.1.0"); then
	emit "$pd" libmd 1.1.0 main "BSD message digest functions" "BSD-3-Clause" \
		"https://www.hadrons.org/software/libmd/" "glibc"
fi
if pd=$(reinstall libxcrypt "$W/libxcrypt-4.5.2"); then
	emit "$pd" libxcrypt 4.5.2 main "crypt(), which glibc no longer provides" \
		"LGPL-2.1-or-later" "https://github.com/besser82/libxcrypt" "glibc"
fi

step "packaging netbsd-curses"
pd=$PKGDIRS/netbsd-curses; rm -rf "$pd"; mkdir -p "$pd"
if ( cd "$W/netbsd-curses-0.3.2" && \
     make PREFIX=/usr DESTDIR="$pd" install-dynamic ) \
     >"$B/logs/pkg-curses.log" 2>&1; then
	# The ncurses compatibility names, same as the rootfs gets.
	ln -sf libcurses.so   "$pd/usr/lib/libncurses.so"
	ln -sf libcurses.so   "$pd/usr/lib/libncursesw.so"
	ln -sf libterminfo.so "$pd/usr/lib/libtinfo.so"
	ln -sf libterminfo.so "$pd/usr/lib/libtermcap.so"
	emit "$pd" netbsd-curses 0.3.2 main \
		"NetBSD curses, a BSD-licensed replacement for ncurses" "BSD-3-Clause" \
		"https://github.com/sabotage-linux/netbsd-curses" "glibc"
else bad netbsd-curses; fi

step "packaging busybox"
pd=$PKGDIRS/busybox; rm -rf "$pd"; mkdir -p "$pd/usr/bin" "$pd/usr/lib/arctic" "$pd/usr/share/busybox"
install -Dm755 "$W/busybox-1.38.0/busybox" "$pd/usr/bin/busybox"
[ -f "$B/stage/busybox.static" ] && \
	install -Dm755 "$B/stage/busybox.static" "$pd/usr/lib/arctic/busybox.static"
install -Dm644 "$W/busybox-1.38.0/.config" "$pd/usr/share/busybox/config"
# Only the applets Arctic wants from busybox; toybox owns the rest.
for a in init getty mdev sh ash login su passwd chpasswd adduser addgroup \
	deluser delgroup mount umount swapon swapoff mkswap fsck blkid findfs \
	mountpoint losetup switch_root pivot_root udhcpc ip ifconfig route ping \
	wget modprobe insmod rmmod lsmod depmod sysctl hwclock killall5 \
	start-stop-daemon syslogd klogd crond reboot halt poweroff setfont \
	loadkmap vi less; do
	ln -sf busybox "$pd/usr/bin/$a"
done
emit "$pd" busybox 1.38.0 main "Init, getty, device manager and network tools" \
	"GPL-2.0-only" "https://busybox.net/" "glibc"

step "packaging toybox"
pd=$PKGDIRS/toybox; rm -rf "$pd"; mkdir -p "$pd/usr/bin"
install -Dm755 "$W/toybox-0.8.14/toybox" "$pd/usr/bin/toybox"
# Whatever busybox already claimed, plus the tools glibc itself installs.
# Overlapping names are a hard conflict at install time, so the two multiplexers
# must not both link the same applet.
BB_CLAIMED=$(ls "$PKGDIRS/busybox/usr/bin" 2>/dev/null | tr '\n' ' ')
GLIBC_CLAIMED="getconf getent ldd locale localedef iconv gencat catchsegv sprof"
CURSES_CLAIMED="reset clear tput tic toe infocmp captoinfo"
"$R/usr/bin/toybox" 2>/dev/null | tr ' ' '\n' | \
while read -r a; do
	[ -n "$a" ] || continue
	case "$a" in toybox) continue ;; esac
	case " $BB_CLAIMED " in *" $a "*) continue ;; esac
	case " $GLIBC_CLAIMED " in *" $a "*) continue ;; esac
	case " $CURSES_CLAIMED " in *" $a "*) continue ;; esac
	ln -sf toybox "$pd/usr/bin/$a"
done
emit "$pd" toybox 0.8.14 main "The classic Unix commands, 0BSD licensed" \
	"0BSD" "https://landley.net/toybox/" "glibc"

step "packaging zsh"
if pd=$(reinstall zsh "$W/zsh-5.9.2"); then
	mkdir -p "$pd/etc"
	printf '/bin/zsh\n/usr/bin/zsh\n' >"$pd/etc/shells"
	emit "$pd" zsh 5.9.2 main "The Z shell, Arctic's login shell" \
		"MIT-Modern-Variant" "https://www.zsh.org/" "glibc netbsd-curses"
fi

step "packaging doas"
DOASDIR=$(ls -d "$W"/OpenDoas-* 2>/dev/null | head -1)
if [ -n "$DOASDIR" ] && pd=$(reinstall doas "$DOASDIR"); then
	chmod 4755 "$pd/usr/bin/doas" 2>/dev/null || :
	mkdir -p "$pd/etc"
	printf '# Arctic Linux - doas rules\npermit persist :wheel\npermit nopass :wheel cmd alpm args fetch all\n' \
		>"$pd/etc/doas.conf"
	chmod 400 "$pd/etc/doas.conf"
	emit "$pd" doas 6.8.2 main "Execute commands as another user" "ISC" \
		"https://github.com/Duncaen/OpenDoas" "glibc libxcrypt"
fi

step "packaging libarchive"
pd=$PKGDIRS/libarchive; rm -rf "$pd"; mkdir -p "$pd"
if ( cd "$W/libarchive-build" && make DESTDIR="$pd" install ) \
	>"$B/logs/pkg-libarchive.log" 2>&1; then
	emit "$pd" libarchive 3.8.9 main "Archive library, provides bsdtar" \
		"BSD-2-Clause" "https://libarchive.org/" "glibc zlib xz zstd libmd"
else bad libarchive; fi

step "packaging mandoc"
if pd=$(reinstall mandoc "$W/mandoc-1.14.6"); then
	ln -sf mandoc "$pd/usr/bin/man" 2>/dev/null || :
	emit "$pd" mandoc 1.14.6 main "Manual reader, replacing man-db and groff" \
		"ISC" "https://mandoc.bsd.lv/" "glibc zlib"
fi

step "packaging the one true awk"
pd=$PKGDIRS/onetrueawk; rm -rf "$pd"; mkdir -p "$pd/usr/bin" "$pd/usr/share/man/man1"
AWKDIR=$(ls -d "$W"/awk-* 2>/dev/null | head -1)
if [ -n "$AWKDIR" ]; then
	cp -f "$AWKDIR/a.out" "$pd/usr/bin/awk" 2>/dev/null || \
		cp -f "$AWKDIR/awk" "$pd/usr/bin/awk"
	chmod 755 "$pd/usr/bin/awk"
	ln -sf awk "$pd/usr/bin/nawk"
	[ -f "$AWKDIR/awk.1" ] && cp -f "$AWKDIR/awk.1" "$pd/usr/share/man/man1/awk.1"
	emit "$pd" onetrueawk 20260426 main "The one true awk" "MIT" \
		"https://github.com/onetrueawk/awk" "glibc"
fi

step "packaging byacc and bmake"
BYDIR=$(ls -d "$W"/byacc-* 2>/dev/null | head -1)
if [ -n "$BYDIR" ] && pd=$(reinstall byacc "$BYDIR"); then
	emit "$pd" byacc 20260426 main "Berkeley yacc, replacing bison" \
		"Public-Domain" "https://invisible-island.net/byacc/" "glibc"
fi
pd=$PKGDIRS/bmake; rm -rf "$pd"; mkdir -p "$pd"
if ( cd "$W/bmake-obj" && "$W/bmake/boot-strap" --prefix=/usr \
     --install-destdir="$pd" op=install ) >"$B/logs/pkg-bmake.log" 2>&1; then
	[ -f "$pd/usr/bin/bmake" ] && ln -sf bmake "$pd/usr/bin/make"
	emit "$pd" bmake 20260714 main "The BSD make, replacing GNU make" \
		"BSD-3-Clause" "https://www.crufty.net/help/sjg/bmake.html" "glibc"
else bad bmake; fi

step "packaging limine"
pd=$PKGDIRS/limine; rm -rf "$pd"; mkdir -p "$pd/usr/bin" "$pd/usr/share/limine"
cp -f "$R/usr/bin/limine" "$pd/usr/bin/limine" 2>/dev/null || :
cp -f "$R"/usr/share/limine/* "$pd/usr/share/limine/" 2>/dev/null || :
emit "$pd" limine 12.5.2 main "The Arctic bootloader, BIOS and UEFI" \
	"BSD-2-Clause" "https://limine-bootloader.org/" "glibc"

# --------------------------------------------------------------- arctic's own
step "packaging alpm"
pd=$PKGDIRS/alpm; rm -rf "$pd"
mkdir -p "$pd/usr/bin" "$pd/usr/lib/alpm" "$pd/etc/alpm/repos.d"
install -Dm755 "$SRCTREE/alpm/alpm"       "$pd/usr/bin/alpm"
install -Dm755 "$SRCTREE/alpm/alpm-build" "$pd/usr/bin/alpm-build"
install -Dm755 "$SRCTREE/alpm/alpm-repo"  "$pd/usr/bin/alpm-repo"
install -Dm644 "$SRCTREE/alpm/libalpm.sh" "$pd/usr/lib/alpm/libalpm.sh"
install -Dm644 "$SRCTREE/skel/etc/alpm/alpm.conf" "$pd/etc/alpm/alpm.conf"
cp -f "$SRCTREE/skel/etc/alpm/repos.d/"*.repo "$pd/etc/alpm/repos.d/"
emit "$pd" alpm 1.0.0 main "Arctic Linux Package Manager" "BSD-2-Clause" \
	"https://github.com/apiwo/arctic-linux" "busybox"

step "packaging arctic-base"
pd=$PKGDIRS/arctic-base; rm -rf "$pd"; mkdir -p "$pd/usr/share/arctic" "$pd/var/lib/arctic"
cp -a "$SRCTREE/skel/etc" "$pd/etc"
# The whole skel/usr tree, not just bin/ - mkiso already does this for the
# live image (cp -a skel/usr/. ), and a file placed anywhere else under
# skel/usr (skel/usr/share/udhcpc/default.script, for one) was silently
# absent from every real install while still being on the ISO.
cp -a "$SRCTREE/skel/usr/." "$pd/usr/"
rm -rf "$pd/etc/alpm"   # alpm owns those files
chmod +x "$pd/etc/rc.boot" "$pd/etc/rc.shutdown" "$pd/etc/rc.d"/* "$pd/usr/bin"/*
# git only tracks the executable bit, not full permission modes, so a fresh
# checkout of skel/etc/shadow comes out at whatever the umask gives regular
# files (typically 644) regardless of what it's chmod'd to on disk right now.
# Every real install went out with world-readable password hashes until this
# matched the chmod mkiso already does for the live image.
chmod 600 "$pd/etc/shadow"
for d in ascii limine plasma wallpaper icons sddm misc; do
	[ -d "$SRCTREE/branding/$d" ] && cp -a "$SRCTREE/branding/$d" "$pd/usr/share/arctic/"
done
install -Dm755 "$SRCTREE/installer/arctic-install"      "$pd/usr/bin/arctic-install"
install -Dm755 "$SRCTREE/installer/arctic-boot-strap" "$pd/usr/bin/arctic-boot-strap"
install -Dm755 "$SRCTREE/installer/arctic-chroot"     "$pd/usr/bin/arctic-chroot"
install -Dm644 "$SRCTREE/installer/lib/tui.sh"        "$pd/usr/lib/arctic/tui.sh"
emit "$pd" arctic-base 1.0.0 main \
	"Arctic base configuration, init scripts and branding" "BSD-2-Clause" \
	"https://github.com/apiwo/arctic-linux" "busybox toybox zsh doas alpm libxcrypt"

# --------------------------------------------- the tools that make it installable
step "packaging util-linux (cfdisk, sfdisk, wipefs, lsblk)"
pd=$PKGDIRS/util-linux; rm -rf "$pd"; mkdir -p "$pd/usr/bin" "$pd/usr/lib"
n=0
for t in cfdisk sfdisk fdisk wipefs lsblk blkid findmnt partx; do
	[ -f "$R/usr/bin/$t" ] && { cp -a "$R/usr/bin/$t" "$pd/usr/bin/"; n=$((n+1)); }
done
for base in libblkid libmount libuuid libsmartcols libfdisk; do
	cp -a "$R/usr/lib/$base.so"* "$pd/usr/lib/" 2>/dev/null || :
done
if [ "$n" -gt 4 ]; then
	emit "$pd" util-linux 2.41.5 main \
		"Partitioning and block device tools: cfdisk, sfdisk, wipefs, lsblk" \
		"GPL-2.0-or-later LGPL-2.1-or-later" \
		"https://github.com/util-linux/util-linux" "glibc"
else bad "util-linux (only $n tools)"; fi

step "packaging e2fsprogs"
pd=$PKGDIRS/e2fsprogs; rm -rf "$pd"; mkdir -p "$pd/usr/bin" "$pd/usr/lib"
n=0
for t in mke2fs mkfs.ext2 mkfs.ext3 mkfs.ext4 e2fsck fsck.ext2 fsck.ext3 \
         fsck.ext4 resize2fs tune2fs dumpe2fs badblocks e2label; do
	[ -e "$R/usr/bin/$t" ] && { cp -a "$R/usr/bin/$t" "$pd/usr/bin/"; n=$((n+1)); }
done
for base in libext2fs libe2p libcom_err libss; do
	cp -a "$R/usr/lib/$base.so"* "$pd/usr/lib/" 2>/dev/null || :
done
if [ "$n" -gt 5 ]; then
	emit "$pd" e2fsprogs 1.47.4 main "ext2/3/4 filesystem tools, a real mkfs.ext4" \
		"GPL-2.0-only" "https://e2fsprogs.sourceforge.net/" "glibc util-linux"
else bad "e2fsprogs (only $n tools)"; fi

step "packaging dosfstools"
pd=$PKGDIRS/dosfstools; rm -rf "$pd"; mkdir -p "$pd/usr/bin"
n=0
for t in mkfs.fat mkfs.vfat mkfs.msdos mkdosfs fsck.fat fsck.vfat fatlabel; do
	[ -e "$R/usr/bin/$t" ] && { cp -a "$R/usr/bin/$t" "$pd/usr/bin/"; n=$((n+1)); }
done
if [ "$n" -gt 2 ]; then
	emit "$pd" dosfstools 4.2 main "FAT filesystem tools, for the EFI partition" \
		"GPL-3.0-or-later" "https://github.com/dosfstools/dosfstools" "glibc"
else bad "dosfstools (only $n tools)"; fi

# libnl and wpa_supplicant are NOT packaged from $R here, on purpose: they
# are real ports now (ports/main/libnl, ports/main/wpa_supplicant), built
# through the ordinary alpm-build/build-batch.sh pipeline like everything
# else in main/extra/base. That build is the full-featured one
# (wpa_supplicant with D-Bus control interface + EAP/802.1X, which
# NetworkManager actually needs) - packaging $R's copy here instead would
# silently overwrite it in the shared repo with the deliberately stripped
# WPA2-Personal-only, no-D-Bus build build-usable.sh made for the live
# image specifically, breaking NetworkManager's own wifi backend on every
# real install. $R still gets its own copies staged directly (see
# build-usable.sh) for the live/installer image's own squashfs - they just
# don't also get published as the "main" repo's package of the same name.
# ell is no longer hand-built into $R at all - iwd was its only consumer on
# the live image, and bluez (its other consumer) builds ell through the
# ordinary ports/main/ell recipe instead when it needs it.

step "packaging linux-firmware (wireless)"
pd=$PKGDIRS/linux-firmware; rm -rf "$pd"; mkdir -p "$pd/usr/lib"
if [ -d "$R/usr/lib/firmware" ]; then
	cp -a "$R/usr/lib/firmware" "$pd/usr/lib/"
	emit "$pd" linux-firmware 20260622 kernels \
		"Wireless and device firmware" "various-redistributable" \
		"https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git" "-"
else bad "linux-firmware (not installed)"; fi

# ------------------------------------------ the GNU pieces the NVIDIA blob needs
step "packaging gcc-libs (libstdc++ and libgcc_s, for the NVIDIA driver)"
pd=$PKGDIRS/gcc-libs; rm -rf "$pd"; mkdir -p "$pd/usr/lib"
gl=0
for f in "$R"/usr/lib/libstdc++.so.6* "$R"/usr/lib/libgcc_s.so.1; do
	[ -e "$f" ] || continue
	cp -a "$f" "$pd/usr/lib/" && gl=$((gl+1))
done
for f in "$pd"/usr/lib/libstdc++.so.6.* "$pd"/usr/lib/libgcc_s.so.1; do
	[ -f "$f" ] && strip --strip-unneeded "$f" 2>/dev/null || :
done
if [ "$gl" -gt 0 ]; then
	emit "$pd" gcc-libs 15.3.0 main \
		"libstdc++ and libgcc_s runtime, required by the NVIDIA driver" \
		"GPL-3.0-or-later WITH GCC-exception-3.1" "https://gcc.gnu.org/" "glibc"
else bad "gcc-libs (not built yet)"; fi

step "packaging gmake"
pd=$PKGDIRS/gmake; rm -rf "$pd"; mkdir -p "$pd/usr/bin"
if [ -x "$R/usr/bin/gmake" ]; then
	cp -a "$R/usr/bin/gmake" "$pd/usr/bin/gmake"
	# Deliberately not installed as /usr/bin/make: bmake owns that name.
	emit "$pd" gmake 4.4.1 main \
		"GNU make as gmake, for kernel modules; /usr/bin/make is still bmake" \
		"GPL-3.0-or-later" "https://www.gnu.org/software/make/" "glibc"
else bad "gmake (not built yet)"; fi

step "packaging libglvnd"
pd=$PKGDIRS/libglvnd; rm -rf "$pd"; mkdir -p "$pd/usr/lib"
gv=0
for f in "$R"/usr/lib/libGLdispatch.so* "$R"/usr/lib/libEGL.so* \
         "$R"/usr/lib/libGLESv2.so* "$R"/usr/lib/libOpenGL.so*; do
	[ -e "$f" ] || continue
	cp -a "$f" "$pd/usr/lib/" && gv=$((gv+1))
done
if [ "$gv" -gt 0 ]; then
	emit "$pd" libglvnd 1.7.0 main \
		"GL vendor dispatch, so mesa and NVIDIA can both provide GL" "MIT" \
		"https://gitlab.freedesktop.org/glvnd/libglvnd" "glibc"
else bad "libglvnd (not built yet)"; fi

# ------------------------------------------------------- data-only packages
step "packaging tzdata"
pd=$PKGDIRS/tzdata; rm -rf "$pd"; mkdir -p "$pd/usr/share/zoneinfo" "$pd/etc"
if [ -f "$SRC_EXTRA/tzdata.tar.gz" ]; then
	rm -rf "$W/tzdata"; mkdir -p "$W/tzdata"
	tar -xf "$SRC_EXTRA/tzdata.tar.gz" -C "$W/tzdata"
	# zic output is TZif data: architecture independent, so the host zic is fine.
	( cd "$W/tzdata" && for z in africa antarctica asia australasia europe \
	    northamerica southamerica etcetera backward factory; do
		[ -f "$z" ] && zic -d "$pd/usr/share/zoneinfo" "$z"
	  done
	  zic -d "$pd/usr/share/zoneinfo/posix" -p America/New_York 2>/dev/null || :
	) >"$B/logs/pkg-tzdata.log" 2>&1
	cp -f "$W/tzdata/zone.tab" "$pd/usr/share/zoneinfo/zone.tab" 2>/dev/null || :
	cp -f "$W/tzdata/zone1970.tab" "$pd/usr/share/zoneinfo/zone1970.tab" 2>/dev/null || :
	cp -f "$W/tzdata/iso3166.tab" "$pd/usr/share/zoneinfo/iso3166.tab" 2>/dev/null || :
	ln -sf /usr/share/zoneinfo/UTC "$pd/etc/localtime"
	n=$(find "$pd/usr/share/zoneinfo" -type f | wc -l)
	if [ "$n" -gt 100 ]; then
		emit "$pd" tzdata 2026b main "Time zone database" "Public-Domain" \
			"https://www.iana.org/time-zones" "-"
	else bad "tzdata (only $n zones compiled)"; fi
else bad "tzdata (source missing)"; fi

step "packaging ca-certificates"
pd=$PKGDIRS/ca-certificates; rm -rf "$pd"
mkdir -p "$pd/etc/ssl/certs" "$pd/usr/share/ca-certificates"
if [ -f "$SRC_EXTRA/cacert.pem" ]; then
	cp -f "$SRC_EXTRA/cacert.pem" "$pd/usr/share/ca-certificates/cacert.pem"
	ln -sf /usr/share/ca-certificates/cacert.pem "$pd/etc/ssl/certs/ca-certificates.crt"
	ln -sf /usr/share/ca-certificates/cacert.pem "$pd/etc/ssl/cert.pem"
	emit "$pd" ca-certificates 20260601 main \
		"Trusted certificate authority bundle" "MPL-2.0" \
		"https://curl.se/docs/caextract.html" "-"
else bad "ca-certificates (bundle missing)"; fi

step "packaging iana-etc"
# /etc/services and /etc/protocols. Generated from the IANA registries when they
# are reachable, otherwise from the host's copies, which come from the same data.
pd=$PKGDIRS/iana-etc; rm -rf "$pd"; mkdir -p "$pd/etc"
if [ -f /etc/services ] && [ -f /etc/protocols ]; then
	cp -f /etc/services  "$pd/etc/services"
	cp -f /etc/protocols "$pd/etc/protocols"
	emit "$pd" iana-etc 20260601 main "/etc/services and /etc/protocols" "MIT" \
		"https://www.iana.org/" "-"
else bad "iana-etc (no source data)"; fi

step "packaging the meta packages"
# These carry no files of their own; the dependency list is the payload. They
# exist because the installer and other packages name them.
meta_pkg() {
	name=$1 deps=$2 desc=$3
	pd=$PKGDIRS/$name
	rm -rf "$pd"; mkdir -p "$pd/usr/share/arctic/meta"
	printf '%s\n' "$deps" >"$pd/usr/share/arctic/meta/$name"
	emit "$pd" "$name" 1.0.0 main "$desc" "BSD-2-Clause" \
		"https://github.com/apiwo/arctic-linux" "$deps"
}
meta_pkg arctic-init "busybox arctic-base" \
	"Arctic init scripts and the service manager"
meta_pkg base \
	"glibc busybox toybox zsh doas alpm arctic-base arctic-init libarchive mandoc onetrueawk libxcrypt" \
	"A minimal but complete Arctic system"
meta_pkg base-devel "llvm bmake byacc pkgconf cmake ninja meson git" \
	"The toolchain needed to build Arctic packages"

# ------------------------------------------------------------------- kernels
step "packaging arctic-base-kernel"
pd=$PKGDIRS/arctic-base-kernel; rm -rf "$pd"; mkdir -p "$pd/boot" "$pd/usr/lib/modules"
cp -a "$B/stage/kernel-base/boot/." "$pd/boot/"
cp -a "$B/stage/kernel-base/lib/modules/." "$pd/usr/lib/modules/"
KREL=$(ls "$B/stage/kernel-base/lib/modules" | head -1)
rm -f "$pd/usr/lib/modules/$KREL/build" "$pd/usr/lib/modules/$KREL/source"
emit "$pd" arctic-base-kernel 7.1.3 kernels \
	"Arctic Linux kernel, broad hardware support" "GPL-2.0-only" \
	"https://kernel.org/" "glibc"

step "packaging arctic-kernel"
if [ -d "$B/stage/kernel-zen/boot" ]; then
	pd=$PKGDIRS/arctic-kernel; rm -rf "$pd"; mkdir -p "$pd/boot" "$pd/usr/lib/modules"
	cp -a "$B/stage/kernel-zen/boot/." "$pd/boot/"
	cp -a "$B/stage/kernel-zen/lib/modules/." "$pd/usr/lib/modules/"
	KREL=$(ls "$B/stage/kernel-zen/lib/modules" | head -1)
	rm -f "$pd/usr/lib/modules/$KREL/build" "$pd/usr/lib/modules/$KREL/source"
	emit "$pd" arctic-kernel 6.12.100 kernels \
		"ZEN patchset on the 6.12 LTS line - PDS/BMQ, ACS override, ntsync, vhba" \
		"GPL-2.0-only" "https://github.com/apiwo/arctic-kernel" "glibc"
else
	echo "   (skipped - $B/stage/kernel-zen not built)"
fi

step "packaging linux-headers"
pd=$PKGDIRS/linux-headers; rm -rf "$pd"; mkdir -p "$pd/usr"
if ( cd "$W/linux-7.1.3" && make headers_install INSTALL_HDR_PATH="$pd/usr" ) \
	>"$B/logs/pkg-headers.log" 2>&1; then
	emit "$pd" linux-headers 7.1.3 kernels "Kernel headers for userspace" \
		"GPL-2.0-only WITH Linux-syscall-note" "https://kernel.org/" "-"
else bad linux-headers; fi

# ------------------------------------------------------- index the binary repos
step "generating repository indexes"
export ALPM_ROOT=/ ALPM_COLOR=never
for r in main extra base kernels nonfree alt-nonfree multilib; do
	c=$(ls -1 "$REPO/$r/$ARCH"/*.alpmz 2>/dev/null | wc -l | tr -d ' ')
	if [ "$c" = "0" ]; then
		# An empty repo still needs a valid index so 'alpm fetch' succeeds.
		{
			printf '# Arctic Linux %s repository index\n' "$r"
			printf '# format\t2\n# generated\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
			printf '# fields\tname version release arch dlsize isize sha256 deps desc\n'
		} >"$REPO/$r/$ARCH/INDEX"
		printf '   %-14s (no binaries yet, empty index written)\n' "$r"
		continue
	fi
	sh "$SRCTREE/alpm/alpm-repo" gen "$REPO/$r" "$ARCH" >/dev/null 2>&1 \
		&& printf '   %-14s %s packages indexed\n' "$r" "$c" \
		|| bad "indexing $r"
done

printf '\n\033[1;36m=== REPOSITORIES ===\033[0m\n'
for r in main extra base kernels nonfree alt-nonfree multilib; do
	c=$(grep -vc '^#' "$REPO/$r/$ARCH/INDEX" 2>/dev/null || echo 0)
	s=$(du -sh "$REPO/$r" 2>/dev/null | cut -f1)
	printf '%-14s %5s packages  %s\n' "$r" "$c" "$s"
done
printf '\ntotal: %s\n' "$(du -sh "$REPO" | cut -f1)"
printf '=== PACKAGING DONE ===\n'
