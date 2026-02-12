#!/bin/bash
# Build Script - Creates Alpine-based bootstrap initramfs
# This script downloads Alpine mini rootfs and creates a bootable initramfs

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_ROOT}/build"
OUTPUT_DIR="${PROJECT_ROOT}/output"
BOOTSTRAP_DIR="${PROJECT_ROOT}/bootstrap"

ALPINE_VERSION="3.19"
ALPINE_ARCH="x86_64"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
INITRAMFS_NAME="chroot-booter-initramfs"
KERNEL_NAME="chroot-booter-kernel"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[BUILD]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[BUILD]${NC} $1"
}

error() {
    echo -e "${RED}[BUILD]${NC} $1"
}

info() {
    echo -e "${BLUE}[BUILD]${NC} $1"
}

# Show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Build the chroot-booter bootstrap initramfs

Options:
    -a, --alpine-version VERSION    Alpine version (default: ${ALPINE_VERSION})
    -A, --arch ARCH                 Architecture (default: ${ALPINE_ARCH})
    -o, --output-dir DIR            Output directory (default: ${OUTPUT_DIR})
    -k, --kernel                    Also download kernel modules
    -c, --clean                     Clean build directory first
    -h, --help                      Show this help

Examples:
    $0                              Build with defaults
    $0 -c                           Clean and rebuild
    $0 -a 3.18 -A aarch64          Build for Alpine 3.18 on ARM64
EOF
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -a|--alpine-version)
                ALPINE_VERSION="$2"
                shift 2
                ;;
            -A|--arch)
                ALPINE_ARCH="$2"
                shift 2
                ;;
            -o|--output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -k|--kernel)
                DOWNLOAD_KERNEL=1
                shift
                ;;
            -c|--clean)
                CLEAN_BUILD=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Setup directories
setup_dirs() {
    log "Setting up directories..."
    
    mkdir -p "$BUILD_DIR"
    mkdir -p "$OUTPUT_DIR"
    
    ROOTFS_DIR="${BUILD_DIR}/rootfs"
    
    if [[ -n "$CLEAN_BUILD" ]]; then
        log "Cleaning build directory..."
        rm -rf "$ROOTFS_DIR"
    fi
    
    mkdir -p "$ROOTFS_DIR"
}

# Download Alpine mini rootfs
download_alpine() {
    log "Downloading Alpine Linux ${ALPINE_VERSION} for ${ALPINE_ARCH}..."
    
    local alpine_file="alpine-minirootfs-${ALPINE_VERSION}.0-${ALPINE_ARCH}.tar.gz"
    local alpine_url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/${alpine_file}"
    local download_path="${BUILD_DIR}/${alpine_file}"
    
    if [[ -f "$download_path" ]]; then
        info "Using cached Alpine rootfs"
    else
        log "Downloading from: $alpine_url"
        wget -O "$download_path" "$alpine_url" || {
            error "Failed to download Alpine rootfs"
            exit 1
        }
    fi
    
    log "Extracting Alpine rootfs..."
    tar -xzf "$download_path" -C "$ROOTFS_DIR"
    
    log "Alpine rootfs extracted"
}

# Configure Alpine repositories
configure_repos() {
    log "Configuring Alpine repositories..."
    
    local repos_file="${ROOTFS_DIR}/etc/apk/repositories"
    
    cat > "$repos_file" << EOF
${ALPINE_MIRROR}/v${ALPINE_VERSION}/main
${ALPINE_MIRROR}/v${ALPINE_VERSION}/community
EOF
}

