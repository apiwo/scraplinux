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

# No banner. It printed the release out of /etc/arctic-release above the
# boot, which is a version string nobody needs at the top of every boot and
# which was wrong for a long time anyway - the installer stamped every machine
# "Alpha 1.1" whatever image it came from. `arcticfetch` answers the question
# when it is actually being asked.

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
	# Only if the kernel actually exposes it. A kernel built without
	# CONFIG_UEVENT_HELPER still has /proc/sys/kernel - it is the hotplug
	# entry inside it that is absent, and procfs will not let one be created -
	# so testing the directory guarded nothing and the boot still printed
	# "can't create /proc/sys/kernel/hotplug". Redirecting stderr does not
	# help either: a failed output redirection is reported before 2>/dev/null
	# takes effect. Test the file itself. The coldplug pass below is what
	# populates /dev either way, so this is an optimisation, not a
	# requirement.
	[ -w /proc/sys/kernel/hotplug ] && printf '/sbin/mdev\n' >/proc/sys/kernel/hotplug
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
#
# A real machine can have several hundred of these, and this used to
# modprobe every single one - including devices the kernel had already
# bound a driver to before userspace even started (most of them, on real
# hardware: built-in matching and earlier-loaded modules satisfy the
# majority of devices before rc.boot ever runs), and including the same
# alias two or three times over on machines with several identical USB or
# PCI devices. Each of those was a full fork of busybox modprobe, which
# re-parses modules.dep from scratch on every invocation - it has no cache
# across calls the way real kmod does. Backgrounded and dotted the same way
# wifi-connect's own silent scan is, so there is a heartbeat instead of a
# dead screen either way, but the real fix is not asking twice: a device
# with a `driver` symlink already has one, and an alias already queued for
# this boot does not need to be looked up again.
if [ -d /sys/devices ]; then
	# A label for this step specifically, even under quiet: begin() prints
	# nothing at all in that mode, and dots with no idea what they belong to
	# read as garbage on an otherwise blank screen rather than progress.
	[ "${QUIET:-0}" = "1" ] && printf '  :: loading drivers '
	(
		find /sys/devices -name modalias -type f 2>/dev/null | \
		while read -r a; do
			[ -e "${a%/modalias}/driver" ] && continue
			read -r alias <"$a" 2>/dev/null || continue
			[ -n "$alias" ] && printf '%s\n' "$alias"
		done | sort -u | \
		{
			# busybox's modprobe caches nothing between invocations - it
			# re-parses modules.dep from scratch every single time, unlike
			# real kmod's binary index. On real hardware's dozens of unique
			# aliases (a VM's much smaller device set never showed this),
			# that repeated parse is most of what makes this step slow, and
			# it is exactly as slow run one at a time as eight at a time:
			# nothing here shares state, each modprobe does its own
			# independent parse regardless. `wait -n` would schedule the
			# next one the moment any one slot frees up, but it is a
			# bashism busybox ash does not have - batches of eight, all
			# launched, then one `wait` for the whole batch, is the
			# portable version of the same idea.
			_cp_n=0
			while read -r alias; do
				modprobe -q "$alias" 2>/dev/null &
				_cp_n=$((_cp_n + 1))
				[ "$_cp_n" -ge 8 ] && { wait; _cp_n=0; }
			done
			wait
		}
	) &
	_cp_pid=$!
	# Not gated on QUIET. The default boot entry passes both quiet and
	# arctic.splash, either of which sets QUIET=1 - so on the one entry
	# everyone actually boots from, a2.5's dots never printed at all, and
	# this step was exactly as silent as it had always been. The whole
	# reason the dots exist is to stop someone reaching for the power
	# button on a machine that is working; that has to survive quiet mode,
	# because quiet mode is what a real boot actually uses. QUIET still
	# suppresses the step label itself, further down in begin(); this is
	# the one piece of output that outranks it.
	while kill -0 "$_cp_pid" 2>/dev/null; do
		printf '.'
		sleep 1
	done
	wait "$_cp_pid" 2>/dev/null
	# good() prints nothing at all under quiet, so without this the cursor
	# sits right after the last dot and whatever prints next - quiet or
	# not - lands on the same line.
	[ "${QUIET:-0}" = "1" ] && printf '\n'
