#!/bin/bash
# Archive a universal Release build and export it with Developer ID signing.
# Output: build/export/StackStatus.app
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHIVE=build/StackStatus.xcarchive
rm -rf "$ARCHIVE" build/export

xcodebuild archive \
  -project StackStatus.xcodeproj \
  -scheme StackStatus \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  ONLY_ACTIVE_ARCH=NO \
  | grep -E 'error|warning: |ARCHIVE' || true

test -d "$ARCHIVE" || { echo "archive failed" >&2; exit 1; }

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export \
  | grep -E 'error|EXPORT' || true

test -d build/export/StackStatus.app || { echo "export failed" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 build/export/StackStatus.app
lipo -info build/export/StackStatus.app/Contents/MacOS/StackStatus
echo "Built build/export/StackStatus.app"