# Install required packages
install_packages() {
    log "Installing required packages..."
    
    # Use chroot to install packages
    # We need to mount proc/sys for apk to work properly
    mount -t proc none "${ROOTFS_DIR}/proc" 2>/dev/null || true
    mount -t sysfs none "${ROOTFS_DIR}/sys" 2>/dev/null || true
    mount --bind /dev "${ROOTFS_DIR}/dev" 2>/dev/null || true
    
    # Update package index
    chroot "$ROOTFS_DIR" apk update
    
    # Install essential packages for chroot-booter
    local packages="
        busybox
        busybox-suid
        busybox-initscripts
        alpine-baselayout
        musl
        libc6-compat
        ca-certificates
        openssl
        curl
        wget
        iputils
        iproute2
        dhclient
        udhcpc
        kbd-bkeymaps
        kbd
        evtest
        util-linux
        coreutils
        tar
        gzip
        squashfs-tools
        parted
        e2fsprogs
        dosfstools
        ntfs-3g
        nfs-utils
        cifs-utils
        rsync
        bash
        ncurses
        findmnt
        blkid
        lsblk
        mount
        umount
        modprobe
        depmod
        lsmod
        insmod
        rmmod
        dmidecode
        pciutils
        usbutils
        hdparm
        sdparm
        smartmontools
        nvme-cli
        ethtool
        tcpdump
        nmap
        iperf
        bridge-utils
        vlan
        bonding
        ifupdown-ng
        openrc
        eudev
        kmod
    "
    
    # Install packages
    chroot "$ROOTFS_DIR" apk add --no-cache $packages || {
        error "Failed to install packages"
        exit 1
    }
    
    log "Packages installed"
}

# Copy bootstrap scripts
copy_bootstrap_scripts() {
    log "Copying bootstrap scripts..."
    
    # Copy init and other scripts
    cp "${BOOTSTRAP_DIR}/init" "${ROOTFS_DIR}/init"
    chmod +x "${ROOTFS_DIR}/init"
    
    cp "${BOOTSTRAP_DIR}/chroot-loader.sh" "${ROOTFS_DIR}/bin/"
    chmod +x "${ROOTFS_DIR}/bin/chroot-loader.sh"
    
    cp "${BOOTSTRAP_DIR}/hotkey-daemon.sh" "${ROOTFS_DIR}/bin/"
    chmod +x "${ROOTFS_DIR}/bin/hotkey-daemon.sh"
    
    cp "${BOOTSTRAP_DIR}/return-handler.sh" "${ROOTFS_DIR}/bin/"
    chmod +x "${ROOTFS_DIR}/bin/return-handler.sh"
    
    log "Bootstrap scripts copied"
}

# Create additional directories
create_directories() {
    log "Creating additional directories..."
    
    mkdir -p "${ROOTFS_DIR}/newroot"
    mkdir -p "${ROOTFS_DIR}/mnt"
    mkdir -p "${ROOTFS_DIR}/var/run"
    mkdir -p "${ROOTFS_DIR}/var/log"
    mkdir -p "${ROOTFS_DIR}/tmp"
    mkdir -p "${ROOTFS_DIR}/root"
    
    log "Directories created"
}

# Set up device nodes
setup_devices() {
    log "Setting up device nodes..."
    
    # Create essential device nodes if they don't exist
    if [[ ! -e "${ROOTFS_DIR}/dev/console" ]]; then
        mknod -m 622 "${ROOTFS_DIR}/dev/console" c 5 1 2>/dev/null || true
        mknod -m 666 "${ROOTFS_DIR}/dev/null" c 1 3 2>/dev/null || true
        mknod -m 666 "${ROOTFS_DIR}/dev/zero" c 1 5 2>/dev/null || true
        mknod -m 666 "${ROOTFS_DIR}/dev/random" c 1 8 2>/dev/null || true
        mknod -m 666 "${ROOTFS_DIR}/dev/urandom" c 1 9 2>/dev/null || true
        mknod -m 666 "${ROOTFS_DIR}/dev/tty" c 5 0 2>/dev/null || true
    fi
    
    log "Device nodes created"
}

# Create initramfs image
create_initramfs() {
    log "Creating initramfs image..."
    
    local output_file="${OUTPUT_DIR}/${INITRAMFS_NAME}.cpio.gz"
    
    # Unmount chroot filesystems
    umount "${ROOTFS_DIR}/proc" 2>/dev/null || true
    umount "${ROOTFS_DIR}/sys" 2>/dev/null || true
    umount "${ROOTFS_DIR}/dev" 2>/dev/null || true
    
    # Create cpio archive
    (
        cd "$ROOTFS_DIR"
        find . -print0 | cpio --null -o --format=newc | gzip -9 > "$output_file"
    )
    
    local size
    size=$(du -h "$output_file" | cut -f1)
    
    log "Initramfs created: $output_file"
    log "Size: $size"
}

