#!/bin/bash
# Builds in debug and relaunches the app.
set -e
cd "$(dirname "$0")"

pkill -f "WhiteboardRecorder" 2>/dev/null || true

xcodebuild -project WhiteboardRecorder.xcodeproj \
           -scheme WhiteboardRecorder \
           -configuration Debug \
           -derivedDataPath build \
           build

open build/Build/Products/Debug/WhiteboardRecorder.app
echo "Launched. Look for the circle in the menu bar."
