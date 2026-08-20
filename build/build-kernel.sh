#!/bin/sh
# Arctic Linux - kernel builder
# arctic-base-kernel starts from the Gentoo dist-kernel .config, as specified,
# then applies the Arctic delta: no BTF/debuginfo, no module signing, and the
# live-ISO filesystems built in-tree instead of as modules.
set -e

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

arctic_set() { scripts/config --set-val "$1" "$2" 2>/dev/null || :; }
arctic_y()   { scripts/config --enable "$1"; }
arctic_n()   { scripts/config --disable "$1"; }
arctic_s()   { scripts/config --set-str "$1" "$2"; }

echo ":: applying Arctic kernel delta ($FLAVOUR)"

# Build-cost trims. BTF + full debuginfo across 4800 modules costs hours and
# ships hundreds of MiB we do not want on an installer image.
arctic_n DEBUG_INFO_BTF
arctic_n DEBUG_INFO_BTF_MODULES
arctic_y DEBUG_INFO_NONE
arctic_n DEBUG_INFO_DWARF5
arctic_n DEBUG_INFO_DWARF4
arctic_n GDB_SCRIPTS
arctic_n PAHOLE_HAS_SPLIT_BTF

# We sign nothing at build time; alpm verifies packages instead.
arctic_n MODULE_SIG
arctic_n MODULE_SIG_ALL
arctic_n MODULE_SIG_FORCE
arctic_n SECURITY_LOCKDOWN_LSM
arctic_s MODULE_SIG_KEY ""
arctic_s SYSTEM_TRUSTED_KEYS ""
arctic_s SYSTEM_REVOCATION_KEYS ""

# Needed before any module can be loaded.
arctic_y SQUASHFS
arctic_y SQUASHFS_XZ
arctic_y SQUASHFS_ZSTD
arctic_y SQUASHFS_LZ4
arctic_y OVERLAY_FS
arctic_y BLK_DEV_LOOP
arctic_y ISO9660_FS
arctic_y JOLIET
arctic_y ZISOFS
arctic_y VFAT_FS
arctic_y NLS_CODEPAGE_437
arctic_y NLS_ISO8859_1
arctic_y NLS_UTF8
arctic_y DEVTMPFS
arctic_y DEVTMPFS_MOUNT
arctic_y TMPFS
arctic_y TMPFS_POSIX_ACL
arctic_y BLK_DEV_INITRD
arctic_y RD_XZ
arctic_y RD_ZSTD
arctic_y RD_GZIP
arctic_set LOG_BUF_SHIFT 18

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
	arctic_y "$c"
done

# Arctic identity in uname / dmesg.
arctic_s LOCALVERSION "-arctic-$FLAVOUR"
arctic_n LOCALVERSION_AUTO
arctic_s DEFAULT_HOSTNAME "arctic"

case "$FLAVOUR" in
libre)
	# No blob loading paths, no nonfree microcode, no proprietary-driver ABI.
	arctic_n FW_LOADER_USER_HELPER
	arctic_s EXTRA_FIRMWARE ""
	arctic_n MICROCODE_INITRD32
	arctic_n DRM_NOUVEAU_GSP_DEFAULT
	;;
small)
	# Monolithic, no module loader at all: fast boot, no initramfs required.
	arctic_n MODULES
	;;
esac

make olddefconfig >/dev/null

echo ":: building vmlinuz + modules with -j$J"
make -j"$J" bzImage
[ "$FLAVOUR" = small ] || make -j"$J" modules

OUT="$B/stage/kernel-$FLAVOUR"
rm -rf "$OUT"; mkdir -p "$OUT/boot" "$OUT/lib/modules"
cp arch/x86/boot/bzImage "$OUT/boot/vmlinuz-arctic-$FLAVOUR"
cp .config "$OUT/boot/config-arctic-$FLAVOUR"
cp System.map "$OUT/boot/System.map-arctic-$FLAVOUR"
if [ "$FLAVOUR" != small ]; then
	make INSTALL_MOD_PATH="$OUT" INSTALL_MOD_STRIP=1 modules_install >/dev/null
fi
echo "=== KERNEL $FLAVOUR DONE ==="
du -sh "$OUT"
