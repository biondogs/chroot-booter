# Chroot Booter - Architecture Documentation

## Overview

Chroot Booter is a PXE-bootable bootstrap system that enables rapid testing of OS images on bare metal hardware. Unlike traditional live boot or installation systems, Chroot Booter allows you to:

1. PXE boot a minimal bootstrap environment
2. Load an OS image over HTTP
3. Pivot into that image (chroot + pivot_root)
4. Test the OS as if it were natively installed
5. **Return to the bootstrap** without rebooting
6. Load a different image and test again

This return-to-bootstrap capability is the key differentiator from other PXE boot systems.

## Architecture

### Boot Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                        PXE BOOT SEQUENCE                         │
└─────────────────────────────────────────────────────────────────┘

  ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
  │   DHCP   │────▶│  TFTP/   │────▶│  Kernel  │────▶│ Bootstrap│
  │ Request  │     │  HTTP    │     │  + Init  │     │   Init   │
  └──────────┘     └──────────┘     └──────────┘     └──────────┘
                                                           │
                           ┌─────────────────────────────────┘
                           │
                           ▼
                    ┌──────────────┐
                    │  Bootstrap   │
                    │  Interactive │
                    │    Shell     │
                    └──────────────┘
                           │
              ┌────────────┴────────────┐
              │                         │
              ▼                         ▼
      ┌──────────────┐          ┌──────────────┐
      │  User loads  │          │  Auto-load   │
      │ image via    │          │ from kernel  │
      │ 'load <url>' │          │ cmdline      │
      └──────────────┘          └──────────────┘
              │                         │
              └────────────┬────────────┘
                           ▼
                    ┌──────────────┐
                    │  Download    │
                    │  Image via   │
                    │    HTTP      │
                    └──────────────┘
                           │
                           ▼
                    ┌──────────────┐
                    │ Mount/Extract│
                    │   Image to   │
                    │   /newroot   │
                    └──────────────┘
                           │
                           ▼
                    ┌──────────────┐
                    │  pivot_root  │
                    │              │
                    │ /newroot → / │
                    │ / → /oldroot │
                    └──────────────┘
                           │
                           ▼
                    ┌──────────────┐
                    │   Target     │
                    │   System     │
                    │   Running    │
                    └──────────────┘
                           │
                           │ (User presses
                           │  Ctrl+Alt+F12)
                           ▼
                    ┌──────────────┐
                    │   Signal     │
                    │   Return     │
                    └──────────────┘
                           │
                           ▼
                    ┌──────────────┐
                    │  Unmount     │
                    │  Target FS   │
                    └──────────────┘
                           │
                           ▼
                    ┌──────────────┐
                    │ Return to    │
                    │ Bootstrap    │
                    └──────────────┘
```

### Key Components

#### 1. Bootstrap Initramfs

The bootstrap runs entirely from an initramfs (initial RAM filesystem), which is loaded into memory by the kernel. This ensures:

- **Persistence**: The bootstrap environment survives pivot_root operations
- **Speed**: No disk I/O required after boot
- **Independence**: Not affected by target system state

**Structure:**
```
/init                    # Main init script (PID 1)
/bin/chroot-loader.sh   # Image loading and pivot
/bin/hotkey-daemon.sh   # Keyboard monitoring
/bin/return-handler.sh  # Return-to-bootstrap logic
/bin/busybox            # Core utilities
/usr/bin/wget           # HTTP downloads
/sbin/pivot_root        # Root pivoting
```

#### 2. Image Loading Process

The chroot-loader handles:

1. **URL Validation**: Checks if the HTTP endpoint is accessible
2. **Download**: Streams the image to local storage (/mnt/images/)
3. **Mount/Extract**: 
   - Squashfs images are mounted directly (read-only)
   - Tarballs are extracted to /newroot
4. **Virtual Filesystems**: Mounts /proc, /sys, /dev in target
5. **Return Mechanism**: Installs helper scripts for returning
6. **Pivot**: Executes pivot_root to swap into target

#### 3. Return Mechanism

The return-to-bootstrap feature uses multiple detection methods:

**Method 1: Hotkey Daemon**
- Runs in background monitoring input devices
- Detects Ctrl+Alt+F12 via /dev/input/event*
- Signals return via named pipe (FIFO)

**Method 2: Serial Console**
- Monitors serial ports for magic string "RETURN_TO_BOOTSTRAP"
- Useful for remote management

**Method 3: Target-side Helper**
- Creates /.bootstrap-return script in target
- Can be called from within target to signal return

**Return Sequence:**
1. Signal received via FIFO
2. Return handler unmounts target filesystems gracefully
3. Cleanup of state files
4. Bootstrap shell restarted
5. User can load new image

#### 4. State Management

State is tracked in `/var/run/bootstrap/`:

```
/var/run/bootstrap/
├── current_phase      # "bootstrap" or "target"
├── pid_in_target      # PID when in target (for detection)
├── last_image_url     # URL of last loaded image
└── boot_time          # Timestamp of initial boot
```

### Kernel Requirements

The bootstrap requires a kernel with:

**Required:**
- `CONFIG_BLK_DEV_INITRD` - Initramfs support
- `CONFIG_NET` - Networking
- `CONFIG_INET` - TCP/IP
- `CONFIG_IP_PNP_DHCP` - DHCP client
- `CONFIG_EXT4_FS` - Common root filesystem
- `CONFIG_DEVTMPFS` - Dynamic device nodes

**Recommended:**
- `CONFIG_SQUASHFS` - For squashfs images
- `CONFIG_OVERLAY_FS` - For overlay support
- `CONFIG_MAGIC_SYSRQ` - Emergency recovery
- Network drivers for target hardware

## Image Formats

### Supported Formats

1. **Squashfs (.squashfs)**
   - Read-only compressed filesystem
   - Fast to download and mount
   - Good for testing read-only scenarios
   - Create: `mksquashfs rootfs/ image.squashfs -comp xz`

2. **Tarball (.tar.gz, .tgz)**
   - Standard archive format
   - Extracted to tmpfs or disk
   - Good for writable root filesystems
   - Create: `tar -czf image.tar.gz -C rootfs/ .`

### Image Structure

Images should contain a complete root filesystem:

```
image-root/
├── bin/
├── boot/
├── dev/
├── etc/
│   └── init systems (systemd, openrc, etc.)
├── lib/
├── lib64/
├── proc/ (created at runtime)
├── root/
├── run/ (created at runtime)
├── sbin/
├── sys/ (created at runtime)
├── tmp/
├── usr/
└── var/
```

### Creating Rocky Linux Images

```bash
# Method 1: From running system
tar -czpf rocky-8.tar.gz \
    --exclude=/proc \
    --exclude=/sys \
    --exclude=/dev \
    --exclude=/run \
    --exclude=/boot \
    --exclude=/tmp \
    /

