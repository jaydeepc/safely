#!/bin/bash
# Compiles and flashes the Safely Key firmware to a Seeed Studio XIAO ESP32C3.
#   firmware/flash.sh [port]        default port: the first /dev/cu.usbmodem*
# Needs: arduino-cli, esp32 core 3.x (arduino-cli core install esp32:esp32), NimBLE-Arduino 2.x (arduino-cli lib install NimBLE-Arduino)
set -euo pipefail
cd "$(dirname "$0")"
PORT="${1:-$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)}"
[[ -n "$PORT" ]] || { echo "No board found. Plug in the XIAO (hold BOOT while plugging in if it does not show up)."; exit 1; }
BUILD="$(mktemp -d)"
arduino-cli compile -b esp32:esp32:XIAO_ESP32C3 --build-path "$BUILD" safely_key
arduino-cli upload -b esp32:esp32:XIAO_ESP32C3 -p "$PORT" --input-dir "$BUILD"
echo "Flashed. Serial log: arduino-cli monitor -p $PORT -c baudrate=115200"
