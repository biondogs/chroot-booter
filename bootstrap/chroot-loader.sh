#!/bin/sh
# Chroot Loader - Downloads, mounts, and pivots into target images
# Handles both .tar.gz images and .squashfs images

set -e

SCRIPT_DIR="$(dirname "$0")"
BOOTSTRAP_STATE=/var/run/bootstrap
RETURN_FIFO=/var/run/return-signal
NEWROOT=/newroot
MOUNT_BASE=/mnt/images

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[LOADER]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[LOADER]${NC} $1"
}

error() {
    echo -e "${RED}[LOADER]${NC} $1"
}

# Check if we can access the URL
check_url() {
    local url="$1"
    log "Checking URL: $url"
    
    if ! wget -q --spider "$url" 2>/dev/null; then
        error "Cannot access URL: $url"
        return 1
    fi
    
    # Get file size
    local size
    size=$(wget -q --spider --server-response "$url" 2>&1 | grep -i 'Content-Length:' | tail -1 | awk '{print $2}')
    if [ -n "$size" ]; then
        log "Image size: $size bytes ($(echo "scale=2; $size/1048576" | bc 2>/dev/null || echo "unknown") MB)"
    fi
    
    return 0
}

# Download image to local storage
download_image() {
    local url="$1"
    local output="$2"
    
    log "Downloading image..."
    log "Source: $url"
    log "Destination: $output"
    
    # Create directory if needed
    mkdir -p "$(dirname "$output")"
    
    # Download with progress
    if ! wget -O "$output" "$url" 2>&1 | tail -20; then
        error "Download failed"
        rm -f "$output"
        return 1
    fi
    
    local size
    size=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output" 2>/dev/null || echo "0")
    log "Download complete: $size bytes"
    
    return 0
}

# Mount squashfs image
mount_squashfs() {
    local image="$1"
    local mountpoint="$2"
    
    log "Mounting squashfs image..."
    
    mkdir -p "$mountpoint"
    
    if ! mount -t squashfs -o ro "$image" "$mountpoint"; then
        error "Failed to mount squashfs"
        return 1
    fi
    
    log "Squashfs mounted at $mountpoint"
    return 0
}

# Extract tar.gz image to directory
extract_tarball() {
    local image="$1"
    local dest="$2"
    
    log "Extracting tarball..."
    
    mkdir -p "$dest"
    
    # Extract with progress
    if ! tar -xzf "$image" -C "$dest" --checkpoint=1000 --checkpoint-action=echo='Extracted %u files' 2>/dev/null; then
        # Fallback without progress
        if ! tar -xzf "$image" -C "$dest"; then
            error "Extraction failed"
            return 1
        fi
    fi
    
    log "Extraction complete"
    return 0
}

# Prepare newroot directory
prepare_newroot() {
    log "Preparing newroot at $NEWROOT..."
    
    # Clean up any existing newroot
    if [ -d "$NEWROOT" ]; then
        warn "Cleaning up existing newroot..."
        umount -R "$NEWROOT" 2>/dev/null || true
        rm -rf "$NEWROOT"
    fi
    
    mkdir -p "$NEWROOT"
    
    # Create mount base for images
    mkdir -p "$MOUNT_BASE"
}

# Mount essential filesystems in newroot
mount_target_essential() {
    log "Mounting essential filesystems in target..."
    
    mount -t proc none "$NEWROOT/proc" 2>/dev/null || true
    mount -t sysfs none "$NEWROOT/sys" 2>/dev/null || true
    mount --rbind /dev "$NEWROOT/dev" 2>/dev/null || true
    mount --make-rslave "$NEWROOT/dev" 2>/dev/null || true
    
    # Mount /run as tmpfs in target
    mount -t tmpfs none "$NEWROOT/run" 2>/dev/null || true
}

# Create return mechanism files in target
setup_return_mechanism() {
    log "Setting up return mechanism in target..."
    
    # Create the return helper script in target
    cat > "$NEWROOT/.bootstrap-return" << 'RETURNEOF'
#!/bin/sh
# Return to bootstrap - Called from within target system

if [ -f /proc/1/root/.bootstrap-id ]; then
    echo "Returning to bootstrap..."
    # Signal the bootstrap init
    echo "return" > /proc/1/root/var/run/return-signal 2>/dev/null
    # Or use SysRq
    echo b > /proc/sysrq-trigger 2>/dev/null || true
else
    echo "Not running in chroot-booter environment"
    exit 1
fi
RETURNEOF
    chmod +x "$NEWROOT/.bootstrap-return"
    
    # Also create a systemd service file if systemd is present
    if [ -d "$NEWROOT/etc/systemd/system" ]; then
        cat > "$NEWROOT/etc/systemd/system/bootstrap-return.service" << 'EOF'
[Unit]
Description=Chroot Booter Return Service
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    fi
    
    # Mark the bootstrap environment
    echo "chroot-booter-$(date +%s)" > "$NEWROOT/.bootstrap-id"
    echo "chroot-booter-$(date +%s)" > "/.bootstrap-id"
}

