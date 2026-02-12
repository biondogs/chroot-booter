#!/bin/sh
# Hotkey Daemon - Monitors keyboard for magic key combo to trigger return
# Listens on input devices for Ctrl+Alt+F12 (or similar)
# Also monitors serial console for magic string

set -e

RETURN_FIFO=/var/run/return-signal
BOOTSTRAP_STATE=/var/run/bootstrap
MAGIC_KEY_COMBO="ctrl-alt-f12"
MAGIC_SERIAL_STRING="RETURN_TO_BOOTSTRAP"
PID_FILE=/var/run/hotkey-daemon.pid

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[HOTKEY]${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[HOTKEY]${NC} $1" >&2
}

error() {
    echo -e "${RED}[HOTKEY]${NC} $1" >&2
}

# Save PID
save_pid() {
    echo $$ > "$PID_FILE"
}

# Signal return to bootstrap
signal_return() {
    log "Magic key detected! Signaling return to bootstrap..."
    
    if [ -p "$RETURN_FIFO" ]; then
        echo "return" > "$RETURN_FIFO"
    else
        warn "Return FIFO not available"
    fi
}

# Monitor input events using showkey (fallback method)
monitor_showkey() {
    log "Using showkey for keyboard monitoring..."
    
    # We need to monitor multiple virtual consoles
    for tty in /dev/tty[0-9]*; do
        [ -e "$tty" ] || continue
        
        # Start showkey in background for each tty
        (
            showkey -s < "$tty" 2>/dev/null | while read -r line; do
                # Look for F12 key scan code (0x58 or similar depending on keyboard)
                # This is a simplified check
                if echo "$line" | grep -q "0x58"; then
                    # Check if ctrl and alt are held (this is simplified)
                    signal_return
                fi
            done
        ) &
    done
}

# Monitor using /dev/input/event* (preferred method)
monitor_input_events() {
    log "Using input event monitoring..."
    
    # Find all keyboard input devices
    for event_dev in /dev/input/event*; do
        [ -e "$event_dev" ] || continue
        
        # Check if it's a keyboard
        if evtest --info "$event_dev" 2>/dev/null | grep -q "keyboard"; then
            log "Monitoring keyboard: $event_dev"
            
            # Monitor in background
            (
                # Track modifier key states
                CTRL_PRESSED=0
                ALT_PRESSED=0
                
                evtest "$event_dev" 2>/dev/null | while read -r line; do
                    # Parse evtest output for key events
                    # Format: Event: time X, type Y (EV_KEY), code Z (KEY_*), value W
                    
                    if echo "$line" | grep -q "EV_KEY"; then
                        # Extract key code and value
                        local code
                        local value
                        code=$(echo "$line" | grep -o 'code [0-9]*' | awk '{print $2}')
                        value=$(echo "$line" | grep -o 'value [0-9]*' | awk '{print $2}')
                        
                        # Key codes (approximate, may vary)
                        # KEY_LEFTCTRL = 29, KEY_RIGHTCTRL = 97
                        # KEY_LEFTALT = 56, KEY_RIGHTALT = 100
                        # KEY_F12 = 88
                        
                        case "$code" in
                            29|97)  # Left/Right Ctrl
                                CTRL_PRESSED="$value"
                                ;;
                            56|100) # Left/Right Alt
                                ALT_PRESSED="$value"
                                ;;
                            88)     # F12
                                if [ "$value" = "1" ] && [ "$CTRL_PRESSED" = "1" ] && [ "$ALT_PRESSED" = "1" ]; then
                                    signal_return
                                fi
                                ;;
                        esac
                    fi
                done
            ) &
        fi
    done
}

# Alternative: Monitor using simpler method with stty
monitor_simple() {
    log "Using simple keyboard monitoring..."
    
    # Create a trap for SIGUSR1 which we'll use for signaling
    trap signal_return SIGUSR1
    
    # For simplicity, we'll also monitor /dev/console
    (
        # Read from console looking for special sequences
        # F12 generates ESC [ 24 ~ or similar
        cat /dev/console | while IFS= read -r -n1 char; do
            # Accumulate characters
            printf "%s" "$char" >> /tmp/keybuffer
            
            # Check for magic sequence (Ctrl+Alt+F12 generates specific sequences)
            # This is terminal-dependent, but F12 typically sends \e[24~
            if grep -q $'\x1b\[24~' /tmp/keybuffer 2>/dev/null; then
                # Check if we're in bootstrap mode (not yet pivoted)
                if [ "$(cat $BOOTSTRAP_STATE/current_phase 2>/dev/null)" = "bootstrap" ]; then
                    log "F12 pressed in bootstrap mode - showing menu"
                    # Just a visual signal, no action needed in bootstrap mode
                else
                    signal_return
                fi
                > /tmp/keybuffer
            fi
            
            # Keep buffer from growing too large
            if [ $(stat -c%s /tmp/keybuffer 2>/dev/null || echo 0) -gt 100 ]; then
                > /tmp/keybuffer
            fi
        done
    ) &
}

# Monitor serial console for magic string
monitor_serial() {
    log "Monitoring serial console..."
    
    # Check common serial devices
    for serial in /dev/ttyS0 /dev/ttyS1 /dev/ttyUSB0 /dev/console; do
        [ -e "$serial" ] || continue
        [ -r "$serial" ] || continue
        
        log "Monitoring serial: $serial"
        
        (
            # Set raw mode for serial
            stty -F "$serial" raw -echo 2>/dev/null || true
            
            # Read line by line
            while IFS= read -r line < "$serial"; do
                if echo "$line" | grep -q "$MAGIC_SERIAL_STRING"; then
                    log "Magic string detected on serial!"
                    signal_return
                fi
            done
        ) &
        
        break  # Only monitor first available serial
    done
}

# Alternative: Use SysRq key monitoring
monitor_sysrq() {
    log "Setting up SysRq monitoring..."
    
    # Enable sysrq
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
    
    # We can use a custom SysRq handler by writing to sysrq-trigger
    # But this is handled by the kernel, so we'll document it instead
    log "SysRq enabled. Alt+SysRq+B will reboot, use return mechanism instead"
}

# Cleanup on exit
cleanup() {
    rm -f "$PID_FILE"
    kill 0 2>/dev/null || true
    exit 0
}

trap cleanup INT TERM EXIT

# Main daemon
main() {
    log "Hotkey Daemon starting..."
    save_pid
    
    # Clear any existing key buffer
    > /tmp/keybuffer 2>/dev/null || true
    
    # Try different monitoring methods
    # Order of preference: input events > showkey > simple > serial
    
    if command -v evtest >/dev/null 2>&1; then
        monitor_input_events
    fi
    
    if command -v showkey >/dev/null 2>&1; then
        monitor_showkey
    fi
    
    # Always try simple monitoring
    monitor_simple
    
    # Monitor serial
    monitor_serial
    
    # Setup SysRq
    monitor_sysrq
    
    log "Hotkey monitoring active"
    log "Press Ctrl+Alt+F12 to return to bootstrap (when in target)"
    log "Or send '$MAGIC_SERIAL_STRING' over serial console"
    
    # Keep daemon running
    while true; do
        sleep 1
    done
}

main "$@"
