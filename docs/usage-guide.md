# Chroot Booter - Usage Guide

## Quick Start

### 1. Build the Bootstrap Initramfs

```bash
cd chroot_booter
chmod +x tools/build-initramfs.sh
sudo ./tools/build-initramfs.sh
```

This creates:
- `output/chroot-booter-initramfs.cpio.gz` - The bootstrap image
- `output/boot.ipxe` - iPXE boot script
- `output/grub.cfg` - GRUB2 configuration
- `output/kernel-config-minimal.txt` - Recommended kernel config

### 2. Setup PXE Server

#### Option A: Using Dnsmasq (Recommended)

```bash
# Install dnsmasq
sudo apt-get install dnsmasq  # Debian/Ubuntu
sudo yum install dnsmasq      # RHEL/CentOS

# Copy PXE config
sudo cp pxe-config/dnsmasq-example.conf /etc/dnsmasq.d/chroot-booter

# Edit and adjust IP ranges for your network
sudo nano /etc/dnsmasq.d/chroot-booter

# Copy bootstrap files
sudo mkdir -p /var/lib/tftpboot/chroot-booter
sudo mkdir -p /var/www/html/chroot-booter
sudo cp output/chroot-booter-initramfs.cpio.gz /var/lib/tftpboot/chroot-booter/initramfs.img
sudo cp output/chroot-booter-initramfs.cpio.gz /var/www/html/chroot-booter/initramfs.img

# You'll need to provide a kernel (vmlinuz)
# Download from your distro or use existing PXE kernel
sudo cp /path/to/vmlinuz /var/lib/tftpboot/chroot-booter/
sudo cp /path/to/vmlinuz /var/www/html/chroot-booter/

# Restart dnsmasq
sudo systemctl restart dnsmasq
```

#### Option B: Using GRUB2 for UEFI

```bash
# Install GRUB2 for EFI
sudo apt-get install grub-efi-amd64-bin

# Create GRUB network boot directory
sudo mkdir -p /var/lib/tftpboot/grub

# Copy configuration
sudo cp pxe-config/grub-netboot.cfg /var/lib/tftpboot/grub/grub.cfg

# Edit server IP in the config
sudo nano /var/lib/tftpboot/grub/grub.cfg

# Copy GRUB EFI binary
sudo cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed \
        /var/lib/tftpboot/grubx64.efi

# Setup TFTP server (e.g., tftpd-hpa)
sudo apt-get install tftpd-hpa
sudo systemctl start tftpd-hpa
```

### 3. Prepare OS Images

Place your OS images on the HTTP server:

```bash
# Create image directory
sudo mkdir -p /var/www/html/images

# Example: Copy Rocky Linux image
sudo cp rocky-linux-8.tar.gz /var/www/html/images/

# Set permissions
sudo chmod 644 /var/www/html/images/*
```

**Image formats supported:**
- `.tar.gz` - Gzipped tarball of root filesystem
- `.squashfs` - Squashfs compressed filesystem

## Using Chroot Booter

### Interactive Mode

After PXE boot, you'll see the bootstrap prompt:

```
========================================
  Chroot Booter - Bootstrap Console
========================================

Available commands:
  load <url>     - Load and boot image from URL
  return         - Return to bootstrap (if in target)
  status         - Show current bootstrap status
  shell          - Drop to shell
  reboot         - Reboot system
  poweroff       - Power off system

Hotkey: Ctrl+Alt+F12 = Return to bootstrap

[bootstrap] # 
```

### Loading an Image

```bash
# Load Rocky Linux 8
[bootstrap] # load http://192.168.1.10/images/rocky-linux-8.tar.gz

# Load with custom URL
[bootstrap] # load http://my-server.local/images/custom-image.squashfs
```

The system will:
1. Download the image
2. Mount/extract it
3. Pivot into the target system
4. Start the target's init system

### Returning to Bootstrap

**Method 1: Hotkey (Recommended)**
- Press `Ctrl+Alt+F12` on the keyboard
- The system will unmount the target and return to bootstrap

**Method 2: Serial Console**
- Send the string `RETURN_TO_BOOTSTRAP` over serial
- Useful for remote management

**Method 3: From Target System**
- If you're logged into the target, run:
```bash
/.bootstrap-return
```

**Method 4: SysRq (Emergency)**
- `Alt+SysRq+B` will reboot the system (use with caution)

### Checking Status

