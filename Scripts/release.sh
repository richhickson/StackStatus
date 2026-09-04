#!/bin/bash
# Full release: bump version, build, notarise, tag, GitHub release, cask update.
# Usage: Scripts/release.sh 0.1.0 [notes-file]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?version, e.g. 0.1.0}"
NOTES="${2:-}"

# Version lives in project.yml (source of truth) and the generated project.
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
sed -i '' "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $VERSION;/" StackStatus.xcodeproj/project.pbxproj

Scripts/build.sh
Scripts/notarize.sh

SHA=$(cut -d' ' -f1 dist/StackStatus.zip.sha256)
sed -i '' "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/stackstatus.rb

git add project.yml StackStatus.xcodeproj/project.pbxproj Casks/stackstatus.rb CHANGELOG.md
git commit -m "Release $VERSION" || true
git tag -a "v$VERSION" -m "StackStatus $VERSION"
git push origin HEAD --tags

if [[ -n "$NOTES" ]]; then
  gh release create "v$VERSION" dist/StackStatus.zip --title "v$VERSION" --notes-file "$NOTES"
else
  gh release create "v$VERSION" dist/StackStatus.zip --title "v$VERSION" --generate-notes
fi
echo "Released v$VERSION. Cask updated with sha256 $SHA."
