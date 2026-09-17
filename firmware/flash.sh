#!/bin/bash
# Compiles and flashes the Shhlock Key firmware to a Seeed Studio XIAO ESP32C3.
#   firmware/flash.sh [port]          default port: the first /dev/cu.usbmodem*
#   firmware/flash.sh --test [port]   test build that also speaks the protocol over USB serial (for shhlock-keytest)
# Needs: arduino-cli, esp32 core 3.x, NimBLE-Arduino 2.x, ArduinoJson 7.x (arduino-cli lib install NimBLE-Arduino ArduinoJson)
set -euo pipefail
cd "$(dirname "$0")"
FLAGS=""
if [[ "${1:-}" == "--test" ]]; then FLAGS="-DSHHLOCK_SERIAL_TEST"; shift; fi
PORT="${1:-$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)}"
[[ -n "$PORT" ]] || { echo "No board found. Plug in the XIAO (hold BOOT while plugging in if it does not show up)."; exit 1; }
BUILD="$(mktemp -d)"
arduino-cli compile -b esp32:esp32:XIAO_ESP32C3 --build-path "$BUILD" --build-property "compiler.cpp.extra_flags=$FLAGS" shhlock_key
arduino-cli upload -b esp32:esp32:XIAO_ESP32C3 -p "$PORT" --input-dir "$BUILD"
echo "Flashed. Serial log: arduino-cli monitor -p $PORT -c baudrate=115200"