fi
good

# --------------------------------------------------------------------- filesystems
begin "Checking filesystems"
# Not "fsck -A": that hands whatever /etc/fstab literally says - usually
# UUID=... - straight to the per-type helper. e2fsck resolves that itself
# via its own libblkid link; dosfstools' fsck.fat does not and just tries
# to open the string "UUID=..." as a path, failing every single boot with
# a separate FAT /boot (every UEFI install, every BIOS+Limine one) with
# nothing more specific than "open: No such file or directory" and a
# forced trip to the repair shell for a filesystem that was never
# actually broken. Resolve every entry to a real device with findfs
# first, the same way the initramfs itself has to for root=.
fsck_all() {
	_fa_extra=$1
	_fa_rc=0
	while read -r _fa_dev _fa_mnt _fa_type _fa_opts _fa_dump _fa_pass; do
		case "$_fa_dev" in ''|\#*) continue ;; esac
		[ "${_fa_pass:-0}" -gt 0 ] 2>/dev/null || continue
		case "$_fa_dev" in
		UUID=*|LABEL=*|PARTUUID=*) _fa_real=$(findfs "$_fa_dev" 2>/dev/null) ;;
		*) _fa_real=$_fa_dev ;;
		esac
		[ -n "$_fa_real" ] || { _fa_real=$_fa_dev; }
		# shellcheck disable=SC2086
		fsck -t "$_fa_type" -a $_fa_extra "$_fa_real" 2>/dev/null
		_fa_this=$?
		# fsck's own exit codes: 0 clean, 1 errors corrected - both are a
		# successful "-a" run, not something to act on. A dirty bit left
		# over from any hard power-off is completely routine and fsck.fat
		# fixes it on its own every time; treating exit 1 as a failure
		# meant that ordinary, expected recovery sent every single boot
		# after an unclean shutdown to the repair shell regardless. Only
		# 4 and up ("errors left uncorrected" and worse) mean anything
		# actually needs a human.
		[ "$_fa_this" -ge 4 ] && [ "$_fa_this" -gt "$_fa_rc" ] && _fa_rc=$_fa_this
	done </etc/fstab
	return "$_fa_rc"
}
if [ -f /forcefsck ] || grep -q ' forcefsck' /proc/cmdline 2>/dev/null; then
	fsck_all -f; rm -f /forcefsck
