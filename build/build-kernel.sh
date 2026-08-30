#!/bin/sh
# ScrapLinux - kernel builder
# scraplinux-base-kernel starts from the Gentoo dist-kernel .config, as specified,
# then applies the ScrapLinux delta: no BTF/debuginfo, no module signing, and the
# live-ISO filesystems built in-tree instead of as modules.
set -e

# Refuse to run outside the sandbox. ScrapLinux's glibc installs to /usr/lib by
# design, so a recipe that forgets DESTDIR would overwrite the host's libc and
# take the machine down - which is exactly what happened once. Run through
# scraplinux-sandbox, where the host filesystem is read-only.
if [ "${SCRAPLINUX_SANDBOX:-0}" != "1" ]; then
	echo "$(basename "$0"): refusing to build outside the sandbox." >&2
	echo "  run it as:  scraplinux/build/scraplinux-sandbox $0 $*" >&2
	echo "  (set SCRAPLINUX_SANDBOX=1 only if you know the host is protected)" >&2
	exit 1
fi
B=/home/apiwo/scraplinux-build
V=7.1.3
FLAVOUR=${1:-base}
J=$(nproc)

cd "$B/work"
if [ ! -d "linux-$V" ]; then
	echo ":: extracting linux-$V"
	tar --use-compress-program="xz -T0 -d" -xf "$B/src/linux-$V.tar.xz"
fi
cd "linux-$V"

cp /usr/src/linux-$V-gentoo-dist-bin/.config .config

scraplinux_set() { scripts/config --set-val "$1" "$2" 2>/dev/null || :; }
scraplinux_y()   { scripts/config --enable "$1"; }
scraplinux_n()   { scripts/config --disable "$1"; }
scraplinux_s()   { scripts/config --set-str "$1" "$2"; }

echo ":: applying ScrapLinux kernel delta ($FLAVOUR)"

# Build-cost trims. BTF + full debuginfo across 4800 modules costs hours and
# ships hundreds of MiB we do not want on an installer image.
scraplinux_n DEBUG_INFO_BTF
scraplinux_n DEBUG_INFO_BTF_MODULES
scraplinux_y DEBUG_INFO_NONE
scraplinux_n DEBUG_INFO_DWARF5
scraplinux_n DEBUG_INFO_DWARF4
scraplinux_n GDB_SCRIPTS
scraplinux_n PAHOLE_HAS_SPLIT_BTF

# We sign nothing at build time; scraps verifies packages instead.
scraplinux_n MODULE_SIG
scraplinux_n MODULE_SIG_ALL
scraplinux_n MODULE_SIG_FORCE
scraplinux_n SECURITY_LOCKDOWN_LSM
scraplinux_s MODULE_SIG_KEY ""
scraplinux_s SYSTEM_TRUSTED_KEYS ""
scraplinux_s SYSTEM_REVOCATION_KEYS ""

# Needed before any module can be loaded.
scraplinux_y SQUASHFS
scraplinux_y SQUASHFS_XZ
scraplinux_y SQUASHFS_ZSTD
scraplinux_y SQUASHFS_LZ4
scraplinux_y OVERLAY_FS
scraplinux_y BLK_DEV_LOOP
scraplinux_y ISO9660_FS
scraplinux_y JOLIET
scraplinux_y ZISOFS
scraplinux_y VFAT_FS
scraplinux_y NLS_CODEPAGE_437
scraplinux_y NLS_ISO8859_1
scraplinux_y NLS_UTF8
scraplinux_y DEVTMPFS
scraplinux_y DEVTMPFS_MOUNT
scraplinux_y TMPFS
scraplinux_y TMPFS_POSIX_ACL
scraplinux_y BLK_DEV_INITRD
scraplinux_y RD_XZ
scraplinux_y RD_ZSTD
scraplinux_y RD_GZIP
scraplinux_set LOG_BUF_SHIFT 18

# Storage and bus controllers must be in-tree, not modules: the initramfs has to
# reach the boot medium before it can load a single module. This covers optical
# media, USB sticks, SATA, NVMe and the virtio devices a VM presents.
for c in \
	BLK_DEV_SD BLK_DEV_SR BLK_DEV_LOOP SCSI SCSI_LOWLEVEL \
	ATA ATA_SFF ATA_PIIX SATA_AHCI SATA_AHCI_PLATFORM ATA_GENERIC \
	NVME_CORE BLK_DEV_NVME \
	USB USB_SUPPORT USB_XHCI_HCD USB_XHCI_PCI USB_EHCI_HCD USB_EHCI_PCI \
	USB_OHCI_HCD USB_UHCI_HCD USB_STORAGE USB_UAS \
	VIRTIO VIRTIO_PCI VIRTIO_BLK VIRTIO_NET SCSI_VIRTIO VIRTIO_CONSOLE \
	VIRTIO_MMIO FUSION_SPI MEGARAID_SAS \
	EXT4_FS EXT4_USE_FOR_EXT2 BTRFS_FS XFS_FS FAT_FS MSDOS_FS \
	CRYPTO_CRC32C LIBCRC32C \
	FB FRAMEBUFFER_CONSOLE DRM DRM_FBDEV_EMULATION SYSFB_SIMPLEFB \
	DRM_SIMPLEDRM FB_EFI FB_VESA
do
	scraplinux_y "$c"
done

# ScrapLinux identity in uname / dmesg.
scraplinux_s LOCALVERSION "-scraplinux-$FLAVOUR"
scraplinux_n LOCALVERSION_AUTO
scraplinux_s DEFAULT_HOSTNAME "scraplinux"

case "$FLAVOUR" in
libre)
	# No blob loading paths, no nonfree microcode, no proprietary-driver ABI.
	scraplinux_n FW_LOADER_USER_HELPER
	scraplinux_s EXTRA_FIRMWARE ""
	scraplinux_n MICROCODE_INITRD32
	scraplinux_n DRM_NOUVEAU_GSP_DEFAULT
	;;
small)
	# Monolithic, no module loader at all: fast boot, no initramfs required.
	scraplinux_n MODULES
	;;
esac

make olddefconfig >/dev/null

echo ":: building vmlinuz + modules with -j$J"
make -j"$J" bzImage
[ "$FLAVOUR" = small ] || make -j"$J" modules

OUT="$B/stage/kernel-$FLAVOUR"
rm -rf "$OUT"; mkdir -p "$OUT/boot" "$OUT/lib/modules"
cp arch/x86/boot/bzImage "$OUT/boot/vmlinuz-scraplinux-$FLAVOUR"
cp .config "$OUT/boot/config-scraplinux-$FLAVOUR"
cp System.map "$OUT/boot/System.map-scraplinux-$FLAVOUR"
if [ "$FLAVOUR" != small ]; then
	make INSTALL_MOD_PATH="$OUT" INSTALL_MOD_STRIP=1 modules_install >/dev/null
fi
echo "=== KERNEL $FLAVOUR DONE ==="
du -sh "$OUT"
