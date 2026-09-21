#!/bin/bash
# Builds in release, puts the app at the root and zips it for the repository.
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

echo "WhiteboardRecorder.app and WhiteboardRecorder.zip are ready."
echo "To install: drag WhiteboardRecorder.app into /Applications."
