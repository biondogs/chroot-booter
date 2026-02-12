#!/bin/sh
# Return Handler - Monitors for return signals and performs reverse pivot
# This runs in the bootstrap (oldroot) context after pivoting to target

set -e

RETURN_FIFO=/var/run/return-signal
BOOTSTRAP_STATE=/var/run/bootstrap
OLDROOT=/oldroot

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[RETURN]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[RETURN]${NC} $1"
}

error() {
    echo -e "${RED}[RETURN]${NC} $1"
}

info() {
    echo -e "${BLUE}[RETURN]${NC} $1"
}

# Check if we can perform return
can_return() {
    if [ ! -f "$BOOTSTRAP_STATE/pid_in_target" ]; then
        warn "Not in target system, cannot return"
        return 1
    fi
    
    if [ ! -d "$OLDROOT" ]; then
        error "Oldroot not found at $OLDROOT"
        return 1
    fi
    
    return 0
}

# Unmount target filesystems gracefully
unmount_target() {
    log "Unmounting target filesystems..."
    
    # First try to gracefully shutdown any services
    if [ -x "$OLDROOT/sbin/init" ] || [ -x "$OLDROOT/usr/sbin/init" ]; then
        warn "Attempting to notify target of shutdown..."
        # Try systemd or other init systems
        if [ -S "$OLDROOT/run/systemd/private" ]; then
            chroot "$OLDROOT" systemctl poweroff 2>/dev/null || true
            sleep 2
        fi
    fi
    
    # Unmount in reverse order of mounting
    # First unmount virtual filesystems
    umount -R "$OLDROOT/run" 2>/dev/null || true
    umount -R "$OLDROOT/dev" 2>/dev/null || true
    umount -R "$OLDROOT/sys" 2>/dev/null || true
    umount -R "$OLDROOT/proc" 2>/dev/null || true
    
    # Unmount the root itself
    umount "$OLDROOT" 2>/dev/null || warn "Could not unmount oldroot cleanly"
    
    log "Target filesystems unmounted"
}

# Reverse pivot_root - go back to bootstrap
reverse_pivot() {
    log "Performing reverse pivot..."
    
    # Create temporary mount point
    mkdir -p /tmp/bootstrap-root
    
    # Mount bootstrap root temporarily
    mount --bind / /tmp/bootstrap-root || {
        error "Failed to bind mount bootstrap root"
        return 1
    }
    
    # Create oldroot directory in bootstrap
    mkdir -p /tmp/bootstrap-root/old-target
    
    # Perform reverse pivot
    # Move current root to /tmp/bootstrap-root/old-target
    # Make /tmp/bootstrap-root the new root
    if ! pivot_root /tmp/bootstrap-root /tmp/bootstrap-root/old-target; then
        error "Reverse pivot failed"
        umount /tmp/bootstrap-root 2>/dev/null || true
        return 1
    fi
    
    # Remount essential filesystems
    mount --move /old-target/proc /proc 2>/dev/null || mount -t proc none /proc
    mount --move /old-target/sys /sys 2>/dev/null || mount -t sysfs none /sys
    mount --move /old-target/dev /dev 2>/dev/null || mount --rbind /old-target/dev /dev
    
    # Clean up old target
    umount -R /old-target 2>/dev/null || true
    rm -rf /old-target
    
    log "Successfully returned to bootstrap"
    return 0
}

# Cleanup target state
cleanup_target_state() {
    log "Cleaning up target state..."
    
    # Remove pid file
    rm -f "$BOOTSTRAP_STATE/pid_in_target"
    
    # Reset state
    echo "bootstrap" > "$BOOTSTRAP_STATE/current_phase"
    
    # Clean up any temp files
    rm -rf /tmp/bootstrap-root 2>/dev/null || true
    rm -rf /mnt/images/* 2>/dev/null || true
}

# Restart bootstrap services
restart_bootstrap() {
    log "Restarting bootstrap environment..."
    
    # Restart hotkey daemon
    if [ -x /bin/hotkey-daemon.sh ]; then
        killall hotkey-daemon.sh 2>/dev/null || true
        sleep 1
        /bin/hotkey-daemon.sh &
    fi
    
    # Clean up and restart return FIFO
    rm -f "$RETURN_FIFO"
    mkfifo "$RETURN_FIFO" 2>/dev/null || true
    
    log "Bootstrap environment ready"
}

# Display return message
show_return_message() {
    echo ""
    echo "========================================"
    echo "  RETURNED TO BOOTSTRAP"
    echo "========================================"
    echo ""
    echo "Previous image has been unloaded."
    echo "You can now load a different image."
    echo ""
    echo "Available commands:"
    echo "  load <url>  - Load new image"
    echo "  status      - Show status"
    echo "  shell       - Drop to shell"
    echo "  reboot      - Reboot system"
    echo ""
}

# Execute return sequence
execute_return() {
    log "Executing return sequence..."
    
    if ! can_return; then
        error "Cannot perform return"
        return 1
    fi
    
    info "Step 1/4: Unmounting target filesystems..."
    unmount_target
    
    info "Step 2/4: Cleaning up target state..."
    cleanup_target_state
    
    info "Step 3/4: Restarting bootstrap services..."
    restart_bootstrap
    
    info "Step 4/4: Return complete"
    
    show_return_message
    
    return 0
}

# Monitor FIFO for return signals
monitor_fifo() {
    log "Monitoring for return signals..."
    
    # Ensure FIFO exists
    [ -p "$RETURN_FIFO" ] || mkfifo "$RETURN_FIFO" 2>/dev/null || {
        error "Cannot create return FIFO"
        exit 1
    }
    
    # Monitor loop
    while true; do
        if [ -r "$RETURN_FIFO" ]; then
            # Read from FIFO (blocks until data available)
            if read -r signal < "$RETURN_FIFO"; then
                case "$signal" in
                    return)
                        log "Received return signal"
                        if execute_return; then
                            log "Return successful"
                        else
                            error "Return failed"
                        fi
                        ;;
                    status)
                        show_status
                        ;;
                    *)
                        warn "Unknown signal: $signal"
                        ;;
                esac
            fi
        else
            # FIFO doesn't exist, recreate it
            sleep 1
            [ -p "$RETURN_FIFO" ] || mkfifo "$RETURN_FIFO" 2>/dev/null || true
        fi
    done
}

# Show current status
show_status() {
    echo ""
    echo "=== Bootstrap Status ==="
    echo "Current phase: $(cat $BOOTSTRAP_STATE/current_phase 2>/dev/null || echo 'unknown')"
    echo "Boot time: $(cat $BOOTSTRAP_STATE/boot_time 2>/dev/null || echo 'unknown')"
    if [ -f "$BOOTSTRAP_STATE/last_image_url" ]; then
        echo "Last image: $(cat $BOOTSTRAP_STATE/last_image_url)"
    fi
    if [ -f "$BOOTSTRAP_STATE/pid_in_target" ]; then
        echo "Target PID: $(cat $BOOTSTRAP_STATE/pid_in_target)"
    fi
    echo ""
}

# Cleanup on exit
cleanup() {
    log "Return handler shutting down..."
    exit 0
}

trap cleanup INT TERM

# Main handler
main() {
    log "Return Handler starting..."
    
    # Show initial status
    show_status
    
    # Start monitoring
    monitor_fifo
}

# Run main
main "$@"
