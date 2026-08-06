#!/bin/sh
# Arctic Linux - system startup
# Run by busybox init as sysinit. Keep it readable: this is the file people
# open first when something will not boot.
# shellcheck shell=sh disable=SC2039

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

. /etc/arctic/rc.lib 2>/dev/null || {
	# rc.lib is what prints the pretty status lines. Without it, stay silent
	# but keep booting.
	begin() { printf ' * %s\n' "$*"; }
	good()  { :; }
	bad()   { printf '   failed: %s\n' "$*"; }
}

QUIET=0
case " $(cat /proc/cmdline 2>/dev/null) " in
*" quiet "*|*" arctic.splash "*) QUIET=1 ;;
esac

banner

# --------------------------------------------------------------- pseudo filesystems
begin "mounting kernel filesystems"
mountpoint -q /proc || mount -t proc     -o nosuid,noexec,nodev proc  /proc
mountpoint -q /sys  || mount -t sysfs    -o nosuid,noexec,nodev sys   /sys
mountpoint -q /run  || mount -t tmpfs    -o nosuid,nodev,mode=755 run /run
mountpoint -q /dev  || mount -t devtmpfs -o nosuid,mode=755 dev /dev
mkdir -p /dev/pts /dev/shm /run/lock /run/arctic
mountpoint -q /dev/pts || mount -t devpts -o nosuid,noexec,gid=5,mode=620 devpts /dev/pts
mountpoint -q /dev/shm || mount -t tmpfs  -o nosuid,nodev,mode=1777 shm /dev/shm
[ -d /sys/kernel/security ] && mount -t securityfs securityfs /sys/kernel/security 2>/dev/null
[ -d /sys/firmware/efi ] && mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null
good

# --------------------------------------------------------------------- the log
# rc_log() appends to a file that survives the boot, so a service that fails
# leaves a trace instead of vanishing into /dev/null. Appends only - not a
# tee through a fifo, which blocks until something opens the other end and
# can hang sysinit before anything has started.
RC_LOG=/run/arctic/boot.log
export RC_LOG
mkdir -p /run/arctic 2>/dev/null || :
: >"$RC_LOG" 2>/dev/null || RC_LOG=/dev/null
rc_log() { printf '%s\n' "$*" >>"$RC_LOG" 2>/dev/null || :; }
export -n RC_LOG 2>/dev/null || :
rc_log "=== Arctic boot $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) ==="
rc_log "kernel: $(uname -r 2>/dev/null)"

# ------------------------------------------------------------------------ devices
begin "starting the device manager"
# Arctic uses busybox mdev with libudev-zero, so there is no systemd-derived
# udev in the base system. eudev is available in extra for anyone who wants it.
if [ -x /sbin/udevd ] && [ -f /etc/arctic/services/udev ]; then
	/sbin/udevd --daemon 2>/dev/null
	udevadm trigger --action=add --type=subsystems 2>/dev/null
	udevadm trigger --action=add --type=devices 2>/dev/null
	udevadm settle --timeout=30 2>/dev/null
else
	printf '/sbin/mdev\n' >/proc/sys/kernel/hotplug
	mdev -s
	[ -x /sbin/mdev ] && mdev -df & 2>/dev/null
fi
good

begin "applying sysctl defaults"
[ -f /etc/sysctl.conf ] && sysctl -p /etc/sysctl.conf >/dev/null 2>&1
good

