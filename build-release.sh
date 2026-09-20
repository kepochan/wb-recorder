#!/bin/bash
# Compile en release, dépose l'app à la racine et la zippe pour le dépôt.
set -e
cd "$(dirname "$0")"

xcodebuild -project WhiteboardRecorder.xcodeproj \
           -scheme WhiteboardRecorder \
           -configuration Release \
           -derivedDataPath build \
           build

rm -rf WhiteboardRecorder.app WhiteboardRecorder.zip
cp -R build/Build/Products/Release/WhiteboardRecorder.app .
ditto -c -k --keepParent WhiteboardRecorder.app WhiteboardRecorder.zip

echo "WhiteboardRecorder.app et WhiteboardRecorder.zip sont prêts."
echo "Installation : glisse WhiteboardRecorder.app dans /Applications."
