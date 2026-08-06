#!/bin/sh
# Arctic Linux - stage 1: build the userland from source into a root filesystem.
#
# Layout is merged-/usr: everything real lives under /usr/bin and /usr/lib,
# and /bin /sbin /lib /lib64 /usr/sbin are symlinks.
#
# A note on the toolchain. Arctic ships LLVM: clang, lld, libc++. But glibc
# itself cannot be compiled by clang - upstream requires GCC - so GCC is used
# here as a stage-0 bootstrap tool only. It is not installed into the image and
# no GNU userland is shipped: coreutils duties go to toybox (0BSD) and busybox,
# awk is the one true awk, make is bmake, yacc is byacc, man is mandoc, and the
# terminal library is netbsd-curses. glibc is the only GNU component present.
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
SRC=$B/src
W=$B/work
R=$B/stage/rootfs
L=$B/logs
J=$(nproc)
KVER=7.1.3
KREL=7.1.3-arctic-base

mkdir -p "$W" "$R" "$L"

FAILED=""
step() { printf '\n\033[1;36m:: %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mok\033[0m %s\n' "$*"; }
softfail() { printf '   \033[31mFAILED\033[0m %s\n' "$*"; FAILED="$FAILED $1"; }
hardfail() { printf '   \033[31mFATAL\033[0m %s\n' "$*"; exit 1; }

unpack() {
	d=$1 tarball=$2
	[ -d "$W/$d" ] && return 0
	tar -xf "$SRC/$tarball" -C "$W" || return 1
}

# ------------------------------------------------------------- 0. skeleton tree
step "creating the filesystem skeleton"
for d in usr/bin usr/lib usr/include usr/share usr/local etc dev proc sys run \
	tmp var home root boot opt srv mnt media \
	var/log var/cache var/lib var/tmp var/empty \
	etc/alpm/repos.d etc/rc.d etc/arctic/services etc/skel \
	var/lib/alpm/local var/lib/alpm/sync var/lib/arctic var/cache/alpm/pkg
do
	mkdir -p "$R/$d"
done
# The merged-/usr symlinks. Everything else in Arctic assumes these exist.
for l in bin sbin lib lib64; do
	[ -e "$R/$l" ] || ln -sfn "usr/${l#s}" "$R/$l"
done
ln -sfn "usr/bin" "$R/sbin" 2>/dev/null
ln -sfn "usr/lib" "$R/lib" 2>/dev/null
ln -sfn "usr/lib" "$R/lib64" 2>/dev/null

