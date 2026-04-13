#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: ./record_bag.sh <name>"
    exit 1
fi

BAG_DIR="$HOME/bags/iac/$(date +%Y-%m-%d)/$1"
mkdir -p "$(dirname "$BAG_DIR")"

ros2 bag record -s mcap -b 10000000000 -a --output "$BAG_DIR" &
PID=$!

echo "Recording -> $BAG_DIR"

cleanup() {
    kill -SIGINT $PID 2>/dev/null || true
    wait $PID 2>/dev/null || true
    echo ""
    echo "Saved to $BAG_DIR"
}

trap cleanup SIGINT SIGTERM
wait
