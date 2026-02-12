# Chroot Booter - Virtual Machine Testing Guide

This guide walks you through setting up a complete VM-based testing environment for Chroot Booter. You'll create a virtual network with a PXE/HTTP server and test clients, all within VMs.

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    VM TESTING ENVIRONMENT                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌─────────────────────┐        ┌─────────────────────┐         │
│  │   PXE/HTTP Server   │        │   Test Client VM    │         │
│  │   (Ubuntu/Rocky)    │◄──────►│   (Bare metal       │         │
│  │                     │  PXE   │    simulator)       │         │
│  │  • Dnsmasq (DHCP)   │        │                     │         │
│  │  • TFTP server      │        │  Boots via network  │         │
│  │  • HTTP server      │        │  Loads images       │         │
│  │  • OS images        │        │  Tests OS           │         │
│  │                     │        │                     │         │
│  │  IP: 192.168.100.10 │        │  IP: DHCP           │         │
│  └─────────────────────┘        └─────────────────────┘         │
│            ▲                                                      │
│            │                                                      │
│            └──────────────────────────────────────┐               │
│                                                   │               │
│                              ┌────────────────────┴───┐          │
│                              │   Virtual Network      │          │
│                              │   (NAT/Host-Only)      │          │
│                              │   192.168.100.0/24     │          │
│                              └────────────────────────┘          │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

### Host Machine Requirements
- **CPU**: 4+ cores recommended
- **RAM**: 8GB+ (4GB for server VM, 2GB+ per client VM)
- **Disk**: 50GB free space
- **OS**: Linux, macOS, or Windows with virtualization

### Software
- VirtualBox, VMware, or KVM/QEMU
- Vagrant (optional but recommended for automation)
- Git

## Method 1: Using Vagrant (Recommended)

### Step 1: Install Prerequisites

```bash
# macOS
brew install vagrant virtualbox

# Ubuntu/Debian
sudo apt-get update
sudo apt-get install vagrant virtualbox

# CentOS/RHEL/Fedora
sudo dnf install vagrant virtualbox
```

### Step 2: Create Vagrant Configuration

Create a `Vagrantfile` in your project directory:

