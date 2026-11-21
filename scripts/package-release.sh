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
dt_update_key="${DT_UPDATE_KEY_FILE:-$dt_root/.signing/updater/private.key}"
if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  [[ -f "$dt_update_key" ]] || { echo 'An update signing key is required.' >&2; exit 1; }
fi
dt_update_repo="$(python3 - <<'PY'
import plistlib, re
from pathlib import Path
feed = plistlib.loads(Path('Resources/Info.plist').read_bytes())['SUFeedURL']
match = re.fullmatch(r'https://github.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/releases/latest/download/appcast.xml', feed)
assert match, 'Unexpected update feed URL'
print(match[1])
PY
)"

dt_team_id='Q2K3CAKGG2'
dt_req='identifier "com.donts.DontsTool" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "Q2K3CAKGG2"'

if [[ -n "${DT_SIGNING_IDENTITY:-}" ]]; then
  dt_identity="$DT_SIGNING_IDENTITY"
else
  dt_find_args=(-v -p codesigning)
  if [[ -n "${DT_SIGNING_KEYCHAIN:-}" ]]; then
    dt_find_args+=("$DT_SIGNING_KEYCHAIN")
  fi
  dt_identities_raw="$(security find-identity "${dt_find_args[@]}")"
  dt_identity="$(DT_IDENTITIES_RAW="$dt_identities_raw" python3 - "$dt_team_id" <<'PY'
import os, re, sys
team = sys.argv[1]
pattern = re.compile(rf'^\s*\d+\)\s+([0-9A-Fa-f]{{40}})\s+"Developer ID Application: .*\({re.escape(team)}\)"\s*$', re.MULTILINE)
matches = list(dict.fromkeys(m.upper() for m in pattern.findall(os.environ['DT_IDENTITIES_RAW'])))
if not matches:
    sys.stderr.write(f'No valid "Developer ID Application (... ({team}))" signing identity found. Install the certificate or set DT_SIGNING_IDENTITY.\n')
    sys.exit(1)
if len(matches) > 1:
    sys.stderr.write(f'Multiple Developer ID Application identities found for {team}; set DT_SIGNING_IDENTITY to select one:\n' + '\n'.join(matches) + '\n')
    sys.exit(1)
print(matches[0])
PY
)"
fi

if [[ -n "${APPLE_ID:-}" || -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  if [[ -z "${APPLE_ID:-}" || -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    echo 'Both APPLE_ID and APPLE_APP_SPECIFIC_PASSWORD are required when using Apple ID notarization.' >&2
    exit 1
  fi
  dt_notary_args=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$dt_team_id")
else
  dt_notary_args=(--keychain-profile "${DT_NOTARY_PROFILE:-DontsTool-Notary}")
  if [[ -n "${DT_NOTARY_KEYCHAIN:-}" ]]; then
    dt_notary_args+=(--keychain "$DT_NOTARY_KEYCHAIN")
  fi
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
  lipo "$dt_binary" -verify_arch "$dt_arch"
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dt_app/Contents/Info.plist")" == "$dt_version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$dt_app/Contents/Info.plist")" == "$dt_build_number" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$dt_app/Contents/Info.plist")" == "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$dt_app/Contents/Info.plist")" == "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Resources/Info.plist)" ]]
[[ -d "$dt_app/Contents/Frameworks/Sparkle.framework" ]]

