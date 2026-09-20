#!/bin/bash
# Compile en debug et relance l'app.
set -e
cd "$(dirname "$0")"

pkill -f "WhiteboardRecorder" 2>/dev/null || true

xcodebuild -project WhiteboardRecorder.xcodeproj \
           -scheme WhiteboardRecorder \
           -configuration Debug \
           -derivedDataPath build \
           build

open build/Build/Products/Debug/WhiteboardRecorder.app
echo "Lancé. Cherche le cercle dans la barre de menu."