```ruby
# Vagrantfile for Chroot Booter Testing
Vagrant.configure("2") do |config|
  
  # PXE/HTTP Server VM
  config.vm.define "pxe-server" do |server|
    server.vm.box = "generic/ubuntu2204"
    server.vm.hostname = "pxe-server"
    server.vm.network "private_network", ip: "192.168.100.10",
                      virtualbox__intnet: "pxe-network"
    
    server.vm.provider "virtualbox" do |vb|
      vb.name = "chroot-booter-pxe-server"
      vb.memory = "4096"
      vb.cpus = 2
    end
    
    server.vm.provision "shell", inline: <<-SHELL
      # Update system
      apt-get update
      apt-get upgrade -y
      
      # Install required packages
      apt-get install -y \
        dnsmasq \
        tftpd-hpa \
        apache2 \
        syslinux \
        syslinux-efi \
        grub-efi-amd64-bin \
        xorriso \
        curl \
        wget \
        git \
        bc
      
      # Create directory structure
      mkdir -p /var/lib/tftpboot/grub
      mkdir -p /var/lib/tftpboot/pxelinux.cfg
      mkdir -p /var/www/html/chroot-booter
      mkdir -p /var/www/html/images
      mkdir -p /opt/chroot-booter
      
      # Clone chroot-booter repository
      cd /opt/chroot-booter
      git clone https://github.com/biondogs/chroot-booter.git .
      
      # Build initramfs
      chmod +x tools/build-initramfs.sh
      ./tools/build-initramfs.sh
      
      # Copy files to web root
      cp output/chroot-booter-initramfs.cpio.gz /var/www/html/chroot-booter/initramfs.img
      
      # Download a kernel (using generic Ubuntu kernel for testing)
      wget -O /var/www/html/chroot-booter/vmlinuz \
        http://archive.ubuntu.com/ubuntu/dists/jammy/main/installer-amd64/current/images/netboot/ubuntu-installer/amd64/linux
      
      # Configure dnsmasq
      cat > /etc/dnsmasq.d/chroot-booter.conf << 'EOF'
interface=eth1
dhcp-range=192.168.100.50,192.168.100.250,255.255.255.0,1h
dhcp-option=option:router,192.168.100.1
dhcp-option=option:dns-server,8.8.8.8
dhcp-boot=tag:efi-x86_64,grubx64.efi
dhcp-boot=tag:bios,pxelinux.0
enable-tftp
tftp-root=/var/lib/tftpboot
log-dhcp
EOF
      
      # Configure PXELINUX
      cp /usr/lib/syslinux/pxelinux.0 /var/lib/tftpboot/
      cp /usr/lib/syslinux/ldlinux.c32 /var/lib/tftpboot/
      cp /usr/lib/syslinux/libcom32.c32 /var/lib/tftpboot/
      cp /usr/lib/syslinux/libutil.c32 /var/lib/tftpboot/
      cp /usr/lib/syslinux/menu.c32 /var/lib/tftpboot/
      cp /usr/lib/syslinux/vesamenu.c32 /var/lib/tftpboot/
      
      # Create PXELINUX config
      cat > /var/lib/tftpboot/pxelinux.cfg/default << 'EOF'
DEFAULT chroot-booter
PROMPT 1
TIMEOUT 100

LABEL chroot-booter
  MENU LABEL ^Chroot Booter (Interactive)
  KERNEL http://192.168.100.10/chroot-booter/vmlinuz
  APPEND initrd=http://192.168.100.10/chroot-booter/initramfs.img console=tty0 console=ttyS0,115200n8

LABEL chroot-booter-debug
  MENU LABEL Chroot Booter (Debug)
  KERNEL http://192.168.100.10/chroot-booter/vmlinuz
  APPEND initrd=http://192.168.100.10/chroot-booter/initramfs.img console=tty0 console=ttyS0,115200n8 bootstrap_debug
EOF
      
      # Configure GRUB for UEFI
      cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed /var/lib/tftpboot/grubx64.efi
      
      cat > /var/lib/tftpboot/grub/grub.cfg << 'EOF'
set timeout=10
set default=0

menuentry "Chroot Booter (Interactive)" {
    linux (http)/chroot-booter/vmlinuz initrd=http://192.168.100.10/chroot-booter/initramfs.img console=tty0 console=ttyS0,115200n8
    initrd (http)/chroot-booter/initramfs.img
}

menuentry "Chroot Booter (Debug)" {
    linux (http)/chroot-booter/vmlinuz initrd=http://192.168.100.10/chroot-booter/initramfs.img console=tty0 console=ttyS0,115200n8 bootstrap_debug
    initrd (http)/chroot-booter/initramfs.img
}
EOF
      
      # Fix permissions
      chown -R www-data:www-data /var/www/html
      chmod -R 755 /var/www/html
      
      # Restart services
      systemctl restart dnsmasq
      systemctl restart tftpd-hpa
      systemctl restart apache2
      
      echo "PXE Server setup complete!"
      echo "Access: http://192.168.100.10/"
    SHELL
  end
  
  # Test Client VM (PXE boot capable)
  config.vm.define "test-client" do |client|
    client.vm.box = "generic/ubuntu2204"
    client.vm.hostname = "test-client"
    client.vm.network "private_network", type: "dhcp",
                      virtualbox__intnet: "pxe-network"
    
    client.vm.provider "virtualbox" do |vb|
      vb.name = "chroot-booter-test-client"
      vb.memory = "2048"
      vb.cpus = 1
      
      # Enable network boot
      vb.customize ["modifyvm", :id, "--boot1", "net"]
      vb.customize ["modifyvm", :id, "--boot2", "disk"]
      vb.customize ["modifyvm", :id, "--nicbootprio2", "1"]
      
      # Enable EFI (for UEFI boot testing)
      # vb.customize ["modifyvm", :id, "--firmware", "efi"]
    end
    
    # No provisioning - this VM PXE boots
    client.vm.boot_timeout = 300
  end
  
end
```

### Step 3: Start the Environment

```bash
# Start the PXE server
vagrant up pxe-server

# Wait for provisioning to complete (this builds the initramfs)
# This may take 10-15 minutes

# Verify server is accessible
vagrant ssh pxe-server -c "ip addr show"
```

### Step 4: Create Test OS Images

SSH into the server and create sample images:

```bash
vagrant ssh pxe-server

# Create a minimal Rocky Linux image
sudo mkdir -p /tmp/rocky-root
sudo dnf --installroot=/tmp/rocky-root \
    --releasever=8 \
    --repo=baseos \
    --repo=appstream \
    install -y \
    @minimal \
    systemd \
    NetworkManager \
    vim

# Create tarball
sudo tar -czf /var/www/html/images/rocky-linux-8.tar.gz -C /tmp/rocky-root .

# Create a Debian image
sudo debootstrap bookworm /tmp/debian-root http://deb.debian.org/debian
sudo tar -czf /var/www/html/images/debian-12.tar.gz -C /tmp/debian-root .

# Create a squashfs image (alternative)
sudo mksquashfs /tmp/rocky-root /var/www/html/images/rocky-linux-8.squashfs -comp xz

# List images
ls -lh /var/www/html/images/
exit
```

