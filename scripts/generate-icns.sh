#!/bin/bash
# The app icon is the egg pixel art; this name is kept for existing habits and docs.
exec "$(dirname "$0")/generate-gs-icns.sh" "$@"