begin "loading kernel modules"
for f in /etc/modules-load.d/*.conf; do
	[ -f "$f" ] || continue
	while read -r m; do
		case "$m" in ''|\#*) continue ;; esac
		modprobe "$m" 2>/dev/null || :
	done <"$f"
done
good

# --------------------------------------------------------------------- filesystems
begin "checking filesystems"
if [ -f /forcefsck ] || grep -q ' forcefsck' /proc/cmdline 2>/dev/null; then
	fsck -A -T -a 2>/dev/null; rm -f /forcefsck
else
	# Only drop to a repair shell when there is a console to type at. During
	# sysinit stdin is not a terminal, so this would otherwise read EOF and
	# fall straight through - or worse, block the whole boot before any
	# service has started, with nothing on screen explaining why.
	fsck -A -T -a -P 2>/dev/null || {
		rc_log "fsck reported errors"
		bad "fsck wants attention"
		if [ -t 0 ] && [ -c /dev/console ]; then
			printf '\n  Dropping to a repair shell. Run fsck, then exit to continue.\n\n'
			sh </dev/console >/dev/console 2>&1
		else
			printf '  continuing; run fsck by hand once booted\n'
		fi
	}
fi
good

begin "remounting the root filesystem read-write"
mount -o remount,rw / 2>/dev/null
good

begin "mounting the remaining filesystems"
mount -a -t nosquashfs,noproc,nosysfs,nodevtmpfs 2>/dev/null || mount -a 2>/dev/null
good

begin "activating swap"
swapon -a 2>/dev/null || :
if [ -f /etc/arctic/zram.conf ]; then
	. /etc/arctic/zram.conf
	if [ -b /dev/zram0 ] || modprobe zram 2>/dev/null; then
		echo "${ZRAM_ALGO:-zstd}" >/sys/block/zram0/comp_algorithm 2>/dev/null
		echo "${ZRAM_SIZE:-4G}"   >/sys/block/zram0/disksize 2>/dev/null
		mkswap /dev/zram0 >/dev/null 2>&1 && swapon -p 100 /dev/zram0 2>/dev/null
	fi
fi
good

# ------------------------------------------------------------------------- system
begin "setting the hostname"
# Not "A && B || C": if /etc/hostname exists but "hostname -F" itself fails
# for any reason (an empty file, a trailing-whitespace quirk), that pattern
# runs the fallback too and silently renames the machine to the literal
# string "arctic" instead of leaving the real, configured name in place.
if [ -f /etc/hostname ]; then
	hostname -F /etc/hostname 2>/dev/null || hostname "$(cat /etc/hostname 2>/dev/null)" 2>/dev/null
else
	hostname arctic
fi
good

begin "setting up the console"
[ -f /etc/vconsole.conf ] && . /etc/vconsole.conf
[ -n "${KEYMAP:-}" ] && loadkmap </usr/share/keymaps/"$KEYMAP".bmap 2>/dev/null || :

# Console fonts ship in several shapes (.psf, .psfu, and either gzipped)
# depending on where they came from, and setfont only takes the file it is
# handed - so find whichever one actually exists rather than assuming .psf.
if [ -n "${FONT:-}" ]; then
	for _e in .psfu.gz .psf.gz .psfu .psf ""; do
		_f=/usr/share/consolefonts/$FONT$_e
		[ -f "$_f" ] && { setfont "$_f" 2>/dev/null; break; }
	done
fi

# Repaint the 16 console colours in Arctic's palette. The default VGA set is
# the one every distribution has looked like since 1991; this is the same
# ice/blue scheme the bootloader and the website use, so a bare TTY looks
# like part of the system rather than a generic Linux console.
#
# ESC]P<index><rrggbb> is the console's own palette escape - it needs no
# tools and works on every VT before anything is installed.
set_palette() {
	printf '\033]P0%s' "1a1b26"   # black
	printf '\033]P1%s' "f38ba8"   # red
	printf '\033]P2%s' "a6e3a1"   # green
	printf '\033]P3%s' "f9e2af"   # yellow
	printf '\033]P4%s' "89b4fa"   # blue
	printf '\033]P5%s' "cba6f7"   # magenta
	printf '\033]P6%s' "94e2d5"   # cyan
	printf '\033]P7%s' "bac2de"   # white
	printf '\033]P8%s' "45475a"   # bright black
	printf '\033]P9%s' "f38ba8"
	printf '\033]PA%s' "a6e3a1"
	printf '\033]PB%s' "f9e2af"
	printf '\033]PC%s' "89b4fa"
	printf '\033]PD%s' "cba6f7"
	printf '\033]PE%s' "94e2d5"
	printf '\033]PF%s' "cdd6f4"   # bright white
	printf '\033[H\033[2J'        # repaint with the new palette in effect
}
for _t in /dev/tty1 /dev/tty2 /dev/tty3 /dev/tty4; do
	[ -w "$_t" ] && set_palette >"$_t" 2>/dev/null
done

# Stop the console blanking after 10 minutes mid-install, and turn off the
# power-management blank that some laptops otherwise apply on top of it.
for _t in /dev/tty1 /dev/tty2 /dev/tty3 /dev/tty4; do
	[ -w "$_t" ] && printf '\033[9;0]\033[14;0]' >"$_t" 2>/dev/null
done
good

begin "seeding the random pool"
[ -f /var/lib/arctic/random-seed ] && \
	cat /var/lib/arctic/random-seed >/dev/urandom 2>/dev/null
mkdir -p /var/lib/arctic
dd if=/dev/urandom of=/var/lib/arctic/random-seed bs=512 count=1 2>/dev/null
chmod 600 /var/lib/arctic/random-seed
good

begin "setting the clock"
[ -e /dev/rtc0 ] && hwclock --hctosys --utc 2>/dev/null || :
good

begin "cleaning up /tmp and /run"
rm -rf /tmp/.[!.]* /tmp/* 2>/dev/null || :
rm -f /run/*.pid 2>/dev/null || :
# Not "rm -f /run/arctic/*": that is where this boot's own log lives, and
# wiping it here threw away every line written before this point - including
# anything that had already gone wrong. /run is a fresh tmpfs each boot, so
# there is nothing stale to clear anyway.
for _f in /run/arctic/*; do
	[ -e "$_f" ] || continue
	[ "$_f" = "$RC_LOG" ] && continue
	rm -rf "$_f" 2>/dev/null || :
done

: >/var/run/utmp 2>/dev/null || :
good

begin "bringing up the loopback interface"
ip link set lo up 2>/dev/null || ifconfig lo 127.0.0.1 up 2>/dev/null
good

# --------------------------------------------------------------------- generation
# Booting an "Arctic Linux (generation N)" entry from the boot menu puts
# arctic.generation=N on the kernel command line. Reconciling here, before
# services start, is what makes that entry mean the same thing as having run
# `arctic-generation switch N` - the machine comes up as that configuration,
# not as the current one with an old label.
#
# This is the escape hatch for a rebuild that made the system unbootable, so
# it deliberately never aborts the boot: if the switch fails, the machine
# still comes all the way up and says so.
for _a in $(cat /proc/cmdline 2>/dev/null); do
	case "$_a" in
	arctic.generation=*)
		_g=${_a#arctic.generation=}
		[ -n "$_g" ] || continue
		[ -d "/var/lib/arctic/generations/$_g" ] || continue
		[ "$_g" = "$(cat /var/lib/arctic/generations/current 2>/dev/null)" ] && continue
		begin "switching to generation $_g"
		if command -v arctic-generation >/dev/null 2>&1 && \
		   arctic-generation switch "$_g" >/var/log/arctic-generation-boot.log 2>&1; then
			good
		else
			bad "generation $_g (see /var/log/arctic-generation-boot.log)"
		fi
		;;
	esac
done

# ------------------------------------------------------------------------ services
if [ -d /etc/arctic/services ]; then
	for s in /etc/arctic/services/*; do
		[ -e "$s" ] || continue
		n=$(basename "$s")
		[ "$n" = "udev" ] && continue     # already handled above
		rc_log "service $n: considering"
		if [ ! -x "/etc/rc.d/$n" ]; then
			# Enabled but there is no script to run it, or it is not
			# executable. Silently skipping this is how a service ends up
			# "enabled" and never running with nothing to show for it.
			bad "$n (no executable /etc/rc.d/$n)"
			continue
		fi
		begin "starting $n"
		# Failures used to go to /dev/null, which meant a service that could
		# not start left no trace anywhere. Keep the console tidy on success,
		# but record what went wrong either way.
		if _out=$("/etc/rc.d/$n" start 2>&1); then
			good
			rc_log "service $n: started"
			[ -n "$_out" ] && rc_log "  $_out"
		else
			bad "$n"
			rc_log "service $n: FAILED"
			[ -n "$_out" ] && { printf '%s\n' "$_out" | sed 's/^/     /'
				printf '%s\n' "$_out" | sed 's/^/  /' >>"$RC_LOG" 2>/dev/null || :; }
		fi
	done
fi

# ----------------------------------------------------------------------- greeting
# A finished install says hello exactly once.
if [ -f /var/lib/arctic/firstboot ]; then
	rm -f /var/lib/arctic/firstboot
	[ -x /usr/bin/arctic-firstboot ] && /usr/bin/arctic-firstboot
fi

rc_done

# /run is a tmpfs, so keep a copy somewhere that survives the boot. This is
# the first thing to look at when something did not come up.
if [ -f /run/arctic/boot.log ]; then
	mkdir -p /var/log 2>/dev/null && \
		cp -f /run/arctic/boot.log /var/log/boot.log 2>/dev/null || :
fi
exit 0
