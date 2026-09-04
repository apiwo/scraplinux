#!/bin/sh
# verify-kernel-modules.sh - fail loudly if a staged rootfs is missing wifi
# driver support, instead of shipping a live ISO or tarball that silently
# can't load iwlwifi/ath9k/etc.
#
#   verify-kernel-modules.sh <staged-rootfs-dir>
#
# Real incident this exists for: a live ISO's rootfs had ScrapLinux-base-kernel
# and linux-firmware both recorded as "installed" in scraps' own database,
# but almost none of their actual files had ever been extracted into the
# rootfs - no /usr/lib/modules at all, no iwlwifi.ko, most of
# /usr/lib/firmware missing. `doas modprobe iwlwifi` on the shipped image
# failed with "Operation not permitted", which reads like a signed-modules
# or lockdown problem and is not - the module simply was not there. Nothing
# caught this before the ISO was published because nothing checked. This
# script is that check: run it against any staged rootfs (ISO squashfs
# content, tarball staging tree, whatever) right before it gets packaged.
#
# shellcheck shell=sh disable=SC2039
set -u

ROOT=${1:?usage: verify-kernel-modules.sh <staged-rootfs-dir>}
[ -d "$ROOT" ] || { echo "verify-kernel-modules.sh: $ROOT is not a directory" >&2; exit 1; }

fail=0
say()  { printf ':: %s\n' "$*"; }
bad()  { printf '!! %s\n' "$*" >&2; fail=1; }

# Find the kernel this rootfs actually ships, by its own recorded config -
# not the build host's, not a guess. scraplinux-base-kernel's package()
# writes exactly this file next to the kernel it belongs to.
config=$(find "$ROOT/boot" -maxdepth 1 -name 'config-*' 2>/dev/null | head -1)
if [ -z "$config" ]; then
	bad "no boot/config-* found under $ROOT - can't tell what this kernel was built with"
else
	say "checking $config"
	for opt in CONFIG_IWLWIFI CONFIG_CFG80211 CONFIG_MAC80211; do
		val=$(grep "^$opt=" "$config" 2>/dev/null)
		case "$val" in
		*=m|*=y) ;;
		*) bad "$opt is not m/y in $config - wifi will not exist on this image" ;;
		esac
	done
	if grep -q '^CONFIG_MODULE_SIG_FORCE=y' "$config" 2>/dev/null; then
		bad "CONFIG_MODULE_SIG_FORCE=y is set - every module load fails with" \
			"Operation not permitted unless something in the package step" \
			"actually signs every .ko with the kernel's embedded key first." \
			"Turn it off, or add a real signing step - not both half-done."
	fi
	if grep -q '^CONFIG_SECURITY_LOCKDOWN_LSM=y' "$config" 2>/dev/null; then
		say "CONFIG_SECURITY_LOCKDOWN_LSM=y - confirm nothing sets lockdown=confidentiality"
		say "or =integrity on the kernel cmdline unless module signing is real"
	fi
fi

# The actual files, not just the config that said they'd be there.
kver=$(ls "$ROOT/usr/lib/modules" 2>/dev/null | head -1)
if [ -z "$kver" ]; then
	bad "$ROOT/usr/lib/modules is empty or missing - no modules on this image at all"
else
	say "found module tree for $kver"
	wl="$ROOT/usr/lib/modules/$kver/kernel/drivers/net/wireless"
	if [ ! -d "$wl" ] || [ -z "$(find "$wl" -name '*.ko*' 2>/dev/null)" ]; then
		bad "$wl has no wireless driver modules - CONFIG_IWLWIFI=m alone isn't" \
			"enough if the .ko never actually got extracted into this rootfs"
	fi
	if [ ! -s "$ROOT/usr/lib/modules/$kver/modules.dep" ]; then
		bad "$ROOT/usr/lib/modules/$kver/modules.dep is empty - depmod never ran" \
			"against this rootfs (or ran against the wrong kernel version)"
	fi
fi

fw="$ROOT/usr/lib/firmware/intel/iwlwifi"
if [ ! -d "$fw" ] || [ -z "$(find "$fw" -name '*.ucode' 2>/dev/null)" ]; then
	bad "$fw has no firmware - iwlwifi will load but never associate. Confirm" \
		"linux-firmware actually extracted, not just recorded as installed" \
		"(scraps info linux-firmware --root=$ROOT, or just count the files)"
fi

if [ "$fail" = 1 ]; then
	printf '\nverify-kernel-modules.sh: FAILED - do not ship this image.\n' >&2
	exit 1
fi
say "wifi driver support looks real on $ROOT"