```bash
[bootstrap] # status

Current phase: bootstrap
Boot time: Thu Feb 12 14:30:00 UTC 2025
Last image: http://192.168.1.10/images/rocky-linux-8.tar.gz
```

### Auto-loading Images

You can configure automatic image loading via kernel command line:

```
image_url=http://192.168.1.10/images/rocky-linux-8.tar.gz
```

Add this to your PXE configuration:

```bash
# In GRUB config
linux /chroot-booter/vmlinuz initrd=initramfs.img image_url=http://192.168.1.10/images/rocky-linux-8.tar.gz

# In PXELINUX
APPEND initrd=chroot-booter/initramfs.img image_url=http://192.168.1.10/images/rocky-linux-8.tar.gz
```

### Debug Mode

Enable debug output:

```bash
# Via kernel command line
bootstrap_debug

# This shows detailed output during init
```

## Creating OS Images

### Rocky Linux 8/9

**Method 1: From Container**

```bash
# Create rootfs directory
mkdir -p /tmp/rocky-root

# Bootstrap minimal system
dnf --installroot=/tmp/rocky-root \
    --releasever=8 \
    --repo=baseos \
    --repo=appstream \
    install -y \
    @minimal \
    systemd \
    NetworkManager \
    vim \
    bash

# Create tarball
tar -czf rocky-linux-8.tar.gz -C /tmp/rocky-root .

# Copy to HTTP server
sudo cp rocky-linux-8.tar.gz /var/www/html/images/
```

**Method 2: Using Docker/Podman**

```bash
# Export container filesystem
docker export $(docker create rockylinux:8) > rocky-8.tar

# Compress
gzip rocky-8.tar

# Rename
mv rocky-8.tar.gz rocky-linux-8.tar.gz
```

### Debian/Ubuntu

```bash
# Bootstrap Debian
mkdir -p /tmp/debian-root
debootstrap bookworm /tmp/debian-root http://deb.debian.org/debian

# Create tarball
tar -czf debian-12.tar.gz -C /tmp/debian-root .
```

### Custom Images

For custom images, ensure they have:

1. **Init system** at one of:
   - `/sbin/init`
   - `/bin/init`
   - `/usr/sbin/init`
   - `/usr/bin/init`

2. **Basic utilities**:
   - shell (bash, sh)
   - mount/umount
   - network tools (if network needed)

3. **Proper directory structure**:
   - Standard FHS layout
   - /proc, /sys, /dev will be mounted by bootstrap

## Advanced Usage

### Serial Console Access

Connect via serial for headless operation:

```bash
# Add to kernel cmdline
console=ttyS0,115200n8

# Then connect from another machine
screen /dev/ttyUSB0 115200
# or
minicom -D /dev/ttyUSB0 -b 115200
```

### Network Configuration

The bootstrap uses DHCP by default. To use static IP:

```bash
# Drop to shell
[bootstrap] # shell

# Configure manually
ip addr add 192.168.1.50/24 dev eth0
ip link set eth0 up
ip route add default via 192.168.1.1

# Edit resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# Return to bootstrap menu
exit
```

### Image Caching

For faster repeated testing:

```bash
# Images are downloaded to /mnt/images/
# After first download, you can reload without re-downloading

# Check downloaded images
ls /mnt/images/

# To manually reload last image
[bootstrap] # load $(cat /var/run/bootstrap/last_image_url)
```

### Multiple Image Testing Workflow

```bash
# Test Rocky Linux 8
[bootstrap] # load http://server/images/rocky-8.tar.gz
# ... test the system ...
# Press Ctrl+Alt+F12 to return

# Test Rocky Linux 9
[bootstrap] # load http://server/images/rocky-9.tar.gz
# ... test the system ...
# Press Ctrl+Alt+F12 to return

# Test Debian
[bootstrap] # load http://server/images/debian-12.tar.gz
# ... test the system ...
# Press Ctrl+Alt+F12 to return

# All done
[bootstrap] # poweroff
```

## Troubleshooting

### Bootstrap hangs at "Loading kernel"

**Problem:** Kernel panic or missing drivers

**Solutions:**
1. Check kernel has network drivers for your hardware
2. Verify initramfs is not corrupted
3. Enable debug mode: `bootstrap_debug`

### "Cannot access URL" error

**Problem:** Network not working

**Solutions:**
```bash
# Check network interface
ip link show

# Check if interface is up
ip link set eth0 up

# Try DHCP manually
udhcpc -i eth0

# Test connectivity
ping 8.8.8.8
wget --spider http://your-server/
```

### Image download fails

