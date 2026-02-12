# Chroot Booter

A PXE-bootable bootstrap system for testing OS images on bare metal with the unique ability to **return to the bootstrap** after pivoting into a target system.

## The Problem

Traditional PXE boot systems require a full reboot to switch between different OS images. This is time-consuming when:
- Testing multiple OS versions on the same hardware
- Validating different configurations
- Running iterative tests that require fresh systems

## The Solution

Chroot Booter stays resident in memory after booting. You can:
1. PXE boot into the lightweight bootstrap
2. Load an OS image over HTTP
3. Pivot into that OS and test it
4. **Press Ctrl+Alt+F12 to instantly return to bootstrap**
5. Load a different image without rebooting

## Features

- **Zero-touch return**: Hotkey (Ctrl+Alt+F12) instantly returns to bootstrap
- **Multiple image formats**: Supports .tar.gz and .squashfs images
- **HTTP-based**: Images fetched over HTTP from your existing PXE server
- **Interactive or automated**: Manual console or auto-load via kernel cmdline
- **Serial console support**: Remote return via serial magic string
- **Bare metal optimized**: Minimal memory footprint (~100MB bootstrap)

## Quick Start

### 1. Build the Bootstrap

```bash
chmod +x tools/build-initramfs.sh
sudo ./tools/build-initramfs.sh
```

### 2. Deploy to PXE Server

```bash
# Copy to your PXE/HTTP server
sudo cp output/chroot-booter-initramfs.cpio.gz /var/www/html/chroot-booter/initramfs.img
sudo cp /path/to/vmlinuz /var/www/html/chroot-booter/
sudo cp output/boot.ipxe /var/www/html/chroot-booter/
```

### 3. Configure DHCP/PXE

See `pxe-config/` for examples:
- `dnsmasq-example.conf` - Dnsmasq DHCP/TFTP configuration
- `grub-netboot.cfg` - GRUB2 UEFI network boot config
- `pxelinux-example.cfg` - Legacy PXELINUX configuration

### 4. Prepare OS Images

```bash
# Place your OS images on the HTTP server
sudo mkdir -p /var/www/html/images
sudo cp rocky-linux-8.tar.gz /var/www/html/images/
sudo cp rocky-linux-9.tar.gz /var/www/html/images/
```

### 5. Boot and Test

```
# After PXE boot, you'll see:
[bootstrap] # load http://your-server/images/rocky-linux-8.tar.gz
# ... system pivots into Rocky Linux 8 ...
# ... run your tests ...
# Press Ctrl+Alt+F12
# ... instant return to bootstrap ...
[bootstrap] # load http://your-server/images/rocky-linux-9.tar.gz
# ... test Rocky 9 ...
# Press Ctrl+Alt+F12
[bootstrap] # poweroff
```

## Project Structure

```
chroot_booter/
├── bootstrap/              # Bootstrap initramfs scripts
│   ├── init               # Main init (PID 1)
│   ├── chroot-loader.sh   # Image loading and pivot
│   ├── hotkey-daemon.sh   # Keyboard monitoring
│   └── return-handler.sh  # Return-to-bootstrap logic
├── tools/
│   └── build-initramfs.sh # Build script
├── pxe-config/            # PXE configuration examples
│   ├── dnsmasq-example.conf
│   ├── grub-netboot.cfg
│   └── pxelinux-example.cfg
├── docs/
│   ├── architecture.md    # Technical architecture
│   └── usage-guide.md     # Detailed usage guide
├── build/                 # Build artifacts (generated)
└── output/                # Output files (generated)
    ├── chroot-booter-initramfs.cpio.gz
    ├── boot.ipxe
    └── grub.cfg
```

## Documentation

- **[Architecture](docs/architecture.md)** - Technical design, boot flow, and component details
- **[Usage Guide](docs/usage-guide.md)** - Complete usage instructions, troubleshooting, and examples
- **[VM Testing Guide](docs/vm-testing-guide.md)** - Step-by-step guide for testing in virtual machines

## Testing Without Bare Metal

Don't have spare bare metal hardware? No problem! You can test Chroot Booter entirely in virtual machines:

```bash
# See the VM Testing Guide for complete instructions
cat docs/vm-testing-guide.md
```

**Quick VM Setup:**
1. Use Vagrant to automatically provision PXE server and test clients
2. Or manually configure VirtualBox/KVM VMs
3. Test the full PXE boot → load image → return → load another flow
4. Perfect for development and CI/CD integration

See **[VM Testing Guide](docs/vm-testing-guide.md)** for detailed instructions.

## How It Works