# Method 2: Using DNF bootstrap
dnf --installroot=/tmp/rocky-root \
    --releasever=8 \
    --repo=baseos \
    --repo=appstream \
    install -y \
    @minimal \
    kernel \
    systemd \
    NetworkManager

tar -czf rocky-8.tar.gz -C /tmp/rocky-root .
```

## Network Architecture

### PXE Server Layout

```
PXE/HTTP Server (192.168.1.10)
├── /var/lib/tftpboot/
│   ├── pxelinux.0          (for BIOS clients)
│   ├── grubx64.efi         (for UEFI clients)
│   ├── grub/
│   │   └── grub.cfg        (GRUB config)
│   └── chroot-booter/
│       ├── vmlinuz         (kernel)
│       └── initramfs.img   (bootstrap initramfs)
│
└── /var/www/html/          (HTTP server root)
    ├── chroot-booter/
    │   ├── vmlinuz
    │   ├── initramfs.img
    │   └── boot.ipxe       (iPXE script)
    └── images/
        ├── rocky-linux-8.tar.gz
        ├── rocky-linux-9.tar.gz
        └── debian-12.tar.gz
```

### Client Network Flow

1. **DHCP**: Client broadcasts DHCP Discover
2. **DHCP Offer**: Server provides IP and PXE options
3. **TFTP**: Client downloads bootloader (GRUB/PXELINUX)
4. **HTTP**: Bootloader downloads kernel and initramfs
5. **HTTP**: Bootstrap downloads target images

## Security Considerations

### Bootstrap Security

- Minimal attack surface (busybox-based)
- No persistent storage
- Read-only initramfs (in memory)
- No network services listening

### Image Integrity

- Images downloaded over HTTP (no TLS in minimal initramfs)
- **Recommendation**: Use internal trusted network
- **Future**: Add checksum verification

### Target Isolation

- Target runs in isolated chroot/pivot
- Bootstrap remains in memory
- Target cannot modify bootstrap

## Limitations

1. **Memory Requirements**: 
   - Bootstrap: ~100MB
   - Each loaded image: Depends on image size
   - Recommend: 2GB+ RAM for comfortable operation

2. **No Persistent State**:
   - Changes to target are lost on return
   - Target runs from RAM or read-only media

3. **Single Return Point**:
   - Can only return to bootstrap, not to previous target state
   - Target must be clean for return to work reliably

4. **Hardware Drivers**:
   - Kernel must include drivers for target hardware
   - Bootstrap includes common drivers but may miss specialized hardware

## Future Enhancements

1. **Overlay Support**: Allow persistent changes to images
2. **HTTPS Downloads**: Add TLS support for image downloads
3. **Image Caching**: Cache downloaded images locally
4. **Checksum Verification**: Verify image integrity
5. **Serial Console Trigger**: More robust serial detection
6. **VNC Support**: Remote console access
7. **Image Validation**: Pre-flight checks for image compatibility

## Troubleshooting

### Bootstrap won't boot

- Check kernel has required config options
- Verify initramfs was created correctly
- Check PXE configuration

### Cannot load image

- Verify network is up (check `ip addr`)
- Test URL with `wget` manually
- Check HTTP server logs

### Return doesn't work

- Verify hotkey daemon is running
- Check `/var/run/bootstrap/current_phase`
- Try serial console method as fallback

### Target won't start

- Verify image format (tar vs squashfs)
- Check image has valid init at /sbin/init
- Review kernel logs with `dmesg`

## References

- [Linux pivot_root documentation](https://man7.org/linux/man-pages/man2/pivot_root.2.html)
- [PXE specification](https://www.pix.net/software/pxeboot/archive/pxespec.pdf)
- [Alpine Linux initramfs](https://wiki.alpinelinux.org/wiki/Manually_editing_initramfs)
- [iPXE](https://ipxe.org/)
- [GRUB2 network boot](https://www.gnu.org/software/grub/manual/grub/html_node/Network.html)