# Create kernel config
create_kernel_config() {
    log "Creating kernel configuration..."
    
    local config_file="${OUTPUT_DIR}/kernel-config-minimal.txt"
    
    cat > "$config_file" << 'EOF'
# Minimal kernel configuration for Chroot Booter
# These options are required or recommended for PXE boot and chroot operations

# Essential settings
CONFIG_BLK_DEV_INITRD=y
CONFIG_INITRAMFS_SOURCE=""

# PXE/Network boot
CONFIG_NET=y
CONFIG_INET=y
CONFIG_PACKET=y
CONFIG_NET_BOOT=y
CONFIG_CMDLINE_BOOL=y
CONFIG_CMDLINE=""

# Ethernet drivers (add more as needed)
CONFIG_NETDEVICES=y
CONFIG_ETHERNET=y
CONFIG_E1000=y
CONFIG_E1000E=y
CONFIG_IGB=y
CONFIG_TIGON3=y
CONFIG_R8169=y
CONFIG_VIRTIO_NET=y
CONFIG_VMXNET3=y
CONFIG_BNX2=y
CONFIG_BNX2X=y
CONFIG_IXGBE=y

# Network protocols
CONFIG_IP_PNP=y
CONFIG_IP_PNP_DHCP=y
CONFIG_IP_PNP_BOOTP=y
CONFIG_IP_PNP_RARP=y

# Filesystems
CONFIG_EXT4_FS=y
CONFIG_EXT4_USE_FOR_EXT2=y
CONFIG_SQUASHFS=y
CONFIG_SQUASHFS_XZ=y
CONFIG_SQUASHFS_LZO=y
CONFIG_OVERLAY_FS=y
CONFIG_NFS_FS=y
CONFIG_NFS_V3=y
CONFIG_NFS_V4=y
CONFIG_CIFS=y
CONFIG_TMPFS=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y

# Block devices
CONFIG_BLK_DEV=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_BLK_DEV_RAM=y
CONFIG_BLK_DEV_RAM_COUNT=16
CONFIG_BLK_DEV_RAM_SIZE=65536

# SCSI/SATA/NVMe
CONFIG_SCSI=y
CONFIG_BLK_MQ_PCI=y
CONFIG_SATA_AHCI=y
CONFIG_SATA_NV=y
CONFIG_NVME_CORE=y
CONFIG_NVME_FABRICS=y
CONFIG_NVME_FC=y
CONFIG_NVME_TCP=y
CONFIG_NVME_TARGET=y

# USB support
CONFIG_USB=y
CONFIG_USB_STORAGE=y
CONFIG_USB_XHCI_HCD=y
CONFIG_USB_EHCI_HCD=y
CONFIG_USB_UHCI_HCD=y
CONFIG_USB_OHCI_HCD=y

# Input/Keyboard
CONFIG_INPUT=y
CONFIG_INPUT_KEYBOARD=y
CONFIG_KEYBOARD_ATKBD=y
CONFIG_INPUT_MISC=y

# Console
CONFIG_VT=y
CONFIG_CONSOLE_TRANSLATIONS=y
CONFIG_VT_CONSOLE=y
CONFIG_HW_CONSOLE=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_TTY_PRINTK=y

# ACPI
CONFIG_ACPI=y
CONFIG_ACPI_BUTTON=y

# Virtualization support
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_VIRTIO_INPUT=y

# Debugging
CONFIG_MAGIC_SYSRQ=y
CONFIG_DEBUG_KERNEL=n
EOF

    log "Kernel configuration guide created: $config_file"
}

