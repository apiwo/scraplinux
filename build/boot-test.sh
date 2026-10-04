#!/bin/sh
# boot-test.sh - build a ScrapLinux test disk, boot it headless under QEMU and
# report whether it reached a login prompt, and how long that took.
#
#   build/boot-test.sh                       one UEFI boot of the base flavor
#   build/boot-test.sh --firmware bios       SeaBIOS instead of OVMF
#   build/boot-test.sh --runs 10             the ten consecutive boots test
#   build/boot-test.sh --rebuild             reinstall the disk from the tarball
#   build/boot-test.sh --flavor wayland      a different tarball flavor
#
# Every run writes a full serial log, so a panic is captured in full rather
# than scrolled off a framebuffer. The disk is installed once and then booted
# from a qcow2 overlay, so a boot that corrupts the filesystem cannot poison
# the next run and the base image never has to be rebuilt to recover.
#
# Exit status is 0 only if every run reached a login prompt.
# shellcheck shell=sh disable=SC2039

set -u

B=${SCRAPLINUX_BUILD:-/home/apiwo/scraplinux-build}
TREE=${SCRAPLINUX_TREE:-/home/apiwo/scraplinux}
WORK=$B/boot-test
NBD=${NBD_DEV:-/dev/nbd3}
MNT=$WORK/mnt

FLAVOR=base
FIRMWARE=uefi
RUNS=1
TIMEOUT=120
REBUILD=0

while [ $# -gt 0 ]; do
	case "$1" in
	--flavor)   FLAVOR=$2; shift 2 ;;
	--firmware) FIRMWARE=$2; shift 2 ;;
	--runs)     RUNS=$2; shift 2 ;;
	--timeout)  TIMEOUT=$2; shift 2 ;;
	--rebuild)  REBUILD=1; shift ;;
	-h|--help)  sed -n '2,16p' "$0" | sed 's/^# \?//'; exit 0 ;;
	*) echo "boot-test.sh: unknown argument '$1'" >&2; exit 2 ;;
	esac
done

[ "$(id -u)" = 0 ] || { echo "boot-test.sh: must run as root (loopback mount, nbd)" >&2; exit 1; }

TARBALL=$B/tarball-out/scraplinux-$FLAVOR-tarball.tar.xz
[ -f "$TARBALL" ] || { echo "boot-test.sh: no tarball at $TARBALL" >&2; exit 1; }

BASE=$WORK/$FLAVOR-base.qcow2
mkdir -p "$WORK" "$MNT"

# OVMF lives in different places depending on the host distribution. Find a
# real file rather than assuming one path, so this works outside this machine.
find_ovmf() {
	for d in /usr/share/edk2/OvmfX64 /usr/share/edk2-ovmf/x64 /usr/share/OVMF \
	         /usr/share/qemu/ovmf-x86_64 /usr/share/ovmf/x64; do
		for c in OVMF_CODE.fd OVMF_CODE.4m.fd OVMF_CODE_4M.fd; do
			[ -f "$d/$c" ] && { printf '%s' "$d/$c"; return 0; }
		done
	done
	return 1
}
find_ovmf_vars() {
	_d=$(dirname "$1")
	for v in OVMF_VARS.fd OVMF_VARS.4m.fd OVMF_VARS_4M.fd; do
		[ -f "$_d/$v" ] && { printf '%s' "$_d/$v"; return 0; }
	done
	return 1
}

cleanup_nbd() {
	for m in "$MNT/boot" "$MNT"; do
		mountpoint -q "$m" 2>/dev/null && umount "$m" 2>/dev/null
	done
	qemu-nbd -d "$NBD" >/dev/null 2>&1
}

