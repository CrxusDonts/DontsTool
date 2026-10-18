#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
: "${DT_RELEASE_TAG:?DT_RELEASE_TAG is required}"
: "${GH_REPO:?GH_REPO is required}"
if [[ ! "$DT_RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'Invalid stable release tag.' >&2
  exit 1
fi
dt_version="${DT_RELEASE_TAG#v}"
dt_commit="$(git rev-parse HEAD)"
# Check the remote tag still identifies the verified source before creating a release.
DT_EXPECTED_COMMIT="$dt_commit" ./scripts/resolve-release-tag.sh >/dev/null
dt_archive="DontsTool-$dt_version-macos-universal.zip"
# Refuse a version mismatch or publishing a different commit's artifact.
python3 - "$dt_version" "$dt_commit" <<'PY'
import json, sys
from pathlib import Path
m = json.loads(Path('dist/manifest.json').read_text())
assert m['version'] == sys.argv[1] and m['commit'] == sys.argv[2]
assert m['signing'] == 'ad-hoc' and m['notarized'] is False
PY
(cd dist && shasum -a 256 -c SHA256SUMS)
dt_work="$(mktemp -d "${TMPDIR:-/tmp}/dontstool-publish.XXXXXX")"
trap 'rm -rf "$dt_work"' EXIT
dt_marker="<!-- dontstool-release:$dt_commit -->"
cat > "$dt_work/notes.md" <<NOTES
$dt_marker
原生 macOS 研发效率启动器。

- 支持 macOS 26 或更新版本，Universal 包含 Apple Silicon 和 Intel 架构。
- 本版本使用 ad-hoc 本地签名，未经 Apple 公证，不需要 Developer ID 证书。
- 下载 ZIP、manifest.json 与 SHA256SUMS 后先校验，再将 DontsTool.app 放入 Applications。
- 安装及首次打开说明：[README](https://github.com/$GH_REPO/blob/$DT_RELEASE_TAG/README.md#安装)。
- 源码提交：$dt_commit
NOTES
# Published versions are immutable. A retry may resume only this commit's own draft.
if gh release view "$DT_RELEASE_TAG" --repo "$GH_REPO" --json isDraft,body > "$dt_work/existing.json" 2>/dev/null; then
  python3 - "$dt_work/existing.json" "$dt_marker" <<'PY'
import json, sys
from pathlib import Path
release = json.loads(Path(sys.argv[1]).read_text())
if not release['isDraft'] or sys.argv[2] not in release['body']:
    raise SystemExit('Existing release is published or belongs to another source; refusing to overwrite.')
PY
else
  gh release create "$DT_RELEASE_TAG" --repo "$GH_REPO" --verify-tag --draft \
    --title "DontsTool $DT_RELEASE_TAG" --notes-file "$dt_work/notes.md"
fi
gh release upload "$DT_RELEASE_TAG" --repo "$GH_REPO" --clobber \
  "dist/$dt_archive" dist/manifest.json dist/SHA256SUMS
mkdir "$dt_work/download"
gh release download "$DT_RELEASE_TAG" --repo "$GH_REPO" --dir "$dt_work/download" \
  --pattern "$dt_archive" --pattern manifest.json --pattern SHA256SUMS
(cd "$dt_work/download" && shasum -a 256 -c SHA256SUMS)
for dt_asset in "$dt_archive" manifest.json SHA256SUMS; do
  cmp "dist/$dt_asset" "$dt_work/download/$dt_asset"
done
gh release edit "$DT_RELEASE_TAG" --repo "$GH_REPO" --draft=false --latest
printf 'Release: https://github.com/%s/releases/tag/%s\n' "$GH_REPO" "$DT_RELEASE_TAG"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '### Published\n[DontsTool %s](https://github.com/%s/releases/tag/%s)\n\nUniversal ZIP, manifest and checksums were downloaded and byte-compared before publication.\n' \
    "$DT_RELEASE_TAG" "$GH_REPO" "$DT_RELEASE_TAG" >> "$GITHUB_STEP_SUMMARY"
fi