**Problem:** HTTP server not accessible

**Solutions:**
1. Verify URL is correct
2. Check HTTP server is running
3. Check firewall rules
4. Try from another machine: `curl -I http://server/images/test.tar.gz`

### Target won't boot after pivot

**Problem:** Image incompatible or missing init

**Solutions:**
1. Verify image has /sbin/init
2. Check image architecture matches kernel (x86_64 vs aarch64)
3. Try different image format (tar vs squashfs)
4. Check kernel logs before pivot

### Return doesn't work

**Problem:** Hotkey not detected or target unmount fails

**Solutions:**
1. Verify hotkey daemon is running: `ps | grep hotkey`
2. Check current phase: `cat /var/run/bootstrap/current_phase`
3. Try serial console method
4. Emergency: `Alt+SysRq+B` to reboot

### Keyboard not working in target

**Problem:** Input drivers missing

**Solutions:**
1. Ensure target has keyboard drivers
2. Use serial console instead
3. Add keyboard modules to kernel

## Tips and Best Practices

### 1. Use Squashfs for Faster Loading

Squashfs images mount instantly without extraction:

```bash
# Create squashfs image
mksquashfs rootfs/ image.squashfs -comp xz
```

### 2. Keep Images Small

Remove unnecessary packages to speed up downloads:

```bash
# Remove docs
rm -rf /usr/share/doc/* /usr/share/man/*

# Remove caches
rm -rf /var/cache/*

# Remove logs
rm -rf /var/log/*
```

### 3. Use Image Templates

Create base images and customize:

```bash
# Create base image
tar -czf rocky-base.tar.gz -C /tmp/rocky-root .

# For testing, mount base and add customizations
mkdir -p /mnt/base /mnt/custom
tar -xzf rocky-base.tar.gz -C /mnt/base
cp -a /mnt/base/* /mnt/custom/
# ... add customizations ...
tar -czf rocky-custom.tar.gz -C /mnt/custom .
```

### 4. Document Image Contents

Create a README for each image:

```bash
cat > /var/www/html/images/rocky-8.README << EOF
Rocky Linux 8
==============
- Created: 2025-02-12
- Kernel: 4.18.0
- Size: 450MB
- Includes: @minimal, systemd, NetworkManager
- Username: root (no password)
EOF
```

### 5. Test Images Before Deployment

```bash
# Local test with chroot (on Linux machine)
sudo mkdir -p /mnt/test-image
sudo tar -xzf rocky-8.tar.gz -C /mnt/test-image
sudo chroot /mnt/test-image /bin/bash
# Test commands...
exit
sudo umount /mnt/test-image
```

## Examples

### Example 1: Testing Different OS Versions

```bash
# Setup PXE boot
# ... boot into chroot-booter ...

# Test Rocky 8
load http://server/images/rocky-8.tar.gz
# Run tests...
# Ctrl+Alt+F12

# Test Rocky 9
load http://server/images/rocky-9.tar.gz
# Run tests...
# Ctrl+Alt+F12

# Test AlmaLinux
load http://server/images/alma-9.tar.gz
# Run tests...
# Ctrl+Alt+F12

poweroff
```

### Example 2: Hardware Validation

```bash
# Load diagnostic image
load http://server/images/diagnostic.tar.gz

# Run hardware tests
lspci
lsusb
dmidecode
smartctl -a /dev/sda
memtester 1024M 1

# Return to bootstrap
Ctrl+Alt+F12

# Load actual OS
load http://server/images/production.tar.gz
```

### Example 3: Automated Testing

Create a custom image with test scripts:

```bash
# In target system (before creating image)
cat > /root/run-tests.sh << 'EOF'
#!/bin/bash
echo "Running automated tests..."
./test-network.sh
./test-disk.sh
./test-memory.sh
echo "Tests complete. Returning to bootstrap..."
/.bootstrap-return
EOF
chmod +x /root/run-tests.sh

# Enable autostart
cat > /etc/systemd/system/test-runner.service << EOF
[Unit]
Description=Test Runner
After=network.target

[Service]
Type=oneshot
ExecStart=/root/run-tests.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl enable test-runner
```

## Getting Help

If you encounter issues:

1. Check the logs: `dmesg` or `cat /var/log/messages`
2. Review architecture.md for technical details
3. Enable debug mode: `bootstrap_debug`
4. Check GitHub issues (if applicable)
5. Include in bug reports:
   - Kernel version
   - Hardware details
   - Image format and size
   - Exact error messages
