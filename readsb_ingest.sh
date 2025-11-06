#!/bin/bash
# Find where readsb is located
READSB_PATH=$(which readsb)

# If not found in PATH, try common locations
if [ -z "$READSB_PATH" ]; then
    # Try these common paths, add more if needed
    for path in /usr/local/bin/readsb /usr/bin/readsb; do
        if [ -f "$path" ]; then
            READSB_PATH="$path"
            break
        fi
    done
fi

# If still not found, try to use dump1090 instead
if [ -z "$READSB_PATH" ]; then
    READSB_PATH=$(which dump1090)
    if [ -n "$READSB_PATH" ]; then
        echo "readsb not found, using dump1090 instead"
    fi
fi

# Create output directory
mkdir -p /tmp

# Run readsb if found
if [ -n "$READSB_PATH" ]; then
    echo "Starting $READSB_PATH"
    $READSB_PATH --device-type rtlsdr --device 0 --write-json /tmp --write-json-every 1
else
    echo "ERROR: readsb or dump1090 not found in PATH or common locations"
    echo "Please install readsb or dump1090, or edit this script with the correct path"
    exit 1
fi
