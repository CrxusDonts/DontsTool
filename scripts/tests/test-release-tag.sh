#!/bin/bash
set -euo pipefail
dt_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dt_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dontstool-tag-test.XXXXXX")"
trap 'rm -rf "$dt_fixture"' EXIT
# Mock only the external GitHub API transport. Unknown endpoints, including branch
# lookup, fail; tag peeling and expected-commit validation use production code.
cat > "$dt_fixture/gh" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ "$1" == api ]]
case "$2" in
  repos/fixture/repo/git/ref/tags/v0.1.0)
    case "${DT_FIXTURE_MODE:-annotated}" in
      lightweight) printf 'commit\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
      tree) printf 'tree\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
      *) printf 'tag\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
    esac ;;
  repos/fixture/repo/git/tags/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
    printf 'commit\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
  *) echo 'Unexpected API endpoint' >&2; exit 1 ;;
esac
MOCK
chmod +x "$dt_fixture/gh"
export PATH="$dt_fixture:$PATH"
export GH_REPO=fixture/repo DT_RELEASE_TAG=v0.1.0
[[ "$("$dt_root/scripts/resolve-release-tag.sh")" == bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]]
[[ "$(DT_FIXTURE_MODE=lightweight "$dt_root/scripts/resolve-release-tag.sh")" == bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]]
DT_EXPECTED_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$dt_root/scripts/resolve-release-tag.sh" >/dev/null
if DT_EXPECTED_COMMIT=cccccccccccccccccccccccccccccccccccccccc "$dt_root/scripts/resolve-release-tag.sh" >/dev/null 2>&1; then
  echo 'Moved tag was accepted' >&2; exit 1
fi
if DT_FIXTURE_MODE=tree "$dt_root/scripts/resolve-release-tag.sh" >/dev/null 2>&1; then
  echo 'Tree object was accepted' >&2; exit 1
fi
if DT_RELEASE_TAG=main "$dt_root/scripts/resolve-release-tag.sh" >/dev/null 2>&1; then
  echo 'Non-version input was accepted' >&2; exit 1
fi
printf 'Release tag tests: 6 checks passed\n'