dt_sign() {
  local dt_target="$1"
  shift
  local dt_sign_args=(--force --options runtime --timestamp --sign "$dt_identity")
  if [[ -n "${DT_SIGNING_KEYCHAIN:-}" ]]; then
    dt_sign_args+=(--keychain "$DT_SIGNING_KEYCHAIN")
  fi
  if [[ $# -gt 0 ]]; then
    dt_sign_args+=("$@")
  fi
  codesign "${dt_sign_args[@]}" "$dt_target"
}

dt_sparkle="$dt_app/Contents/Frameworks/Sparkle.framework"
dt_sign "$dt_sparkle/Versions/B/XPCServices/Downloader.xpc"
dt_sign "$dt_sparkle/Versions/B/XPCServices/Installer.xpc"
dt_sign "$dt_sparkle/Versions/B/Autoupdate"
dt_sign "$dt_sparkle/Versions/B/Updater.app"
dt_sign "$dt_sparkle"

dt_helpers_dir="$dt_app/Contents/Helpers"
if [[ -d "$dt_helpers_dir" ]]; then
  while IFS= read -r -d '' dt_helper; do
    for dt_arch in arm64 x86_64; do
      lipo "$dt_helper" -verify_arch "$dt_arch"
    done
    dt_sign "$dt_helper"
  done < <(find "$dt_helpers_dir" -maxdepth 1 -type f -perm -111 -print0)
fi

dt_sign "$dt_app" --entitlements "$dt_root/Resources/DontsTool.entitlements"

codesign --verify --deep --strict -R="$dt_req" "$dt_app"
dt_signature="$(codesign -dv --verbose=4 "$dt_app" 2>&1)"
grep -q "^TeamIdentifier=$dt_team_id$" <<< "$dt_signature"
grep -q '^Authority=Developer ID Application:' <<< "$dt_signature"
grep -q '^Timestamp=' <<< "$dt_signature"
grep -Eq '^CodeDirectory .* flags=.*\(runtime\)' <<< "$dt_signature"

dt_work="$(mktemp -d "${TMPDIR:-/tmp}/dontstool-release-work.XXXXXX")"
trap 'rm -rf "$dt_work"' EXIT

ditto -c -k --sequesterRsrc --keepParent "$dt_app" "$dt_work/notary-submit.zip"
dt_notary_timeout="${DT_NOTARY_TIMEOUT:-45m}"
dt_notary_status_rc=0
xcrun notarytool submit "$dt_work/notary-submit.zip" "${dt_notary_args[@]}" \
  --wait --timeout "$dt_notary_timeout" --output-format json \
  > "$dt_work/notary-stdout.json" 2> "$dt_work/notary-stderr.txt" || dt_notary_status_rc=$?
{
  IFS= read -r dt_notary_status
  IFS= read -r dt_submission_id
  IFS= read -r dt_notary_message
  IFS= read -r dt_notary_parsed_json
} < <(python3 - "$dt_work/notary-stdout.json" "$dt_work/notary-stderr.txt" <<'PY'
import json, re, sys
from pathlib import Path

def clean(value):
    return re.sub(r'[\r\n]+', ' ', str(value or '')).strip()

stdout_raw = Path(sys.argv[1]).read_text(errors='replace').strip()
stderr_raw = Path(sys.argv[2]).read_text(errors='replace').strip()
for candidate in (stdout_raw, stderr_raw):
    if not candidate:
        continue
    try:
        data = json.loads(candidate)
    except json.JSONDecodeError:
        continue
    if isinstance(data, dict):
        print(clean(data.get('status')))
        print(clean(data.get('id')))
        print(clean(data.get('message')))
        print('1')
        sys.exit(0)
raw = stdout_raw or stderr_raw
print('MISSING' if not raw else 'INVALID_JSON')
print('')
print(clean(raw))
print('0')
PY
)
if [[ "$dt_notary_status_rc" -ne 0 || "$dt_notary_status" != 'Accepted' ]]; then
  echo "Apple notarization failed (exit=$dt_notary_status_rc, status=${dt_notary_status:-unknown}, id=${dt_submission_id:-none}, message=${dt_notary_message:-none})." >&2
  if [[ "$dt_notary_parsed_json" != '1' && -s "$dt_work/notary-stderr.txt" ]]; then
    cat "$dt_work/notary-stderr.txt" >&2
  fi
  if [[ "$dt_notary_status_rc" -eq 124 && -n "${dt_submission_id:-}" ]]; then
    echo "Notarization is still in progress on Apple servers; check status with: xcrun notarytool info \"$dt_submission_id\"" >&2
  elif [[ -n "${dt_submission_id:-}" ]]; then
    xcrun notarytool log "$dt_submission_id" "${dt_notary_args[@]}" >&2 || true
  fi
  exit 1
fi

xcrun stapler staple "$dt_app"
xcrun stapler validate "$dt_app"
spctl --assess --type execute --verbose=4 "$dt_app"

mkdir -p "$dt_dist"
dt_archive="DontsTool-$dt_version-macos-universal.zip"
rm -f "$dt_dist/$dt_archive" "$dt_dist/manifest.json" "$dt_dist/appcast.xml" "$dt_dist/SHA256SUMS"
ditto -c -k --sequesterRsrc --keepParent "$dt_app" "$dt_dist/$dt_archive"
dt_commit="${DT_SOURCE_COMMIT:-$(git rev-parse --verify HEAD 2>/dev/null || printf unknown)}"
python3 - "$dt_dist" "$dt_archive" "$dt_version" "$dt_build_number" "$dt_commit" "$dt_team_id" <<'PY'
from pathlib import Path
import hashlib, json, sys
folder, archive, version, build, commit, team_id = sys.argv[1:]
root = Path(folder)
manifest = {
    'name': 'DontsTool', 'version': version, 'build': build, 'commit': commit,
    'platform': 'macOS', 'minimumSystemVersion': '26.0',
    'architectures': ['arm64', 'x86_64'], 'signing': 'developer-id',
    'teamId': team_id, 'notarized': True,
    'archive': archive, 'sha256': hashlib.sha256((root / archive).read_bytes()).hexdigest()
}
(root / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
PY
dt_feed_args=(generate --dist "$dt_dist" --repository "$dt_update_repo"
  --sign-tool "$dt_derived/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update")
if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  dt_feed_args+=(--key-file "$dt_update_key")
fi
if [[ -f "docs/releases/v$dt_version.md" ]]; then
  dt_feed_args+=(--notes "docs/releases/v$dt_version.md")
fi
python3 scripts/update-feed.py "${dt_feed_args[@]}"
(
  cd "$dt_dist"
  shasum -a 256 "$dt_archive" manifest.json appcast.xml > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
# Validate the actual archive, not only the build directory.
mkdir -p "$dt_work/verify"
ditto -x -k "$dt_dist/$dt_archive" "$dt_work/verify"
codesign --verify --deep --strict -R="$dt_req" "$dt_work/verify/DontsTool.app"
xcrun stapler validate "$dt_work/verify/DontsTool.app"
spctl --assess --type execute --verbose=4 "$dt_work/verify/DontsTool.app"
for dt_arch in arm64 x86_64; do
  lipo "$dt_work/verify/DontsTool.app/Contents/MacOS/DontsTool" -verify_arch "$dt_arch"
done
cmp "$dt_binary" "$dt_work/verify/DontsTool.app/Contents/MacOS/DontsTool"
printf '\nRelease package: %s\n' "$dt_dist/$dt_archive"
