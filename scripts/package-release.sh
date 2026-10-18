#!/bin/bash
set -euo pipefail

# The source plist is authoritative. Tags must match it; releases never rewrite sources.
dt_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$dt_root"
dt_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if [[ ! "$dt_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'CFBundleShortVersionString must be a stable MAJOR.MINOR.PATCH version.' >&2
  exit 1
fi
if [[ -n "${DT_RELEASE_TAG:-}" && "$DT_RELEASE_TAG" != "v$dt_version" ]]; then
  echo 'The release tag must match CFBundleShortVersionString.' >&2
  exit 1
fi
dt_build_number="${DT_BUILD_NUMBER:-1}"
if [[ ! "$dt_build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo 'DT_BUILD_NUMBER must be a positive integer.' >&2
  exit 1
fi

dt_derived="${DT_DERIVED_DATA:-$dt_root/build}"
dt_dist="${DT_DIST_DIR:-$dt_root/dist}"
xcodegen generate --spec project.yml
xcodebuild -project DontsTool.xcodeproj -scheme DontsTool -configuration Release \
  -derivedDataPath "$dt_derived" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CURRENT_PROJECT_VERSION="$dt_build_number" build

dt_app="$dt_derived/Build/Products/Release/DontsTool.app"
dt_binary="$dt_app/Contents/MacOS/DontsTool"
for dt_arch in arm64 x86_64; do
  lipo -verify_arch "$dt_arch" "$dt_binary"
done
codesign --force --sign - --timestamp=none "$dt_app"
codesign --verify --deep --strict "$dt_app"
dt_signature="$(codesign -d --verbose=4 "$dt_app" 2>&1)"
grep -q '^Signature=adhoc$' <<< "$dt_signature"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dt_app/Contents/Info.plist")" == "$dt_version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$dt_app/Contents/Info.plist")" == "$dt_build_number" ]]

mkdir -p "$dt_dist"
dt_archive="DontsTool-$dt_version-macos-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$dt_app" "$dt_dist/$dt_archive"
dt_commit="${DT_SOURCE_COMMIT:-$(git rev-parse --verify HEAD 2>/dev/null || printf unknown)}"
python3 - "$dt_dist" "$dt_archive" "$dt_version" "$dt_build_number" "$dt_commit" <<'PY'
from pathlib import Path
import hashlib, json, sys
folder, archive, version, build, commit = sys.argv[1:]
root = Path(folder)
manifest = {
    'name': 'DontsTool', 'version': version, 'build': build, 'commit': commit,
    'platform': 'macOS', 'minimumSystemVersion': '26.0',
    'architectures': ['arm64', 'x86_64'], 'signing': 'ad-hoc', 'notarized': False,
    'archive': archive, 'sha256': hashlib.sha256((root / archive).read_bytes()).hexdigest()
}
(root / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
PY
(
  cd "$dt_dist"
  shasum -a 256 "$dt_archive" manifest.json > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
# Validate the actual archive, not only the build directory.
dt_verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/dontstool-release-verify.XXXXXX")"
trap 'rm -rf "$dt_verify_dir"' EXIT
ditto -x -k "$dt_dist/$dt_archive" "$dt_verify_dir"
codesign --verify --deep --strict "$dt_verify_dir/DontsTool.app"
for dt_arch in arm64 x86_64; do
  lipo -verify_arch "$dt_arch" "$dt_verify_dir/DontsTool.app/Contents/MacOS/DontsTool"
done
cmp "$dt_binary" "$dt_verify_dir/DontsTool.app/Contents/MacOS/DontsTool"
printf '\nRelease package: %s\n' "$dt_dist/$dt_archive"