# /usr/sbin -> bin, the last of the merged-/usr symlinks.
#
# This one needs care that the others do not. By the time this runs,
# /usr/sbin may already be a real directory with binaries in it, because
# packages install there. `ln -sfn bin /usr/sbin` against a real directory
# does not replace it - it creates /usr/sbin/bin -> bin *inside* it, a
# symlink pointing at itself, and leaves /usr/sbin unmerged. That is
# exactly what was in the shipped image.
#
# So: move anything already there into /usr/bin first, then replace the
# empty directory with the symlink.
if [ -d "$R/usr/sbin" ] && [ ! -L "$R/usr/sbin" ]; then
	rm -f "$R/usr/sbin/bin" 2>/dev/null || :
	for f in "$R/usr/sbin"/* "$R/usr/sbin"/.[!.]*; do
		[ -e "$f" ] || continue
		mv -f "$f" "$R/usr/bin/" 2>/dev/null || :
	done
	rmdir "$R/usr/sbin" 2>/dev/null || :
fi
[ -e "$R/usr/sbin" ] || ln -sfn "bin" "$R/usr/sbin"

# /var/run -> ../run and /var/lock -> ../run/lock.
#
# These are not cosmetic. dbus listens on /run/dbus/system_bus_socket, but
# ell - the library bluez is built on - looks for the system bus under
# /var/run/dbus. With /var/run missing, anything built on ell cannot reach a
# bus that is running perfectly well and reports "Failed to initialize
# D-Bus", which reads like a dbus fault and is not one. Anything else still
# using the older path finds it too.
rm -rf "$R/var/run" "$R/var/lock" 2>/dev/null || :
ln -sfn "../run" "$R/var/run"
ln -sfn "../run/lock" "$R/var/lock"
chmod 1777 "$R/tmp" "$R/var/tmp"
chmod 0700 "$R/root"
chmod 0555 "$R/var/empty"

# A handful of real device nodes in the image itself. devtmpfs normally provides
# these, but if anything mounts this filesystem without one, PID 1 still needs
# /dev/console to report what went wrong.
mknod -m 600 "$R/dev/console" c 5 1 2>/dev/null || :
mknod -m 666 "$R/dev/null"    c 1 3 2>/dev/null || :
mknod -m 666 "$R/dev/zero"    c 1 5 2>/dev/null || :
mknod -m 666 "$R/dev/tty"     c 5 0 2>/dev/null || :
mknod -m 666 "$R/dev/random"  c 1 8 2>/dev/null || :
mknod -m 666 "$R/dev/urandom" c 1 9 2>/dev/null || :
mkdir -p "$R/dev/pts" "$R/dev/shm"
ln -sfn /proc/self/fd    "$R/dev/fd"     2>/dev/null || :
ln -sfn /proc/self/fd/0  "$R/dev/stdin"  2>/dev/null || :
ln -sfn /proc/self/fd/1  "$R/dev/stdout" 2>/dev/null || :
ln -sfn /proc/self/fd/2  "$R/dev/stderr" 2>/dev/null || :
ok "tree"

# ---------------------------------------------------- 1. kernel headers + glibc
step "installing kernel headers ($KVER)"
if [ ! -f "$R/usr/include/linux/version.h" ]; then
	( cd "$W/linux-$KVER" && make headers_install INSTALL_HDR_PATH="$R/usr" ) \
		>"$L/headers.log" 2>&1 || hardfail "kernel headers (see $L/headers.log)"
fi
ok "linux headers"

step "building glibc 2.44"
if [ ! -f "$R/usr/lib/libc.so.6" ]; then
	unpack glibc-2.44 glibc-2.44.tar.xz || hardfail "cannot unpack glibc"
	rm -rf "$W/glibc-build"; mkdir -p "$W/glibc-build"
	# configparms puts the runtime loader and the "sbin" programs where a
	# merged-/usr system expects them.
	cat >"$W/glibc-build/configparms" <<'EOF'
slibdir=/usr/lib
rtlddir=/usr/lib
sbindir=/usr/bin
rootsbindir=/usr/bin
EOF
	( cd "$W/glibc-build" && \
	  ../glibc-2.44/configure \
		--prefix=/usr \
		--libdir=/usr/lib \
		--libexecdir=/usr/lib/glibc \
		--enable-kernel=5.15 \
		--enable-stack-protector=strong \
		--enable-bind-now \
		--disable-nscd \
		--disable-werror \
		--without-selinux \
		--with-headers="$R/usr/include" \
	  && make -j"$J" \
	  && make DESTDIR="$R" install \
	) >"$L/glibc.log" 2>&1 || hardfail "glibc (see $L/glibc.log)"
	# glibc's install skips these two directories.
	mkdir -p "$R/usr/lib/locale" "$R/etc"
	ok "glibc installed"
else
	ok "glibc already built"
fi

# ---------------------------------------------------- helpers for the rest of stage 1
#
# Linking model, and the mistake worth not repeating: this is a NATIVE build, so
# every compiler here is the host's. The host glibc (2.43) is older than the one
# we just built (2.44), and glibc is forward compatible, so host-linked binaries
# run correctly on the target. What must never happen is pointing the host
# linker at $R/usr/lib - it then tries to link host objects against the target
# libc and fails with "file in wrong format". So: no -L into $R, ever.
#
# Libraries we build ourselves and then need to link against go into their own
# staging prefix under $B/stage/deps, which contains no libc. That directory is
# safe to put on -L.
export CFLAGS="-O2 -pipe -fstack-protector-strong"
export CXXFLAGS="$CFLAGS"
unset CPPFLAGS LDFLAGS

DEPS=$B/stage/deps
mkdir -p "$DEPS/usr/lib" "$DEPS/usr/include"
DEP_CPP="-I$DEPS/usr/include"
DEP_LD="-L$DEPS/usr/lib"

# Target binaries carry PT_INTERP=/usr/lib/ld-linux-x86-64.so.2, which does not
# exist on a Gentoo host. Run them through the loader we built instead.
LOADER="$R/usr/lib/ld-linux-x86-64.so.2"
tgt() { "$LOADER" --library-path "$R/usr/lib:$DEPS/usr/lib" "$@"; }

step "generating locales"
if [ -x "$R/usr/bin/localedef" ] && [ -x "$LOADER" ]; then
	for loc in C.UTF-8 en_US.UTF-8; do
		base=${loc%%.*}; cs=${loc#*.}
		I18N="$W/glibc-2.44/localedata"
		( cd "$I18N" && \
		  I18NPATH="$I18N" tgt "$R/usr/bin/localedef" \
			--prefix="$R" --no-archive \
			-i "locales/$base" -f "charmaps/$cs" "$loc" \
		) >>"$L/locale.log" 2>&1 && ok "$loc" || softfail "locale-$loc"
	done
	printf 'C.UTF-8 UTF-8\nen_US.UTF-8 UTF-8\n' >"$R/etc/locale.gen"
else
	softfail localedef
fi

# ------------------------------------------- 2. compression libraries (0BSD/BSD)
# libarchive needs these, and Arctic wants them anyway: liblzma is public domain,
# zlib and zstd are BSD-style. None of them are GNU.
step "building zlib 1.3.1"
if [ ! -f "$DEPS/usr/lib/libz.so" ]; then
	unpack zlib-1.3.1 zlib-1.3.1.tar.gz || softfail zlib-unpack
	if [ -d "$W/zlib-1.3.1" ]; then
		( cd "$W/zlib-1.3.1" && ./configure --prefix=/usr && make -j"$J" \
		  && make DESTDIR="$DEPS" install && make DESTDIR="$R" install \
		) >"$L/zlib.log" 2>&1 && ok "zlib" || softfail zlib
	fi
else
	ok "zlib already built"
fi

step "building xz 5.8.3 (liblzma, so .alpmz packages can be read)"
if [ ! -f "$DEPS/usr/lib/liblzma.so" ]; then
	unpack xz-5.8.3 xz-5.8.3.tar.gz || softfail xz-unpack
	if [ -d "$W/xz-5.8.3" ]; then
		( cd "$W/xz-5.8.3" && \
		  ./configure --prefix=/usr --disable-static --disable-nls --disable-doc \
		  && make -j"$J" \
		  && make DESTDIR="$DEPS" install && make DESTDIR="$R" install \
		) >"$L/xz.log" 2>&1 && ok "xz + liblzma" || softfail xz
	fi
else
	ok "xz already built"
fi

step "building zstd 1.5.7"
if [ ! -f "$DEPS/usr/lib/libzstd.so" ]; then
	unpack zstd-1.5.7 zstd-1.5.7.tar.gz || softfail zstd-unpack
	if [ -d "$W/zstd-1.5.7" ]; then
		( cd "$W/zstd-1.5.7" && \
		  make -j"$J" PREFIX=/usr HAVE_LZ4=0 HAVE_LZMA=0 \
		  && make PREFIX=/usr HAVE_LZ4=0 HAVE_LZMA=0 DESTDIR="$DEPS" install \
		  && make PREFIX=/usr HAVE_LZ4=0 HAVE_LZMA=0 DESTDIR="$R" install \
		) >"$L/zstd.log" 2>&1 && ok "zstd" || softfail zstd
	fi
else
	ok "zstd already built"
fi

# ----------------------------------------------------------------------- libmd
# libarchive wants a message-digest library. BSD's libmd is the natural fit for
# Arctic, and building it keeps libarchive from linking the host's copy.
step "building libmd 1.1.0 (BSD message digests)"
if [ ! -f "$DEPS/usr/lib/libmd.so" ]; then
	unpack libmd-1.1.0 libmd-1.1.0.tar.xz || softfail libmd-unpack
	if [ -d "$W/libmd-1.1.0" ]; then
		( cd "$W/libmd-1.1.0" && \
		  ./configure --prefix=/usr --libdir=/usr/lib --disable-static \
		  && make -j"$J" \
		  && make DESTDIR="$DEPS" install && make DESTDIR="$R" install \
		) >"$L/libmd.log" 2>&1 && ok "libmd" || softfail libmd
	fi
else
	ok "libmd already built"
fi

# ------------------------------------------------------------------ 3. libxcrypt
# glibc 2.44 no longer ships libcrypt, but crypt() is how doas and login check a
# password. Without this, nobody can log in. libxcrypt is the maintained
# replacement and supports the modern yescrypt and bcrypt hashes.
step "building libxcrypt 4.5.2 (crypt(), which glibc no longer provides)"
if [ ! -f "$DEPS/usr/lib/libcrypt.so" ]; then
	unpack libxcrypt-4.5.2 libxcrypt-4.5.2.tar.xz || softfail libxcrypt-unpack
	if [ -d "$W/libxcrypt-4.5.2" ]; then
		( cd "$W/libxcrypt-4.5.2" && \
		  ./configure --prefix=/usr --libdir=/usr/lib \
			--disable-static --disable-xcrypt-compat-files \
			--disable-werror \
			--enable-hashes=strong,glibc \
			--disable-obsolete-api \
		  && make -j"$J" \
		  && make DESTDIR="$DEPS" install && make DESTDIR="$R" install \
		) >"$L/libxcrypt.log" 2>&1 && ok "libxcrypt" || softfail libxcrypt
	fi
else
	ok "libxcrypt already built"
fi

# ------------------------------------------------------------- 4. netbsd-curses
step "building netbsd-curses (the BSD terminal library, replacing ncurses)"
if [ ! -f "$DEPS/usr/lib/libcurses.so" ]; then
	unpack netbsd-curses-0.3.2 netbsd-curses-0.3.2.tar.gz || softfail curses-unpack
	if [ -d "$W/netbsd-curses-0.3.2" ]; then
		( cd "$W/netbsd-curses-0.3.2" && \
		  make -j"$J" PREFIX=/usr all-dynamic && \
		  make PREFIX=/usr DESTDIR="$DEPS" install-dynamic && \
		  make PREFIX=/usr DESTDIR="$R" install-dynamic \
		) >"$L/curses.log" 2>&1 && ok "netbsd-curses" || softfail netbsd-curses
		# Anything that asks for -lncurses gets netbsd-curses instead. Note
		# that libterminfo.so is a real library here, not an alias: it holds
		# the ti_* symbols libcurses.so itself depends on.
		#
		# libtinfow.so (the wide-char name) has to be here too, not just
		# libtinfo.so: autoconf's tinfo probe (UL_TINFO_CHECK, used by
		# util-linux and others) tries "-ltinfow" before "-ltinfo", and
		# without this symlink that search finds nothing under $DEPS and
		# falls through to the build host's real libtinfow.so instead -
		# which Arctic does not ship, so the resulting binary fails on the
		# target with "libtinfow.so.6: cannot open shared object file".
		for base in "$DEPS" "$R"; do
			[ -f "$base/usr/lib/libcurses.so" ] || continue
			ln -sf libcurses.so   "$base/usr/lib/libncurses.so"
			ln -sf libcurses.so   "$base/usr/lib/libncursesw.so"
			ln -sf libterminfo.so "$base/usr/lib/libtinfo.so"
			ln -sf libterminfo.so "$base/usr/lib/libtinfow.so"
			ln -sf libterminfo.so "$base/usr/lib/libtermcap.so"
			# The unversioned names above are what satisfy -ltinfow at link
			# time, but that did not stop dmesg (and others) from recording
			# a *versioned* NEEDED entry - libtinfow.so.6 - in the built
			# binary anyway, presumably because the sandboxed build still
			# found the host's own real, versioned ncurses ahead of these
			# symlinks for that particular package. Whatever the exact
			# reason, the fix that actually holds regardless of it is
			# shipping the versioned names too, so the binary that already
			# exists finds what it is actually asking for.
			ln -sf libcurses.so   "$base/usr/lib/libncurses.so.6"
			ln -sf libcurses.so   "$base/usr/lib/libncursesw.so.6"
			ln -sf libterminfo.so "$base/usr/lib/libtinfo.so.6"
			ln -sf libterminfo.so "$base/usr/lib/libtinfow.so.6"
			# Packages written against GNU ncurses probe for headers under an
			# "ncursesw/" subdirectory before falling back to a flat ncurses.h.
			# netbsd-curses has no such subdirectory, so that probe walks past
			# $DEPS/usr/include entirely and picks up the build host's real
			# ncursesw headers instead - compiled against those, then linked
			# against netbsd-curses above, a binary like cfdisk ends up wanting
			# a literal `acs_map` symbol (how GNU ncurses.h declares it) when
			# netbsd-curses only exports it as `_acs_char`, aliased to
			# `acs_map` by a #define that never gets seen because the wrong
			# header won. Shimming the subdirectory closes that gap.
			mkdir -p "$base/usr/include/ncursesw"
			for hdr in curses.h ncurses.h term.h unctrl.h; do
				[ -f "$base/usr/include/$hdr" ] || continue
				ln -sf "../$hdr" "$base/usr/include/ncursesw/$hdr"
			done
			# Same story one layer down, for pkg-config instead of the C
			# preprocessor: netbsd-curses' own install names this file
			# terminfo.pc, but UL_TINFO_CHECK (util-linux and others) asks
			# pkg-config for "tinfow" and then "tinfo" - neither of which
			# exists under $DEPS, so the query falls through to the build
			# host's real tinfo/tinfow.pc and quietly pulls in host paths.
			# The content doesn't need to differ, pkg-config just matches on
			# the filename, so an alias is enough.
			if [ -f "$base/usr/lib/pkgconfig/terminfo.pc" ]; then
				ln -sf terminfo.pc "$base/usr/lib/pkgconfig/tinfo.pc"
				ln -sf terminfo.pc "$base/usr/lib/pkgconfig/tinfow.pc"
			fi
		done
	fi
else
	ok "netbsd-curses already built"
fi

# ------------------------------------------------------------------ 3. busybox
step "building busybox 1.38.0 (init, getty, mdev, networking)"
if [ ! -x "$R/usr/bin/busybox" ]; then
	unpack busybox-1.38.0 busybox-1.38.0.tar.bz2 || hardfail "cannot unpack busybox"
	( cd "$W/busybox-1.38.0"
	  make defconfig >/dev/null 2>&1
	  # Trim applets that either clash with toybox's BSD userland or no longer
	  # compile against current kernel headers.
	  for off in TC FSCK_MINIX MKFS_MINIX INETD RPM RPM2CPIO DPKG DPKG_DEB \
	             LINUX_MODULE_LOADER_BUILTIN SELINUX; do
		sed -i "s/^CONFIG_$off=y/# CONFIG_$off is not set/" .config
	  done
	  # Applets Arctic actively relies on.
	  for on in INIT INIT_TERMINAL_TYPE FEATURE_USE_INITTAB GETTY MDEV \
	            FEATURE_MDEV_CONF FEATURE_MDEV_EXEC FEATURE_MDEV_LOAD_FIRMWARE \
	            ASH ASH_INTERNAL_GLOB SH_IS_ASH MOUNT UMOUNT SWAPON SWAPOFF \
	            UDHCPC IP IFCONFIG ROUTE PING WGET MODPROBE INSMOD RMMOD LSMOD \
	            DEPMOD SYSCTL HWCLOCK KILLALL5 START_STOP_DAEMON SYSLOGD KLOGD \
	            ADDUSER ADDGROUP DELUSER DELGROUP PASSWD CHPASSWD SU LOGIN \
	            MKSWAP FSCK BLKID FINDFS MOUNTPOINT SETFONT LOADKMAP REBOOT \
	            HALT POWEROFF SWITCH_ROOT PIVOT_ROOT LOSETUP UNZIP TAR GZIP \
	            BUNZIP2 UNXZ XZ VI LESS FEATURE_LESS_MAXLINES; do
		if grep -q "^# CONFIG_$on is not set" .config; then
			sed -i "s/^# CONFIG_$on is not set/CONFIG_$on=y/" .config
		fi
	  done
	  sed -i 's/^CONFIG_STATIC=y/# CONFIG_STATIC is not set/' .config
	  sed -i 's|^CONFIG_PREFIX=.*|CONFIG_PREFIX="'"$R"'"|' .config
	  yes "" | make oldconfig >/dev/null 2>&1
	  make -j"$J" CFLAGS_EXTRA="-Wno-error"
	) >"$L/busybox.log" 2>&1 || hardfail "busybox (see $L/busybox.log)"

	# Install by hand: busybox's own installer wants to make /bin symlinks,
	# but /bin is already a symlink to usr/bin here.
	cp -f "$W/busybox-1.38.0/busybox" "$R/usr/bin/busybox"
	chmod 755 "$R/usr/bin/busybox"
	tgt "$R/usr/bin/busybox" --list 2>/dev/null | while read -r a; do
		[ "$a" = "busybox" ] && continue
		[ -e "$R/usr/bin/$a" ] || ln -sf busybox "$R/usr/bin/$a"
	done
	ok "busybox + $(tgt "$R/usr/bin/busybox" --list | wc -l) applets"

	# A static busybox for the initramfs, where nothing else exists yet.
	( cd "$W/busybox-1.38.0"
	  cp .config .config.dyn
	  sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
	  yes "" | make oldconfig >/dev/null 2>&1
	  make -j"$J" CFLAGS_EXTRA="-Wno-error"
	  cp busybox "$B/stage/busybox.static"
	  cp .config.dyn .config
	) >>"$L/busybox.log" 2>&1 && ok "static busybox for the initramfs" \
		|| softfail busybox-static
else
	ok "busybox already built"
fi

# ------------------------------------------------------------------- 4. toybox
step "building toybox 0.8.14 (the BSD-licensed userland)"
if [ ! -x "$R/usr/bin/toybox" ]; then
	unpack toybox-0.8.14 toybox-0.8.14.tar.gz || softfail toybox-unpack
	if [ -d "$W/toybox-0.8.14" ]; then
		( cd "$W/toybox-0.8.14"
		  make defconfig >/dev/null 2>&1
		  # su, login and mkpasswd are the only applets that need crypt(), and
		  # busybox already owns those three on Arctic. Dropping them here means
		  # toybox needs no libcrypt and can link statically.
		  for off in SU LOGIN MKPASSWD; do
			sed -i "s/^CONFIG_$off=y/# CONFIG_$off is not set/" .config
		  done
		  yes "" | make oldconfig >/dev/null 2>&1
		  # Statically linked on purpose. toybox is designed for it, and it makes
		  # the core userland independent of the dynamic loader - so a broken
		  # /usr/lib can still be repaired with ls, cp and mv.
		  make -j"$J" CFLAGS="$CFLAGS -Wno-error" LDFLAGS="--static" toybox
		) >"$L/toybox.log" 2>&1 && {
			cp -f "$W/toybox-0.8.14/toybox" "$R/usr/bin/toybox"
			chmod 755 "$R/usr/bin/toybox"
			# toybox wins for the classic Unix tools; busybox keeps init and
			# the network stack. Where both provide an applet, toybox is linked
			# only if busybox has not already claimed the name as a real file.
			# Only link toybox for names busybox and glibc have not already
			# taken - two providers of one path is a package conflict later.
			GLIBC_CLAIMED="getconf getent ldd locale localedef iconv gencat sprof"
			"$R/usr/bin/toybox" 2>/dev/null | tr ' ' '\n' | \
			  while read -r a; do
				[ -n "$a" ] || continue
				[ "$a" = toybox ] && continue
				case " $GLIBC_CLAIMED " in *" $a "*) continue ;; esac
				# busybox already owns this name if it is a symlink to busybox.
				if [ -L "$R/usr/bin/$a" ] && \
				   [ "$(readlink "$R/usr/bin/$a")" = busybox ]; then
					case "$a" in
					init|sh|ash|getty|mdev|login|su|passwd|blkid|mount|umount|\
					fsck|swapon|swapoff|mkswap|findfs|mountpoint|losetup|ip|\
					ifconfig|route|ping|wget|modprobe|insmod|rmmod|lsmod|depmod|\
					sysctl|hwclock|reboot|halt|poweroff|vi|less|syslogd|crond)
						continue ;;
					esac
				fi
				ln -sf toybox "$R/usr/bin/$a" 2>/dev/null || :
			  done
			ok "toybox + $(tgt "$R/usr/bin/toybox" | wc -w) commands"
		} || softfail toybox
	fi
else
	ok "toybox already built"
fi

# util-linux is built with --disable-more, so toybox's own applet is
# supposed to be what /usr/bin/more actually is - but a stale standalone
# more binary from an older build of this script (from before that flag
# existed) was found still sitting there, silently shadowing the symlink
# and shipping with a dangling libmagic.so.1 dependency that made it fail
# to start at all. Nothing in Arctic is meant to provide a real, separate
# more binary; reassert the symlink unconditionally so this cannot recur
# regardless of what an earlier build left behind.
[ -x "$R/usr/bin/toybox" ] && ln -sf toybox "$R/usr/bin/more" 2>/dev/null || :

# --------------------------------------------------------------------- 5. zsh
step "building zsh 5.9.2 (the Arctic login shell)"
if [ ! -x "$R/usr/bin/zsh" ]; then
	unpack zsh-5.9.2 zsh-5.9.2.tar.xz || softfail zsh-unpack
	if [ -d "$W/zsh-5.9.2" ]; then
		( cd "$W/zsh-5.9.2" && \
		  CPPFLAGS="$DEP_CPP" LDFLAGS="$DEP_LD" \
		  ac_cv_header_ncursesw_term_h=no \
		  ac_cv_header_ncurses_term_h=no \
		  ac_cv_header_ncursesw_ncurses_h=no \
		  ac_cv_header_ncurses_ncurses_h=no \
		  ac_cv_header_ncurses_h=no \
		  ac_cv_header_termcap_h=no \
		  ./configure --prefix=/usr --sysconfdir=/etc \
			--with-term-lib="curses terminfo" \
			--enable-multibyte --enable-etcdir=/etc/zsh \
			--enable-fndir=/usr/share/zsh/functions \
			--enable-site-fndir=/usr/local/share/zsh/site-functions \
			--with-tcsetpgrp --disable-gdbm --disable-pcre \
		  && make -j"$J" \
		  && make DESTDIR="$R" install \
		) >"$L/zsh.log" 2>&1 && ok "zsh" || softfail zsh
	fi
else
	ok "zsh already built"
fi

# -------------------------------------------------------------------- 6. doas
step "building opendoas 6.8.2 (privilege escalation, no sudo)"
if [ ! -x "$R/usr/bin/doas" ]; then
	unpack OpenDoas-6.8.2 opendoas-6.8.2.tar.gz || softfail doas-unpack
	d=$(ls -d "$W"/OpenDoas-* 2>/dev/null | head -1)
	if [ -n "$d" ]; then
		( cd "$d" && ./configure --prefix=/usr --sysconfdir=/etc --without-pam \
		  && make -j"$J" \
		  && make DESTDIR="$R" install \
		) >"$L/doas.log" 2>&1 && {
			# doas is useless without the setuid bit.
			chmod 4755 "$R/usr/bin/doas" 2>/dev/null || :
			ok "doas"
		} || softfail doas
	fi
else
	ok "doas already built"
fi

# -------------------------------------------------------------- 7. libarchive
step "building libarchive 3.8.9 (bsdtar, the .alpmz reader)"
if [ ! -x "$R/usr/bin/bsdtar" ]; then
	unpack libarchive-3.8.9 libarchive-3.8.9.tar.gz || softfail libarchive-unpack
	if [ -d "$W/libarchive-3.8.9" ]; then
		rm -rf "$W/libarchive-build"; mkdir -p "$W/libarchive-build"
		( cd "$W/libarchive-build" && \
		  cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release \
			-DENABLE_TEST=OFF -DENABLE_OPENSSL=OFF -DENABLE_ICONV=OFF \
			-DENABLE_BZip2=OFF -DENABLE_LZ4=OFF -DENABLE_LZO=OFF \
			-DENABLE_LIBB2=OFF -DENABLE_EXPAT=OFF -DENABLE_LIBXML2=OFF \
			-DENABLE_ACL=OFF -DENABLE_XATTR=OFF -DENABLE_CNG=OFF \
			-DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF -DENABLE_PCREPOSIX=OFF \
			-DCMAKE_INSTALL_LIBDIR=lib \
			-DCMAKE_PREFIX_PATH="$DEPS/usr" \
			-DCMAKE_INCLUDE_PATH="$DEPS/usr/include" \
			-DCMAKE_LIBRARY_PATH="$DEPS/usr/lib" \
			"$W/libarchive-3.8.9" \
		  && make -j"$J" \
		  && make DESTDIR="$R" install \
		) >"$L/libarchive.log" 2>&1 && ok "libarchive + bsdtar" || softfail libarchive
	fi
else
	ok "libarchive already built"
fi

# ------------------------------------------------------------------ 8. mandoc
step "building mandoc 1.14.6 (man, replacing man-db)"
if [ ! -x "$R/usr/bin/mandoc" ]; then
	unpack mandoc-1.14.6 mandoc-1.14.6.tar.gz || softfail mandoc-unpack
	if [ -d "$W/mandoc-1.14.6" ]; then
		( cd "$W/mandoc-1.14.6"
		  cat >configure.local <<EOF
PREFIX=/usr
MANDIR=/usr/share/man
BINDIR=/usr/bin
SBINDIR=/usr/bin
CFLAGS="$CFLAGS"
EOF
		  ./configure && make -j"$J" && make DESTDIR="$R" install
		) >"$L/mandoc.log" 2>&1 && {
			ln -sf mandoc "$R/usr/bin/man" 2>/dev/null || :
			ok "mandoc"
		} || softfail mandoc
	fi
else
	ok "mandoc already built"
fi

# --------------------------------------------------------- 9. awk, byacc, bmake
step "building the one true awk"
if [ ! -x "$R/usr/bin/awk" ] || [ -L "$R/usr/bin/awk" ]; then
	unpack "awk-20260426" onetrueawk-20260426.tar.gz || softfail awk-unpack
	d=$(ls -d "$W"/awk-* 2>/dev/null | head -1)
	if [ -n "$d" ]; then
		( cd "$d" && make -j1 CC="cc $CFLAGS" ) >"$L/awk.log" 2>&1 && {
			rm -f "$R/usr/bin/awk"
			cp -f "$d/a.out" "$R/usr/bin/awk" 2>/dev/null || \
				cp -f "$d/awk" "$R/usr/bin/awk"
			chmod 755 "$R/usr/bin/awk"
			ok "one true awk"
		} || softfail awk
	fi
fi

step "building byacc"
if [ ! -x "$R/usr/bin/yacc" ]; then
	unpack byacc-20260426 byacc.tar.gz || :
	d=$(ls -d "$W"/byacc-* 2>/dev/null | head -1)
	if [ -n "$d" ]; then
		( cd "$d" && ./configure --prefix=/usr --program-prefix= \
		  && make -j"$J" && make DESTDIR="$R" install \
		) >"$L/byacc.log" 2>&1 && ok "byacc" || softfail byacc
	fi
fi

step "building bmake (the BSD make, replacing GNU make)"
if [ ! -x "$R/usr/bin/bmake" ]; then
	unpack bmake bmake-20260714.tar.gz || :
	if [ -d "$W/bmake" ]; then
		rm -rf "$W/bmake-obj"; mkdir -p "$W/bmake-obj"
		( cd "$W/bmake-obj" && \
		  "$W/bmake/boot-strap" --prefix=/usr op=build \
		  && "$W/bmake/boot-strap" --prefix=/usr --install-destdir="$R" op=install \
		) >"$L/bmake.log" 2>&1 && ok "bmake" || softfail bmake
	fi
fi

# ------------------------------------------------------------- 10. limine tool
step "building the limine host tool"
if [ -d "$SRC/limine-binary" ]; then
	mkdir -p "$R/usr/share/limine"
	cp -f "$SRC/limine-binary"/*.EFI "$R/usr/share/limine/" 2>/dev/null || :
	cp -f "$SRC/limine-binary"/limine-bios.sys "$R/usr/share/limine/" 2>/dev/null || :
	cp -f "$SRC/limine-binary"/limine-bios-cd.bin "$R/usr/share/limine/" 2>/dev/null || :
	cp -f "$SRC/limine-binary"/limine-uefi-cd.bin "$R/usr/share/limine/" 2>/dev/null || :
	cp -f "$SRC/limine-binary"/limine-bios-hdd.h "$R/usr/share/limine/" 2>/dev/null || :
	( cd "$SRC/limine-binary" && cc -O2 -o "$R/usr/bin/limine" limine.c 2>/dev/null ) \
		&& ok "limine tool + boot binaries" || {
		# Some releases need the bundled header on the include path.
		( cd "$SRC/limine-binary" && cc -O2 -I. -o "$R/usr/bin/limine" limine.c ) \
			>"$L/limine.log" 2>&1 && ok "limine tool" || softfail limine-tool
	}
else
	softfail limine-missing
fi

# ------------------------------------------------------------------- 11. kernel
step "installing the kernel and modules"
if [ -d "$B/stage/kernel-base" ]; then
	cp -a "$B/stage/kernel-base/boot/." "$R/boot/"
	mkdir -p "$R/usr/lib/modules"
	cp -a "$B/stage/kernel-base/lib/modules/." "$R/usr/lib/modules/"
	ok "kernel $KREL + modules"
else
	softfail kernel-missing
fi

# -------------------------------------------------------------------- 12. strip
step "stripping binaries"
find "$R/usr/bin" "$R/usr/lib" -type f 2>/dev/null | while read -r f; do
	case "$(dd if="$f" bs=4 count=1 2>/dev/null | od -An -c | tr -d ' \n')" in
	*ELF*) strip --strip-unneeded "$f" 2>/dev/null || : ;;
	esac
done
ok "stripped"

step "running ldconfig inside the image"
mkdir -p "$R/etc"
printf '/usr/lib\n/usr/local/lib\n' >"$R/etc/ld.so.conf"
if ldconfig -r "$R" 2>/dev/null; then
	ok "ld.so.cache"
elif [ -x "$R/usr/bin/ldconfig" ]; then
	tgt "$R/usr/bin/ldconfig" -r "$R" 2>/dev/null && ok "ld.so.cache" || softfail ldconfig
else
	softfail ldconfig
fi

printf '\n\033[1;36m=== ROOTFS SUMMARY ===\033[0m\n'
printf 'size:      %s\n' "$(du -sh "$R" | cut -f1)"
printf 'binaries:  %s\n' "$(find "$R/usr/bin" -maxdepth 1 | wc -l)"
printf 'libraries: %s\n' "$(find "$R/usr/lib" -maxdepth 1 -name '*.so*' | wc -l)"
if [ -n "$FAILED" ]; then
	printf '\033[31mfailed:\033[0m%s\n' "$FAILED"
	printf 'logs are in %s\n' "$L"
else
	printf '\033[32mall components built\033[0m\n'
fi
printf '=== ROOTFS DONE ===\n'