### Step 5: Test PXE Boot

```bash
# Start the test client
vagrant up test-client

# Watch the console
vagrant console test-client

# Or use VirtualBox GUI to see the boot process
# The VM should:
# 1. PXE boot
# 2. Download the bootstrap
# 3. Show the [bootstrap] # prompt
```

### Step 6: Test Image Loading

Once the test client shows the bootstrap prompt:

```
[bootstrap] # load http://192.168.100.10/images/rocky-linux-8.tar.gz

# System will download and pivot into Rocky Linux
# ...
# Test the system

# Return to bootstrap (Ctrl+Alt+F12 or type on serial console)
[bootstrap] # load http://192.168.100.10/images/debian-12.tar.gz

# Test Debian
```

## Method 2: Manual VirtualBox Setup

### Step 1: Create Virtual Network

1. Open VirtualBox Preferences → Network → Host-Only Networks
2. Create new network: `vboxnet1`
3. Configure:
   - IPv4 Address: `192.168.100.1`
   - IPv4 Network Mask: `255.255.255.0`
   - DHCP Server: Disabled (we'll use our own)

### Step 2: Create PXE Server VM

1. **Create VM**:
   - Name: `pxe-server`
   - Type: Linux, Ubuntu 64-bit
   - RAM: 4096 MB
   - Disk: 20 GB

2. **Network Settings**:
   - Adapter 1: NAT (for internet access)
   - Adapter 2: Host-Only, `vboxnet1`

3. **Install Ubuntu Server 22.04**:
   - During install, set static IP on Adapter 2: `192.168.100.10/24`

4. **Install Required Software**:
   ```bash
   sudo apt-get update
   sudo apt-get install -y dnsmasq tftpd-hpa apache2 syslinux git
   ```

5. **Configure Services**:
   Follow the same configuration steps as in the Vagrant provision script above.

### Step 3: Create Test Client VM

1. **Create VM**:
   - Name: `test-client`
   - Type: Linux, Other Linux 64-bit
   - RAM: 2048 MB
   - Disk: 8 GB (or no disk for true network boot)

2. **Network Settings**:
   - Adapter 1: Host-Only, `vboxnet1`
   - Advanced: Adapter Type: PCnet-FAST III (for better PXE compatibility)

3. **Boot Order**:
   - System → Boot Order: Enable Network, move to top
   - Or: Disable all except Network for forced PXE boot

4. **For UEFI Testing**:
   - System → Motherboard: Enable EFI
   - Network boot will use GRUB instead of PXELINUX

### Step 4: Test

1. Start PXE Server VM
2. Start Test Client VM
3. Watch it PXE boot into Chroot Booter

## Method 3: Using KVM/QEMU (Linux)

### Step 1: Create Network

```bash
# Create virtual network
sudo virsh net-define /dev/stdin <<EOF
<network>
  <name>chroot-booter</name>
  <bridge name='virbr1' stp='on' delay='0'/>
  <ip address='192.168.100.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.100.50' end='192.168.100.250'/>
    </dhcp>
  </ip>
</network>
EOF

sudo virsh net-start chroot-booter
sudo virsh net-autostart chroot-booter
```

### Step 2: Create PXE Server VM

```bash
# Download Ubuntu cloud image
wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img

# Create disk
qemu-img create -f qcow2 -b jammy-server-cloudimg-amd64.img pxe-server.qcow2 20G

# Create VM
virt-install \
  --name pxe-server \
  --ram 4096 \
  --vcpus 2 \
  --disk path=pxe-server.qcow2,format=qcow2 \
  --network network=chroot-booter,model=virtio \
  --network bridge=virbr0,model=virtio \
  --os-variant ubuntu22.04 \
  --import \
  --noautoconsole

# Get IP
virsh domifaddr pxe-server

# SSH into it and configure as above
```

### Step 3: Create Test Client VM

```bash
# Create empty VM (no disk, PXE boot only)
virt-install \
  --name test-client \
  --ram 2048 \
  --vcpus 1 \
  --network network=chroot-booter,model=virtio \
  --boot network,hd \
  --os-variant generic \
  --graphics vnc,listen=0.0.0.0 \
  --noautoconsole

# Connect via VNC to see boot process
```

## Testing Scenarios

### Scenario 1: Quick OS Comparison

```bash
# On test client
[bootstrap] # load http://192.168.100.10/images/rocky-linux-8.tar.gz
# ... test Rocky 8

# Return
Ctrl+Alt+F12

[bootstrap] # load http://192.168.100.10/images/rocky-linux-9.tar.gz
# ... test Rocky 9

# Return
Ctrl+Alt+F12

[bootstrap] # load http://192.168.100.10/images/debian-12.tar.gz
# ... test Debian

# Done
[bootstrap] # poweroff
```

### Scenario 2: Automated Testing

Create a test script:

```bash
#!/bin/bash
# test-automation.sh - Run on test client

IMAGES=(
    "http://192.168.100.10/images/rocky-linux-8.tar.gz"
    "http://192.168.100.10/images/rocky-linux-9.tar.gz"
    "http://192.168.100.10/images/debian-12.tar.gz"
)

for image in "${IMAGES[@]}"; do
    echo "Testing: $image"
    
    # Load image
    echo "load $image" > /dev/console
    
    # Wait for boot
    sleep 30
    
    # Run tests (from target)
    echo "Running validation..."
    /root/run-validation.sh || echo "Validation failed for $image"
    
    # Return to bootstrap
    echo "return" > /var/run/return-signal
    
    # Wait for return
    sleep 10
done

echo "All tests complete"
```

### Scenario 3: Serial Console Testing

Useful for headless testing:

```bash
# On host, connect to VM serial
socat -,raw,echo=0 tcp:192.168.100.51:23

# Or use virsh console
virsh console test-client

# Send commands
RETURN_TO_BOOTSTRAP
```

## Troubleshooting

### Client doesn't PXE boot

```bash
# Check server is listening
sudo netstat -tlnp | grep -E '(67|68|69|80)'

# Check dhcp is working
sudo tcpdump -i eth1 port 67 or port 68

# Check tftp requests
sudo tail -f /var/log/syslog | grep tftp
```

### Bootstrap loads but can't download images

```bash
# Test from client
wget --spider http://192.168.100.10/images/rocky-linux-8.tar.gz

# Check server
ls -la /var/www/html/images/
sudo tail -f /var/log/apache2/access.log
```

### Return doesn't work

```bash
# Check hotkey daemon is running
ps | grep hotkey

# Check phase
cat /var/run/bootstrap/current_phase

# Manual return
echo return > /var/run/return-signal
```

## Advanced Configurations

### Multiple Test Clients

Create multiple test client VMs, each boots the same image:

```bash
# Create 3 test clients
for i in 1 2 3; do
    virt-clone --original test-client --name test-client-$i --file test-client-$i.qcow2
done
```

### Using Different Architectures

Test ARM64 images using QEMU:

```bash
# Install QEMU for ARM
sudo apt-get install qemu-system-arm

# Run ARM VM with network boot
qemu-system-aarch64 \
    -M virt \
    -cpu cortex-a53 \
    -m 2048 \
    -netdev user,id=net0,tftp=/var/lib/tftpboot,bootfile=grubaa64.efi \
    -device virtio-net-device,netdev=net0 \
    -nographic
```

### Performance Testing

Measure boot times:

```bash
#!/bin/bash
# benchmark-boot.sh

echo "$(date +%s)" > /tmp/boot-start

# Load image
load http://192.168.100.10/images/rocky-linux-8.tar.gz

# In target, record time
# Add to target's /etc/rc.local:
echo "$(date +%s)" > /tmp/target-boot-complete

# Calculate
download_time=$((target_boot_complete - boot_start))
echo "Total boot time: ${download_time}s"
```

## Cleanup

### Vagrant

```bash
# Destroy all VMs
vagrant destroy -f

# Remove virtual network
VBoxManage dhcpserver remove --netname pxe-network
```

### KVM/QEMU

```bash
# Stop and undefine VMs
virsh destroy pxe-server
virsh undefine pxe-server
virsh destroy test-client
virsh undefine test-client

# Remove network
virsh net-destroy chroot-booter
virsh net-undefine chroot-booter

# Clean up files
rm -f *.qcow2 *.img
```

## Next Steps

1. **Customize images**: Add your test scripts and validation tools
2. **Automate testing**: Integrate with CI/CD pipelines
3. **Scale up**: Run multiple parallel test clients
4. **Hardware testing**: Apply lessons learned to real bare metal

## Resources

- [Vagrant Documentation](https://www.vagrantup.com/docs)
- [VirtualBox Networking](https://www.virtualbox.org/manual/ch06.html)
- [KVM/QEMU Documentation](https://www.qemu.org/documentation/)
- [PXE Boot Guide](https://wiki.syslinux.org/wiki/index.php?title=PXELINUX)
