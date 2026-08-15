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
begin "Mounting pseudo-filesystems"
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
# Arctic uses busybox mdev with libudev-zero, so there is no systemd-derived
# udev in the base system. eudev is available in extra for anyone who wants it.
# The line names the one that actually ran - "starting the device manager" is
# true of either and tells you nothing when you are looking at a boot log
# trying to work out which one this machine came up with.
if [ -x /sbin/udevd ] && [ -f /etc/arctic/services/udev ]; then
	begin "Starting udev"
	/sbin/udevd --daemon 2>/dev/null
	udevadm trigger --action=add --type=subsystems 2>/dev/null
	udevadm trigger --action=add --type=devices 2>/dev/null
	udevadm settle --timeout=30 2>/dev/null
else
	begin "Starting mdev"
	# Only if the kernel actually exposes it. Writing the hotplug helper
	# unconditionally printed "can't create /proc/sys/kernel/hotplug:
	# nonexistent directory" across the boot on any kernel without
	# CONFIG_UEVENT_HELPER - the coldplug pass below is what populates /dev
	# either way, so this is an optimisation, not a requirement.
	[ -d /proc/sys/kernel ] && printf '/sbin/mdev\n' >/proc/sys/kernel/hotplug 2>/dev/null
	mdev -s
	[ -x /sbin/mdev ] && mdev -df & 2>/dev/null
fi
good

begin "Applying sysctl settings"
[ -f /etc/sysctl.conf ] && sysctl -p /etc/sysctl.conf >/dev/null 2>&1
good

begin "Loading kernel modules"
for f in /etc/modules-load.d/*.conf; do
	[ -f "$f" ] || continue
	while read -r m; do
		case "$m" in ''|\#*) continue ;; esac
		modprobe "$m" 2>/dev/null || :
	done <"$f"
done

# Coldplug: load a driver for every device already present.
#
# udev does this on other systems; mdev does not, and Arctic runs mdev. The
# hotplug handler only fires for devices that appear *after* boot, so
# anything already plugged in when the machine started - which is every PCI
# device, including the network card - never had its module loaded at all.
# A live session came up with nothing but "lo" and "Network is unreachable",
# on real hardware as much as in a VM, while the driver sat in
# /usr/lib/modules unused.
#
# Every modalias under /sys is a device asking for its driver by name;
# modprobe resolves it through modules.alias. Failures are ordinary here -
# plenty of devices have no module in this kernel - so they stay quiet.
if [ -d /sys/devices ]; then
	find /sys/devices -name modalias -type f 2>/dev/null | \
	while read -r a; do
		read -r alias <"$a" 2>/dev/null || continue
		[ -n "$alias" ] || continue
		modprobe -q "$alias" 2>/dev/null || :
	done
fi
good

# --------------------------------------------------------------------- filesystems
begin "Checking filesystems"
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

begin "Remounting rootfs read-write"
mount -o remount,rw / 2>/dev/null
good

begin "Mounting all filesystems"
mount -a -t nosquashfs,noproc,nosysfs,nodevtmpfs 2>/dev/null || mount -a 2>/dev/null
good

begin "Activating swap"
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
begin "Setting up hostname"
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

begin "Setting up console"
[ -f /etc/vconsole.conf ] && . /etc/vconsole.conf
# Braces around the redirect: a failed input redirection is the shell's own
# error, so "2>/dev/null" on loadkmap alone still printed "can't open
# /usr/share/keymaps/us.bmap: no such file" over the boot on every image that
# ships no keymaps at all.
if [ -n "${KEYMAP:-}" ] && [ -f "/usr/share/keymaps/$KEYMAP.bmap" ]; then
	{ loadkmap </usr/share/keymaps/"$KEYMAP".bmap; } 2>/dev/null || :
fi

# Console fonts ship in several shapes (.psf, .psfu, and either gzipped)
# depending on where they came from, and setfont only takes the file it is
# handed - so find whichever one actually exists rather than assuming .psf.
if [ -n "${FONT:-}" ]; then
	for _e in .psfu.gz .psf.gz .psfu .psf ""; do
		_f=/usr/share/consolefonts/$FONT$_e
		[ -f "$_f" ] && { setfont "$_f" 2>/dev/null; break; }
	done
fi

# Stop the console blanking after 10 minutes mid-install, and turn off the
# power-management blank that some laptops otherwise apply on top of it.
for _t in /dev/tty1 /dev/tty2 /dev/tty3 /dev/tty4; do
	[ -w "$_t" ] && printf '\033[9;0]\033[14;0]' >"$_t" 2>/dev/null
done
good

begin "Initializing random seed"
[ -f /var/lib/arctic/random-seed ] && \
	cat /var/lib/arctic/random-seed >/dev/urandom 2>/dev/null
mkdir -p /var/lib/arctic
# chmod before writing, not after - a plain dd of a not-yet-existing file
# creates it at the umask's default mode first, leaving fresh entropy
# world-readable for the moment between that create and the chmod.
: >/var/lib/arctic/random-seed
chmod 600 /var/lib/arctic/random-seed
dd if=/dev/urandom of=/var/lib/arctic/random-seed bs=512 count=1 2>/dev/null
good

begin "Setting up RTC"
[ -e /dev/rtc0 ] && hwclock --hctosys --utc 2>/dev/null || :
good

begin "Cleaning up /tmp and /run"
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

begin "Setting up loopback interface"
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
		begin "Switching to generation $_g"
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
			# begin() first: bad() right-aligns its result against whatever
			# begin() last set, so without one this printed its [failed] at
			# the padding of the *previous* line's label.
			begin "Service '$n'"
			bad "no executable /etc/rc.d/$n"
			continue
		fi
		begin "Service '$n'"
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

# Leave a clean screen for the login prompt. The boot log is worth watching
# while it happens and worth keeping afterwards - it is in /var/log/boot.log
# and /run/arctic/boot.log either way - but landing on a fresh tty is what
# you want once the machine is up. A verbose boot keeps it on screen.
case " $(cat /proc/cmdline 2>/dev/null) " in
*" verbose "*|*" debug "*) ;;
*) [ "${QUIET:-0}" = "1" ] || { command -v clear >/dev/null 2>&1 && clear; } ;;
esac

# /run is a tmpfs, so keep a copy somewhere that survives the boot. This is
# the first thing to look at when something did not come up.
if [ -f /run/arctic/boot.log ]; then
	mkdir -p /var/log 2>/dev/null && \
		cp -f /run/arctic/boot.log /var/log/boot.log 2>/dev/null || :
fi
exit 0