### The Pivot and Return Mechanism

1. **Bootstrap loads into initramfs** (memory-based filesystem)
2. **Target image is downloaded** to /mnt/images/
3. **Image is mounted/extracted** to /newroot
4. **pivot_root** swaps /newroot to become /
5. **Target init starts** running the OS
6. **Hotkey daemon monitors** for Ctrl+Alt+F12
7. **On hotkey**: Unmount target, cleanup, return to bootstrap shell

The key insight is that the initramfs stays in memory (accessible via /oldroot after pivot), allowing us to reverse the pivot operation.

## Requirements

### Server Side
- Existing PXE/DHCP server (dnsmasq, ISC DHCP, etc.)
- HTTP server for images
- TFTP server for boot files

### Client Side (Bootstrap)
- x86_64 or aarch64 system
- 2GB+ RAM recommended
- Network interface with PXE support
- Kernel with network drivers for your hardware

### Target Images
- Rocky Linux, Debian, or any Linux distribution
- Must have init system at /sbin/init or similar
- Formats: .tar.gz (extracted) or .squashfs (mounted)

## Image Format Examples

### Rocky Linux 8
```bash
# Bootstrap minimal system
dnf --installroot=/tmp/rocky-root --releasever=8 \
    install -y @minimal systemd NetworkManager

# Create tarball
tar -czf rocky-linux-8.tar.gz -C /tmp/rocky-root .
```

### Squashfs (Faster)
```bash
mksquashfs rootfs/ image.squashfs -comp xz
```

## Bootstrap Commands

```
load <url>      - Download and boot image from URL
return          - Return to bootstrap (when in target)
status          - Show bootstrap status
shell           - Drop to shell
reboot          - Reboot system
poweroff        - Power off system
help            - Show help
```

## Return Methods

1. **Hotkey**: Ctrl+Alt+F12 (from keyboard)
2. **Serial**: Send "RETURN_TO_BOOTSTRAP" over serial console
3. **Command**: Run `/.bootstrap-return` from within target
4. **Menu**: Use `return` command in bootstrap console

## Kernel Command Line Options

```
image_url=http://server/image.tar.gz  # Auto-load image
bootstrap_debug                       # Enable debug output
console=ttyS0,115200n8               # Serial console
```

## Testing Workflow Example

```
# Boot into chroot-booter via PXE
[bootstrap] # load http://server/images/rocky-8-base.tar.gz

# System boots Rocky 8
[root@target ~]# uname -a
Linux target 4.18.0-xxx.el8.x86_64 ...

# Run tests...
[root@target ~]# ./run-validation.sh

# Return to bootstrap (Ctrl+Alt+F12)

[bootstrap] # load http://server/images/rocky-8-updated.tar.gz

# Test updated version...

# Return to bootstrap (Ctrl+Alt+F12)

[bootstrap] # load http://server/images/rocky-9.tar.gz

# Test Rocky 9...

# Done
[bootstrap] # poweroff
```

## Troubleshooting

### Bootstrap won't boot
- Check kernel has initramfs support (`CONFIG_BLK_DEV_INITRD`)
- Verify network drivers are included in kernel
- Enable debug: add `bootstrap_debug` to kernel cmdline

### Cannot load image
- Verify network is up: `ip addr`
- Test URL: `wget --spider http://server/image.tar.gz`
- Check firewall and HTTP server logs

### Return doesn't work
- Verify you're in target: `cat /var/run/bootstrap/current_phase`
- Check hotkey daemon: `ps | grep hotkey`
- Try serial method as fallback

See [Usage Guide](docs/usage-guide.md) for detailed troubleshooting.

## Limitations

- Images are loaded into RAM (tmpfs) - size limited by available memory
- Changes to target are lost on return (no persistence)
- Target must cleanly unmount for return to work
- Kernel must include drivers for target hardware

## Future Enhancements

- [ ] HTTPS support for image downloads
- [ ] Image caching to avoid re-downloads
- [ ] Checksum verification
- [ ] OverlayFS for persistent changes
- [ ] VNC/remote console support
- [ ] Image pre-validation

## Contributing

Contributions welcome! Areas of interest:
- Additional return methods (IPMI, custom hardware triggers)
- Image format support (Docker export, VM disk images)
- Performance optimizations
- Hardware compatibility reports

## License

MIT License - See LICENSE file

## Credits

Built with:
- Alpine Linux (minimal userspace)
- BusyBox (core utilities)
- Standard Linux pivot_root

## Support

- Documentation: `docs/`
- Issues: GitHub Issues
- Discussions: GitHub Discussions