# Perform pivot_root into target
pivot_to_target() {
    log "Pivoting to target system..."
    
    # Create oldroot directory in target
    mkdir -p "$NEWROOT/oldroot"
    
    # Store our PID for return detection
    echo $$ > "$BOOTSTRAP_STATE/pid_in_target"
    echo "target" > "$BOOTSTRAP_STATE/current_phase"
    
    # Perform the pivot
    # This moves current root to NEWROOT/oldroot and NEWROOT becomes /
    if ! pivot_root "$NEWROOT" "$NEWROOT/oldroot"; then
        error "pivot_root failed"
        return 1
    fi
    
    # Move essential mounts
    mount --move /oldroot/proc /proc 2>/dev/null || mount -t proc none /proc
    mount --move /oldroot/sys /sys 2>/dev/null || mount -t sysfs none /sys
    mount --move /oldroot/dev /dev 2>/dev/null || mount --rbind /oldroot/dev /dev
    
    # Keep access to bootstrap state through /oldroot
    log "Bootstrap preserved at /oldroot"
    
    return 0
}

# Start return handler daemon
start_return_handler() {
    log "Starting return handler..."
    
    # The return handler runs in the bootstrap (oldroot) context
    # and monitors for return signals
    if [ -x /oldroot/bin/return-handler.sh ]; then
        /oldroot/bin/return-handler.sh &
        echo $! > /oldroot/var/run/return_handler.pid
        log "Return handler started (PID: $!)"
    fi
}

# Execute target init
exec_target_init() {
    log "Starting target init..."
    
    # Determine init program
    local init="/sbin/init"
    [ -x "/bin/init" ] && init="/bin/init"
    [ -x "/usr/sbin/init" ] && init="/usr/sbin/init"
    [ -x "/usr/bin/init" ] && init="/usr/bin/init"
    
    log "Target init: $init"
    
    # Start return handler before execing init
    start_return_handler
    
    # Execute target init
    # If this fails, we fall back to the bootstrap
    exec "$init"
}

# Cleanup on failure
cleanup() {
    warn "Cleaning up after failure..."
    umount -R "$NEWROOT" 2>/dev/null || true
    rm -rf "$NEWROOT"
    rm -f "$BOOTSTRAP_STATE/pid_in_target"
    echo "bootstrap" > "$BOOTSTRAP_STATE/current_phase"
}

# Main loader function
main() {
    local url="$1"
    local image_file="$MOUNT_BASE/downloaded-image"
    
    if [ -z "$url" ]; then
        error "Usage: $0 <image-url>"
        exit 1
    fi
    
    log "Chroot Loader starting..."
    log "URL: $url"
    
    # Check URL accessibility
    if ! check_url "$url"; then
        error "URL check failed"
        exit 1
    fi
    
    # Determine image type from URL
    local img_type="tar"
    if echo "$url" | grep -q "\.squashfs"; then
        img_type="squashfs"
    elif echo "$url" | grep -q "\.tar"; then
        img_type="tar"
    else
        warn "Unknown image type, assuming tarball"
    fi
    
    # Prepare directories
    prepare_newroot
    
    # Download image
    if ! download_image "$url" "$image_file"; then
        cleanup
        exit 1
    fi
    
    # Mount or extract based on type
    if [ "$img_type" = "squashfs" ]; then
        if ! mount_squashfs "$image_file" "$NEWROOT"; then
            cleanup
            exit 1
        fi
    else
        if ! extract_tarball "$image_file" "$NEWROOT"; then
            cleanup
            exit 1
        fi
    fi
    
    # Setup essential mounts in target
    mount_target_essential
    
    # Setup return mechanism
    setup_return_mechanism
    
    # Perform pivot
    if ! pivot_to_target; then
        error "Pivot failed, attempting cleanup..."
        cleanup
        exit 1
    fi
    
    # Execute target init
    # This replaces the current process
    exec_target_init
    
    # Should never reach here
    error "Failed to execute target init"
    exit 1
}

# Run main
main "$@"
