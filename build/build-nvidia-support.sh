#!/bin/sh
# ScrapLinux - the pieces the NVIDIA proprietary driver needs.
#
# WHY THESE ARE HERE
#   ScrapLinux's rule is "no GNU except glibc". Reading the actual NVIDIA driver
#   shipped on this machine shows that rule cannot hold if the proprietary
#   driver is to work:
#
#     libnvidia-api.so.1     needs libstdc++.so.6
#     libnvidia-rtcore.so    needs libgcc_s.so.1     (OptiX / RT cores)
#
#   Both come from GCC. There is no substitute: libc++ is not ABI-compatible
#   with libstdc++, and these are prebuilt blobs that cannot be relinked. The
#   kernel module is a second case - Linux's kbuild is written against GNU make
#   and bmake cannot drive it.
#
#   So ScrapLinux ships three GNU runtime pieces, and nothing more:
#     gcc-libs   libstdc++.so.6 and libgcc_s.so.1, runtime only, no compiler
#     gmake      GNU make, installed as gmake; /usr/bin/make is still bmake
#     (glibc, which was always there)
#
#   The userland stays BSD: toybox, busybox, zsh, doas, bmake, byacc, mandoc,
#   netbsd-curses are all unchanged. Only the C++ runtime and a build tool are
#   added, and only because a binary blob demands them.
set -u

if [ "${SCRAPLINUX_SANDBOX:-0}" != "1" ]; then
	echo "refusing to build outside the sandbox - use scraplinux/build/scraplinux-sandbox" >&2
	exit 1
fi

B=/home/apiwo/scraplinux-build
SRC=$B/src
W=$B/work
R=$B/stage/rootfs
DEPS=$B/stage/deps
L=$B/logs
J=$(nproc)

step() { printf '\n\033[1;36m:: %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mok\033[0m %s\n' "$*"; }
bad()  { printf '   \033[31mFAILED\033[0m %s\n' "$*"; }

# ------------------------------------------------------------------ GNU make
step "building GNU make 4.4.1 (kbuild needs it; /usr/bin/make stays bmake)"
if [ ! -x "$R/usr/bin/gmake" ]; then
	[ -d "$W/make-4.4.1" ] || tar -xf "$SRC/make-4.4.1.tar.gz" -C "$W"
	( cd "$W/make-4.4.1" && \
	  ./configure --prefix=/usr --program-prefix=g --disable-nls && \
	  make -j"$J" && make DESTDIR="$R" install \
	) >"$L/gmake.log" 2>&1 && {
		# Do not let it become /usr/bin/make: bmake owns that name on ScrapLinux.
		rm -f "$R/usr/bin/make.gnu"
		ok "gmake"
	} || bad "gmake (see logs/gmake.log)"
else
	ok "gmake already built"
fi

# ------------------------------------------------------------------ gcc-libs
step "building libstdc++ and libgcc_s (GCC 15.3.0 runtime, for NVIDIA)"
if [ ! -f "$R/usr/lib/libstdc++.so.6" ]; then
	[ -d "$W/gcc-15.3.0" ] || tar -xf "$SRC/gcc-15.3.0.tar.xz" -C "$W"
	( cd "$W/gcc-15.3.0" && ./contrib/download_prerequisites ) \
		>"$L/gcc-prereq.log" 2>&1 || bad "gcc prerequisites (gmp/mpfr/mpc)"
	rm -rf "$W/gcc-build"; mkdir -p "$W/gcc-build"
	( cd "$W/gcc-build" && \
	  ../gcc-15.3.0/configure \
		--prefix=/usr \
		--libdir=/usr/lib \
		--disable-bootstrap \
		--enable-languages=c,c++ \
		--disable-multilib \
		--disable-nls \
		--disable-libstdcxx-pch \
		--enable-shared \
		--enable-threads=posix \
		--enable-__cxa_atexit \
		--enable-clocale=gnu \
	  && make -j"$J" \
	) >"$L/gcc.log" 2>&1 || bad "gcc (see logs/gcc.log)"

	# Install only the two runtime libraries. ScrapLinux does not ship the compiler:
	# clang is the toolchain, and these exist purely so the NVIDIA blobs resolve.
	if [ -d "$W/gcc-build" ]; then
		found=0
		for lib in $(find "$W/gcc-build" -name 'libstdc++.so.6.*' -o -name 'libgcc_s.so.1' 2>/dev/null); do
			base=$(basename "$lib")
			cp -f "$lib" "$R/usr/lib/$base" && found=$((found+1))
		done
		# The sonames NVIDIA actually links against.
		so=$(ls "$R/usr/lib"/libstdc++.so.6.* 2>/dev/null | head -1)
		[ -n "$so" ] && ln -sf "$(basename "$so")" "$R/usr/lib/libstdc++.so.6"
		[ -f "$R/usr/lib/libgcc_s.so.1" ] && ln -sf libgcc_s.so.1 "$R/usr/lib/libgcc_s.so"
		if [ -f "$R/usr/lib/libstdc++.so.6" ] && [ -f "$R/usr/lib/libgcc_s.so.1" ]; then
			ok "gcc-libs: libstdc++.so.6 + libgcc_s.so.1 ($found files)"
		else
			bad "gcc-libs (libraries not produced)"
		fi
	fi
else
	ok "gcc-libs already built"
fi

# ------------------------------------------------------------------ libglvnd
step "building libglvnd 1.7.0 (lets mesa and NVIDIA provide GL side by side)"
if [ ! -f "$R/usr/lib/libGLdispatch.so.0" ]; then
	d=$(ls -d "$W"/libglvnd-* 2>/dev/null | head -1)
	[ -n "$d" ] || { tar -xf "$SRC/libglvnd-1.7.0.tar.gz" -C "$W"; d=$(ls -d "$W"/libglvnd-* | head -1); }
	if [ -n "$d" ]; then
		( cd "$d" && \
		  meson setup build --prefix=/usr --libdir=/usr/lib --buildtype=release \
			-Dx11=disabled -Dglx=disabled -Degl=true -Dgles1=false -Dgles2=true \
		  && ninja -C build -j"$J" \
		  && DESTDIR="$R" ninja -C build install \
		) >"$L/glvnd.log" 2>&1 && ok "libglvnd" || bad "libglvnd (see logs/glvnd.log)"
	fi
else
	ok "libglvnd already built"
fi

printf '\n\033[1;36m=== NVIDIA SUPPORT SUMMARY ===\033[0m\n'
for f in usr/bin/gmake usr/lib/libstdc++.so.6 usr/lib/libgcc_s.so.1 \
         usr/lib/libGLdispatch.so.0; do
	if [ -e "$R/$f" ]; then printf '  present  %s\n' "$f"
	else printf '  MISSING  %s\n' "$f"; fi
done
