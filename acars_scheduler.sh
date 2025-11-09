#!/bin/bash
# Time-sliced ACARS scheduler for VDL2 + Legacy ACARS with proper device management

DEVICE_ID="${1:-0}"
VDL2_DURATION=30
ACARS_DURATION=30
TRANSITION_DELAY=5  # Increased for USB device release

VDL2_NDJSON="/tmp/vdl2.ndjson"
ACARS_NDJSON="/tmp/acars.ndjson"

VDL2_PID=""
ACARS_PID=""

cleanup() {
    echo "Shutting down ACARS scheduler..."
    stop_current
    pkill -9 -f "dumpvdl2.*--rtlsdr $DEVICE_ID" 2>/dev/null
    pkill -9 -f "acarsdec.*--rtlsdr $DEVICE_ID" 2>/dev/null
    
    # Force USB device reset
    if command -v usbreset &> /dev/null; then
        echo "Resetting USB device..."
        rtl_test -d $DEVICE_ID -t 1 2>/dev/null || true
    fi
    
    exit 0
}

trap cleanup SIGINT SIGTERM

start_vdl2() {
    echo "[$(date '+%H:%M:%S')] Starting VDL2 capture for ${VDL2_DURATION}s..."
    
    # Verify device is available
    if ! rtl_test -d $DEVICE_ID -t 1 &>/dev/null; then
        echo "ERROR: Device $DEVICE_ID not available"
        return 1
    fi
    
    dumpvdl2 \
        --rtlsdr $DEVICE_ID \
        --gain 49.6 \
        136650000 136725000 136775000 136800000 136825000 136875000 136900000 136975000 \
        --output "decoded:json:file:path=$VDL2_NDJSON" \
        >/dev/null 2>&1 &
    
    VDL2_PID=$!
    
    # Wait for process to initialize
    sleep 2
    
    if ! kill -0 $VDL2_PID 2>/dev/null; then
        echo "ERROR: VDL2 failed to start"
        VDL2_PID=""
        return 1
    fi
    
    echo "VDL2 started (PID: $VDL2_PID)"
    return 0
}

start_acars() {
    echo "[$(date '+%H:%M:%S')] Starting Legacy ACARS capture for ${ACARS_DURATION}s..."
    
    # Verify device is available
    if ! rtl_test -d $DEVICE_ID -t 1 &>/dev/null; then
        echo "ERROR: Device $DEVICE_ID not available"
        return 1
    fi
    
    acarsdec \
        -A -e \
        -g 36.4 \
        --output "json:file:path=$ACARS_NDJSON" \
        --rtlsdr $DEVICE_ID \
        131.525 131.725 131.825 130.450 130.825 131.550 \
        >/dev/null 2>&1 &
    
    ACARS_PID=$!
    
    # Wait for process to initialize
    sleep 2
    
    if ! kill -0 $ACARS_PID 2>/dev/null; then
        echo "ERROR: ACARS failed to start"
        ACARS_PID=""
        return 1
    fi
    
    echo "ACARS started (PID: $ACARS_PID)"
    return 0
}

stop_current() {
    local stopped_any=false
    
    if [[ -n "$VDL2_PID" ]]; then
        echo "[$(date '+%H:%M:%S')] Stopping VDL2 (PID: $VDL2_PID)..."
        kill -TERM $VDL2_PID 2>/dev/null
        
        # Wait up to 3 seconds for graceful shutdown
        for i in {1..3}; do
            if ! kill -0 $VDL2_PID 2>/dev/null; then
                break
            fi
            sleep 1
        done
        
        # Force kill if still running
        if kill -0 $VDL2_PID 2>/dev/null; then
            kill -9 $VDL2_PID 2>/dev/null
        fi
        
        wait $VDL2_PID 2>/dev/null
        VDL2_PID=""
        stopped_any=true
    fi
    
    if [[ -n "$ACARS_PID" ]]; then
        echo "[$(date '+%H:%M:%S')] Stopping ACARS (PID: $ACARS_PID)..."
        kill -TERM $ACARS_PID 2>/dev/null
        
        # Wait up to 3 seconds for graceful shutdown
        for i in {1..3}; do
            if ! kill -0 $ACARS_PID 2>/dev/null; then
                break
            fi
            sleep 1
        done
        
        # Force kill if still running
        if kill -0 $ACARS_PID 2>/dev/null; then
            kill -9 $ACARS_PID 2>/dev/null
        fi
        
        wait $ACARS_PID 2>/dev/null
        ACARS_PID=""
        stopped_any=true
    fi
    
    # Ensure no orphaned processes
    pkill -9 -f "dumpvdl2.*--rtlsdr $DEVICE_ID" 2>/dev/null
    pkill -9 -f "acarsdec.*--rtlsdr $DEVICE_ID" 2>/dev/null
    
    if [[ "$stopped_any" == "true" ]]; then
        echo "[$(date '+%H:%M:%S')] Waiting ${TRANSITION_DELAY}s for USB device release..."
        sleep $TRANSITION_DELAY
        
        # Test device availability
        rtl_test -d $DEVICE_ID -t 1 &>/dev/null || {
            echo "WARNING: Device may still be in use, waiting additional 3s..."
            sleep 3
        }
    fi
}

# Verify device exists before starting
if ! rtl_test -d $DEVICE_ID -t 1 &>/dev/null; then
    echo "ERROR: RTL-SDR device $DEVICE_ID not found or not accessible"
    echo "Available devices:"
    rtl_test -t 2>&1 | grep -E "^\s*[0-9]+:"
    exit 1
fi

echo "=========================================="
echo "ACARS Time-Slicing Scheduler Started"
echo "=========================================="
echo "Device:        $DEVICE_ID"
echo "VDL2 Duration: ${VDL2_DURATION}s"
echo "ACARS Duration: ${ACARS_DURATION}s"
echo "Transition:    ${TRANSITION_DELAY}s"
echo "Output Files:"
echo "  - $VDL2_NDJSON"
echo "  - $ACARS_NDJSON"
echo "=========================================="

# Main loop with error recovery
ERROR_COUNT=0
MAX_ERRORS=5

while true; do
    # VDL2 Phase
    if start_vdl2; then
        ERROR_COUNT=0
        sleep $VDL2_DURATION
        stop_current
    else
        ERROR_COUNT=$((ERROR_COUNT + 1))
        echo "ERROR: VDL2 start failed (attempt $ERROR_COUNT/$MAX_ERRORS)"
        stop_current
        
        if [[ $ERROR_COUNT -ge $MAX_ERRORS ]]; then
            echo "FATAL: Too many consecutive errors, exiting"
            cleanup
        fi
        
        sleep 5
        continue
    fi
    
    # ACARS Phase
    if start_acars; then
        ERROR_COUNT=0
        sleep $ACARS_DURATION
        stop_current
    else
        ERROR_COUNT=$((ERROR_COUNT + 1))
        echo "ERROR: ACARS start failed (attempt $ERROR_COUNT/$MAX_ERRORS)"
        stop_current
        
        if [[ $ERROR_COUNT -ge $MAX_ERRORS ]]; then
            echo "FATAL: Too many consecutive errors, exiting"
            cleanup
        fi
        
        sleep 5
        continue
    fi
    
    echo "[$(date '+%H:%M:%S')] Cycle complete, starting next..."
done