else
	# Only drop to a repair shell when there is a console to type at. During
	# sysinit stdin is not a terminal, so this would otherwise read EOF and
	# fall straight through - or worse, block the whole boot before any
	# service has started, with nothing on screen explaining why.
	fsck_all "" || {
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
#
# Started together, then waited on in the same order they started - not one
# at a time. A slow service used to hold up every service after it whether
# or not either had anything to do with the other: rc.d/wifi and rc.d/network
# can each spend real seconds waiting for a lease or an association, and
# nothing about, say, sshd or a display manager needs to wait for that to
# finish first. Output still prints in a fixed, readable order (begin() for
# each is not interleaved with another service's own output) - only the
# actual work overlaps, not the reporting of it.
#
# network/wifi specifically are not waited on at all here - getty on the
# console is a respawn entry, not part of this sysinit script, but busybox
# init still does not start it until sysinit exits, so waiting on an
# association or a DHCP lease here meant the login prompt itself sat
# behind however long the radio took to come up, on every single boot,
# whether or not anyone at the console cared about the network yet. They
# still start in the first loop below like everything else; they are just
# left out of the second loop that blocks on completion, and a detached
# watcher reports how each one actually went into the boot log once it
# finishes, asynchronously, after the prompt is already up.
_svc_deferred=" network wifi "
if [ -d /etc/arctic/services ]; then
	mkdir -p /run/arctic/svc-out
	: >/run/arctic/svc-pids
	_svc_pending=""
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
		# Failures used to go to /dev/null, which meant a service that could
		# not start left no trace anywhere. Keep the console tidy on
		# success, but record what went wrong either way.
		#
		# PID kept in a file, not an eval'd $n-named variable: service names
		# from /etc/arctic/services/* are almost always plain words, but
		# A_SERVICES in install.conf is user-supplied text, and a name with
		# a dash or anything else that is not a valid shell identifier
		# character breaks an eval'd assignment instead of just failing to
		# start.
		case "$_svc_deferred" in
		*" $n "*)
			# Started and waited on inside the same backgrounded subshell,
			# not forked here and adopted there - wait can only ever wait on
			# a shell's own direct child, and a process this loop forks
			# belongs to rc.boot itself, not to some other subshell handed
			# the bare pid afterward.
			rc_log "service $n: deferred, not holding up boot"
			( if "/etc/rc.d/$n" start >"/run/arctic/svc-out/$n" 2>&1; then
				rc_log "service $n: started (deferred)"
				[ -s "/run/arctic/svc-out/$n" ] && rc_log "  $(cat "/run/arctic/svc-out/$n")"
			  else
				rc_log "service $n: FAILED (deferred)"
				[ -s "/run/arctic/svc-out/$n" ] && \
					sed 's/^/  /' "/run/arctic/svc-out/$n" >>"$RC_LOG" 2>/dev/null || :
			  fi
			) &
			;;
		*)
			"/etc/rc.d/$n" start >"/run/arctic/svc-out/$n" 2>&1 &
			printf '%s %s\n' "$n" "$!" >>/run/arctic/svc-pids
			_svc_pending="$_svc_pending $n"
			;;
		esac
	done
	for n in $_svc_pending; do
		begin "Service '$n'"
		_svc_pid=$(awk -v n="$n" '$1==n{print $2; exit}' /run/arctic/svc-pids)
		if wait "$_svc_pid"; then
			good
			rc_log "service $n: started"
			[ -s "/run/arctic/svc-out/$n" ] && rc_log "  $(cat "/run/arctic/svc-out/$n")"
		else
			bad "$n"
			rc_log "service $n: FAILED"
			if [ -s "/run/arctic/svc-out/$n" ]; then
				sed 's/^/     /' "/run/arctic/svc-out/$n"
				sed 's/^/  /' "/run/arctic/svc-out/$n" >>"$RC_LOG" 2>/dev/null || :
			fi
		fi
	done
fi

# ----------------------------------------------------------------------- greeting
# No automatic message on first boot any more - arctic-firstboot still exists
# and still works, run by hand, but a finished install boots straight to the
# login prompt now rather than printing something once and needing to be
# told to stop.
rm -f /var/lib/arctic/firstboot

rc_done

# Leave a clean screen for the login prompt. The boot log is worth watching
# while it happens and worth keeping afterwards - it is in /var/log/boot.log
# and /run/arctic/boot.log either way - but landing on a fresh tty is what
# you want once the machine is up. A verbose boot keeps it on screen.
case " $(cat /proc/cmdline 2>/dev/null) " in
*" verbose "*|*" debug "*) ;;
# netbsd-curses' clear goes through tput, which wants a terminfo database
# that nothing in Arctic ships yet - so it failed, printed "tput: cannot
# access the terminfo database" directly above the login prompt on every
# boot, and left the screen uncleared. The escape sequence needs no database
# and every terminal Arctic can boot on understands it.
*) [ "${QUIET:-0}" = "1" ] || \
	{ command -v clear >/dev/null 2>&1 && clear 2>/dev/null; } || \
	printf '\033[H\033[2J' ;;
esac

# /run is a tmpfs, so keep a copy somewhere that survives the boot. This is
# the first thing to look at when something did not come up.
if [ -f /run/arctic/boot.log ]; then
	mkdir -p /var/log 2>/dev/null && \
		cp -f /run/arctic/boot.log /var/log/boot.log 2>/dev/null || :
fi
exit 0