install_disk() {
	echo ":: installing a fresh $FLAVOR disk at $BASE"
	cleanup_nbd
	rm -f "$BASE"
	qemu-img create -f qcow2 "$BASE" 8G >/dev/null || return 1
	modprobe nbd max_part=16 2>/dev/null
	qemu-nbd -c "$NBD" "$BASE" || return 1
	sleep 1

	# Three partitions, not two. On GPT a BIOS machine has nowhere to put a
	# bootloader's second stage: there is no post-MBR gap to speak of, so the
	# convention is a tiny unformatted BIOS boot partition (type EF02) that
	# stage 2 is written into. Without it `limine bios-install` refuses
	# outright ("no BIOS boot partition specified or detected") and the disk
	# is UEFI-only. The real installer needs this same partition for the same
	# reason.
	parted -s "$NBD" mklabel gpt \
		mkpart primary 1MiB 2MiB set 1 bios_grub on \
		mkpart primary fat32 2MiB 512MiB set 2 esp on \
		mkpart primary ext4 512MiB 100% || { cleanup_nbd; return 1; }
	sleep 1
	mkfs.vfat -F32 -n SCRAPTEST "${NBD}p2" >/dev/null || { cleanup_nbd; return 1; }
	mkfs.ext4 -qF -L SCRAPROOT "${NBD}p3"        || { cleanup_nbd; return 1; }

	mount "${NBD}p3" "$MNT"            || { cleanup_nbd; return 1; }
	mkdir -p "$MNT/boot"
	mount "${NBD}p2" "$MNT/boot"       || { cleanup_nbd; return 1; }

	tar -xJf "$TARBALL" -C "$MNT"      || { cleanup_nbd; return 1; }
	cp -f /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null

	sh "$TREE/scraps/scraps-strap" "$MNT" >/dev/null 2>&1 \
		|| { echo "   scraps-strap failed" >&2; cleanup_nbd; return 1; }
	sh "$TREE/skel/usr/bin/scraplinux-chroot" "$MNT" \
		scraps add -y scraplinux-base ScrapLinux-base-kernel linux-firmware limine \
		>"$WORK/install.log" 2>&1 \
		|| { echo "   scraps add failed, see $WORK/install.log" >&2; cleanup_nbd; return 1; }

	KIMG=$(cd "$MNT/boot" && ls vmlinuz-* 2>/dev/null | head -1)
	IIMG=$(cd "$MNT/boot" && ls initramfs-*.img 2>/dev/null | head -1)
	[ -n "$KIMG" ] && [ -n "$IIMG" ] \
		|| { echo "   no kernel or initramfs installed" >&2; cleanup_nbd; return 1; }

	RU=$(blkid -s UUID -o value "${NBD}p3")
	BU=$(blkid -s UUID -o value "${NBD}p2")

	mkdir -p "$MNT/boot/EFI/BOOT"
	cp -f "$MNT/usr/share/limine/BOOTX64.EFI" "$MNT/boot/EFI/BOOT/BOOTX64.EFI"

	# console= on both so the same image works headless over the serial port and
	# on a real screen. ttyS0 last makes it the one /dev/console resolves to.
	cat >"$MNT/boot/limine.conf" <<-EOF
		timeout: 0

		/ScrapLinux
		    protocol: linux
		    kernel_path: boot():/$KIMG
		    module_path: boot():/$IIMG
		    cmdline: root=UUID=$RU rw console=tty0 console=ttyS0,115200
	EOF

	cat >"$MNT/etc/fstab" <<-EOF
		UUID=$RU	/	ext4	rw,relatime	0	1
		UUID=$BU	/boot	vfat	rw,relatime	0	2
		tmpfs	/tmp	tmpfs	rw,nosuid,nodev,size=50%	0	0
		proc	/proc	proc	rw,nosuid,nodev,noexec	0	0
		sysfs	/sys	sysfs	rw,nosuid,nodev,noexec	0	0
		devpts	/dev/pts	devpts	rw,nosuid,noexec,gid=5,mode=620	0	0
	EOF

	# Limine's BIOS stage is a second, separate install: the UEFI path only
	# needs EFI/BOOT/BOOTX64.EFI on the ESP, but a BIOS machine loads stage 1
	# from the MBR gap and stage 2 from limine-bios.sys, so both have to be
	# put there explicitly or --firmware bios has nothing to boot.
	if [ -f "$MNT/usr/share/limine/limine-bios.sys" ]; then
		cp -f "$MNT/usr/share/limine/limine-bios.sys" "$MNT/boot/limine-bios.sys"
	fi
	# Resolve and copy the installer out *before* unmounting: the path inside
	# the image stops existing the moment the filesystem is unmounted, and
	# running it afterwards failed with "No such file or directory" against a
	# path that was perfectly valid a line earlier. The host's own limine is
	# preferred when present, because the packaged one is linked against
	# ScrapLinux's glibc and will not run on the build host.
	_limine=""
	if command -v limine >/dev/null 2>&1; then
		_limine=$(command -v limine)
	elif [ -x "$MNT/usr/bin/limine" ]; then
		cp -f "$MNT/usr/bin/limine" "$WORK/limine-installer"
		_limine="$WORK/limine-installer"
	fi

	sync
	umount "$MNT/boot"; umount "$MNT"
	sync

	if [ -n "$_limine" ]; then
		# Runs against the raw nbd device, after unmounting, so stage 2's
		# recorded location matches what is actually on disk.
		"$_limine" bios-install "$NBD" >>"$WORK/install.log" 2>&1 \
			|| echo "   note: limine bios-install failed, BIOS boots will not work" >&2
	else
		echo "   note: no limine binary, BIOS boots will not work" >&2
	fi
	qemu-nbd -d "$NBD" >/dev/null 2>&1
	sleep 1
	echo "   installed"
	return 0
}