# Create PXE boot files
create_pxe_files() {
    log "Creating PXE configuration files..."
    
    local ipxe_script="${OUTPUT_DIR}/boot.ipxe"
    
    cat > "$ipxe_script" << EOF
#!ipxe
# Chroot Booter iPXE script
# This script boots the chroot-booter bootstrap image

# Network configuration (optional - can use DHCP)
# set net0/ip 192.168.1.100
# set net0/netmask 255.255.255.0
# set net0/gateway 192.168.1.1
# set dns 8.8.8.8

# Use DHCP by default
dhcp

echo "Loading Chroot Booter..."
echo "Server: \${next-server}"

# Load kernel
kernel http://\${next-server}/chroot-booter/vmlinuz \
    initrd=initramfs.img \
    image_url=http://\${next-server}/images/rocky-linux-8.tar.gz \
    console=tty0 \
    console=ttyS0,115200n8

# Load initramfs
initrd http://\${next-server}/chroot-booter/initramfs.img

# Boot
boot
EOF

    # Create GRUB config
    local grub_config="${OUTPUT_DIR}/grub.cfg"
    
    cat > "$grub_config" << 'EOF'
# GRUB2 configuration for Chroot Booter
# Place in /var/lib/tftpboot/grub/grub.cfg or similar

menuentry "Chroot Booter (Interactive)" {
    linux /chroot-booter/vmlinuz initrd=initramfs.img console=tty0 console=ttyS0,115200n8
    initrd /chroot-booter/initramfs.img
}

menuentry "Chroot Booter (Auto-load Rocky Linux)" {
    linux /chroot-booter/vmlinuz initrd=initramfs.img image_url=http://YOUR_SERVER/images/rocky-linux-8.tar.gz console=tty0 console=ttyS0,115200n8
    initrd /chroot-booter/initramfs.img
}

menuentry "Chroot Booter (Debug Mode)" {
    linux /chroot-booter/vmlinuz initrd=initramfs.img bootstrap_debug console=tty0 console=ttyS0,115200n8
    initrd /chroot-booter/initramfs.img
}
EOF

    log "PXE configuration files created"
}

# Create README
create_readme() {
    log "Creating README..."
    
    local readme="${OUTPUT_DIR}/README.txt"
    
    cat > "$readme" << EOF
Chroot Booter - Bootstrap Image
================================

This directory contains the chroot-booter bootstrap initramfs and configuration.

Files:
  - ${INITRAMFS_NAME}.cpio.gz    : The bootstrap initramfs image
  - boot.ipxe                    : iPXE boot script
  - grub.cfg                     : GRUB2 PXE configuration
  - kernel-config-minimal.txt    : Recommended kernel configuration

Installation:
1. Copy the initramfs and kernel to your PXE/HTTP server:
   - ${INITRAMFS_NAME}.cpio.gz -> /var/www/html/chroot-booter/initramfs.img
   - vmlinuz (kernel)          -> /var/www/html/chroot-booter/vmlinuz

2. Configure your DHCP/TFTP server to use the appropriate bootloader config

3. Test PXE boot

Usage:
  - Boot into the bootstrap console
  - Use 'load <url>' to fetch and boot an image
  - Press Ctrl+Alt+F12 to return to bootstrap from target
  - Use 'status' to check current state
  - Use 'help' for full command list

Image Format:
  Target images should be:
  - .tar.gz archives of a root filesystem, OR
  - .squashfs compressed filesystem images
  - Accessible via HTTP

See docs/ for full documentation.
EOF

    log "README created"
}

# Cleanup build artifacts
cleanup() {
    log "Cleaning up..."
    
    # Unmount any remaining mounts
    umount "${ROOTFS_DIR}/proc" 2>/dev/null || true
    umount "${ROOTFS_DIR}/sys" 2>/dev/null || true
    umount "${ROOTFS_DIR}/dev" 2>/dev/null || true
    
    log "Cleanup complete"
}

# Main build process
main() {
    log "Chroot Booter Build Script"
    log "=========================="
    
    parse_args "$@"
    
    info "Alpine Version: $ALPINE_VERSION"
    info "Architecture: $ALPINE_ARCH"
    info "Output Directory: $OUTPUT_DIR"
    
    setup_dirs
    download_alpine
    configure_repos
    install_packages
    copy_bootstrap_scripts
    create_directories
    setup_devices
    create_initramfs
    create_kernel_config
    create_pxe_files
    create_readme
    cleanup
    
    log ""
    log "=========================================="
    log "Build Complete!"
    log "=========================================="
    log ""
    log "Output files:"
    ls -lh "$OUTPUT_DIR"
    log ""
    log "Next steps:"
    log "1. Copy initramfs and kernel to your PXE server"
    log "2. Configure DHCP/PXE boot"
    log "3. Test the bootstrap image"
    log ""
}

# Run main
trap cleanup EXIT
main "$@"
