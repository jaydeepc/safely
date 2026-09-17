#!/bin/bash
# Serves the harmless test login page at http://localhost:8765 (the simulated phone has a login for it).
cd "$(dirname "$0")/../extension-test-page" && exec python3 -m http.server 8765 --bind 127.0.0.1