boot_once() {
	_run=$1
	_log=$WORK/serial-$FIRMWARE-$_run.log
	_overlay=$WORK/overlay-$_run.qcow2
	rm -f "$_log" "$_overlay"
	qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$_overlay" >/dev/null 2>&1 || return 1

	set -- -enable-kvm -cpu host -m 2048 -smp 2 \
		-drive file="$_overlay",if=none,id=nvm,format=qcow2 \
		-device nvme,drive=nvm,serial=scraptest \
		-chardev file,id=c0,path="$_log" -serial chardev:c0 \
		-display none -no-reboot

	if [ "$FIRMWARE" = uefi ]; then
		_code=$(find_ovmf) || { echo "   no OVMF firmware found" >&2; return 1; }
		_vars=$(find_ovmf_vars "$_code") || { echo "   no OVMF vars template" >&2; return 1; }
		cp -f "$_vars" "$WORK/vars-$_run.fd"
		set -- "$@" -drive if=pflash,format=raw,readonly=on,file="$_code" \
		           -drive if=pflash,format=raw,file="$WORK/vars-$_run.fd"
	fi

	_start=$(date +%s.%N)
	qemu-system-x86_64 "$@" >"$WORK/qemu-$_run.log" 2>&1 &
	_pid=$!

	_ok=0
	# Integer tick counter, not a float accumulator: POSIX [ compares integers
	# only, so a 0.25 step made every comparison an error and the loop exited
	# immediately, failing a boot that had not even started.
	_ticks=0
	_maxticks=$(( TIMEOUT * 4 ))
	while [ "$_ticks" -lt "$_maxticks" ]; do
		kill -0 "$_pid" 2>/dev/null || break
		if grep -qE "login:|Welcome to SDDM|sddm-greeter" "$_log" 2>/dev/null; then
			_ok=1; break
		fi
		if grep -qE "Kernel panic|Attempted to kill init|end Kernel panic" "$_log" 2>/dev/null; then
			_ok=0; break
		fi
		sleep 0.25
		_ticks=$(( _ticks + 1 ))
	done
	_end=$(date +%s.%N)
	kill -9 "$_pid" 2>/dev/null
	wait "$_pid" 2>/dev/null

	_wall=$(awk -v a="$_start" -v b="$_end" 'BEGIN{printf "%.2f", b-a}')
	# The kernel's own clock for the handoff, and rc.lib's own total, so a slow
	# boot can be attributed to firmware, kernel or userspace rather than
	# guessed at.
	_handoff=$(sed 's/\x1b\[[0-9;]*m//g' "$_log" 2>/dev/null \
		| sed -n 's/^\[ *\([0-9.]*\)\] Run \/init as init process.*/\1/p' | head -1)
	_initdone=$(sed 's/\x1b\[[0-9;]*m//g' "$_log" 2>/dev/null \
		| sed -n 's/.*Init done *\([0-9.]*\)s.*/\1/p' | head -1)
	_panic=$(grep -cE "Kernel panic|Attempted to kill init" "$_log" 2>/dev/null)

	if [ "$_ok" = 1 ]; then
		printf '  run %-3s %-6s PASS  wall %ss  kernel-handoff %ss  rc.boot %ss\n' \
			"$_run" "$FIRMWARE" "$_wall" "${_handoff:-?}" "${_initdone:-?}"
	else
		printf '  run %-3s %-6s FAIL  wall %ss  panics %s  log %s\n' \
			"$_run" "$FIRMWARE" "$_wall" "${_panic:-0}" "$_log"
	fi
	rm -f "$_overlay" "$WORK/vars-$_run.fd"
	return $(( 1 - _ok ))
}

trap 'cleanup_nbd' EXIT INT TERM

if [ ! -f "$BASE" ] || [ "$REBUILD" = 1 ]; then
	install_disk || { echo "boot-test.sh: install failed" >&2; exit 1; }
fi

echo ":: booting $FLAVOR, firmware $FIRMWARE, $RUNS run(s), timeout ${TIMEOUT}s"
pass=0; fail=0
n=1
while [ "$n" -le "$RUNS" ]; do
	if boot_once "$n"; then pass=$((pass+1)); else fail=$((fail+1)); fi
	n=$((n+1))
done

echo
echo "  $pass passed, $fail failed"
[ "$fail" = 0 ]
