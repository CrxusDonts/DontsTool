#!/bin/bash
set -euo pipefail

dt_repository='CrxusDonts/DontsTool'
dt_install_dir='/Applications'
dt_tag=''
dt_work=''
dt_stage=''
dt_lock=''
dt_installed=0

dt_fail() { printf '安装失败：%s\n' "$*" >&2; exit 1; }
dt_usage() {
  cat <<'USAGE'
安装 DontsTool 最新稳定版（macOS 26+，Apple Silicon / Intel）。

用法：bash install.sh [--dir /绝对路径] [--version v0.2.6]
  --dir       安装目录，默认 /Applications；无写入权限时可用 "$HOME/Applications"
  --version   安装指定稳定版；默认下载最新 Release
  --help      显示帮助

更新前请保存草稿并从菜单栏正常退出 DontsTool。脚本不会强制退出、自动
启动应用或移除 macOS 隔离标记，也不需要 sudo、GitHub 登录或开发工具。
USAGE
}
dt_cleanup() {
  if [[ -n "$dt_stage" && -d "$dt_stage" ]]; then
    if [[ -d "$dt_stage/previous.app" && "$dt_installed" == 0 ]]; then
      if [[ -e "$dt_install_dir/DontsTool.app" || -L "$dt_install_dir/DontsTool.app" ]] \
        || ! mv "$dt_stage/previous.app" "$dt_install_dir/DontsTool.app"; then
        printf '旧版保留在 %s/previous.app，请手动恢复。\n' "$dt_stage" >&2
        [[ -z "$dt_lock" ]] || rmdir "$dt_lock"
        [[ -z "$dt_work" ]] || rm -rf "$dt_work"
        return
      fi
    fi
    rm -rf "$dt_stage"
  fi
  [[ -z "$dt_lock" ]] || rmdir "$dt_lock"
  [[ -z "$dt_work" ]] || rm -rf "$dt_work"
}
trap dt_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) [[ $# -ge 2 && -n "$2" ]] || dt_fail '--dir 缺少目录'; dt_install_dir="$2"; shift 2 ;;
    --version) [[ $# -ge 2 && "$2" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || dt_fail '版本格式应为 vMAJOR.MINOR.PATCH'; dt_tag="$2"; shift 2 ;;
    --help|-h) dt_usage; exit 0 ;;
    *) dt_fail "未知参数：$1（使用 --help 查看帮助）" ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || dt_fail '仅支持 macOS'
[[ $EUID -ne 0 ]] || dt_fail '请使用普通用户运行，不要使用 sudo'
[[ "$dt_install_dir" == /* ]] || dt_fail '安装目录必须是绝对路径'
case "$(uname -m)" in arm64|x86_64) ;; *) dt_fail '仅支持 Apple Silicon 和 Intel Mac' ;; esac

dt_version_ge() {
  local dt_have dt_need dt_i
  [[ "$1" =~ ^[0-9]+(\.[0-9]+){0,2}$ && "$2" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
  IFS=. read -r -a dt_have <<< "$1"
  IFS=. read -r -a dt_need <<< "$2"
  for dt_i in 0 1 2; do
    (( 10#${dt_have[$dt_i]:-0} >= 10#${dt_need[$dt_i]:-0} )) || return 1
    if (( 10#${dt_have[$dt_i]:-0} > 10#${dt_need[$dt_i]:-0} )); then return 0; fi
  done
}
dt_os="$(sw_vers -productVersion)"
dt_version_ge "$dt_os" 26.0 || dt_fail '需要 macOS 26 或更新版本'
dt_check_stopped() {
  if pgrep -x DontsTool >/dev/null; then
    dt_fail 'DontsTool 正在运行，请保存草稿并从菜单栏正常退出后重试'
  fi
}
dt_check_stopped
mkdir -p "$dt_install_dir" || dt_fail '无法创建安装目录'
[[ -w "$dt_install_dir" ]] || dt_fail "安装目录不可写；可添加 --dir \"$HOME/Applications\"，无需 sudo"
if ! mkdir "$dt_install_dir/.DontsTool-install.lock" 2>/dev/null; then
  dt_fail "安装锁已存在：$dt_install_dir/.DontsTool-install.lock。请等待其他安装完成；若任务已异常结束，确认没有安装任务后再删除此空目录"
fi
dt_lock="$dt_install_dir/.DontsTool-install.lock"
dt_target="$dt_install_dir/DontsTool.app"
[[ ! -L "$dt_target" ]] || dt_fail '目标应用是符号链接，请手动处理后重试'
if [[ -e "$dt_target" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dt_target/Contents/Info.plist" 2>/dev/null)" == 'com.donts.DontsTool' ]] \
    || dt_fail '目标位置已有其他文件或应用，拒绝覆盖'
fi

dt_work="$(mktemp -d "${TMPDIR:-/tmp}/dontstool-install.XXXXXX")"
dt_fetch() {
  curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 300 \
    --proto '=https' --proto-redir '=https' --output "$2" "$1" \
    || dt_fail '下载失败；请检查网络，以及仓库和 Release 是否已公开'
}
dt_base="https://github.com/$dt_repository/releases"
if [[ -n "$dt_tag" ]]; then
  dt_manifest_url="$dt_base/download/$dt_tag/manifest.json"
else
  dt_manifest_url="$dt_base/latest/download/manifest.json"
fi
printf '正在读取发布信息…\n'
dt_fetch "$dt_manifest_url" "$dt_work/manifest.json"
dt_json() { plutil -extract "$1" raw -o - "$dt_work/manifest.json"; }
dt_version="$(dt_json version)"
[[ "$dt_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || dt_fail '发布版本号无效'
[[ -z "$dt_tag" || "$dt_tag" == "v$dt_version" ]] || dt_fail '发布版本与请求不一致'
dt_tag="v$dt_version"
dt_archive="DontsTool-$dt_version-macos-universal.zip"
[[ "$(dt_json name)" == DontsTool && "$(dt_json platform)" == macOS && "$(dt_json archive)" == "$dt_archive" ]] \
  || dt_fail '发布信息中的应用或安装包名称无效'
dt_version_ge "$dt_os" "$(dt_json minimumSystemVersion)" || dt_fail '当前系统低于此版本的最低要求'
dt_expected_sha="$(dt_json sha256)"
[[ "$dt_expected_sha" =~ ^[0-9a-f]{64}$ ]] || dt_fail '发布信息中的 SHA256 无效'

# Pin all remaining downloads to the manifest version, even if latest changes.
dt_fetch "$dt_base/download/$dt_tag/SHA256SUMS" "$dt_work/SHA256SUMS"
dt_check_hash() {
  local dt_file="$1" dt_expected dt_actual
  dt_expected="$(awk -v name="$dt_file" '$2 == name { print $1; count++ } END { if (count != 1) exit 1 }' "$dt_work/SHA256SUMS")" \
    || dt_fail "SHA256SUMS 缺少或重复记录：$dt_file"
  [[ "$dt_expected" =~ ^[0-9a-f]{64}$ ]] || dt_fail 'SHA256SUMS 格式无效'
  dt_actual="$(shasum -a 256 "$dt_work/$dt_file")"
  [[ "${dt_actual%% *}" == "$dt_expected" ]] || dt_fail "SHA256 校验失败：$dt_file"
}
dt_check_hash manifest.json
printf '正在下载 DontsTool %s…\n' "$dt_version"
dt_fetch "$dt_base/download/$dt_tag/$dt_archive" "$dt_work/$dt_archive"
dt_check_hash "$dt_archive"
dt_actual_sha="$(shasum -a 256 "$dt_work/$dt_archive")"
[[ "${dt_actual_sha%% *}" == "$dt_expected_sha" ]] || dt_fail '安装包与 manifest.json 的 SHA256 不一致'

zipinfo -1 "$dt_work/$dt_archive" > "$dt_work/entries"
while IFS= read -r dt_entry; do
  case "$dt_entry" in DontsTool.app/|DontsTool.app/*|__MACOSX/|__MACOSX/DontsTool.app/|__MACOSX/DontsTool.app/*) ;; *) dt_fail '安装包包含意外路径' ;; esac
  case "/$dt_entry/" in *'/../'*|*'/./'*) dt_fail '安装包包含不安全路径' ;; esac
done < "$dt_work/entries"
ditto -x -k "$dt_work/$dt_archive" "$dt_work/extracted"
dt_app="$dt_work/extracted/DontsTool.app"
[[ -d "$dt_app" && ! -L "$dt_app" ]] || dt_fail '安装包缺少 DontsTool.app'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dt_app/Contents/Info.plist")" == 'com.donts.DontsTool' ]] || dt_fail '应用标识不匹配'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dt_app/Contents/Info.plist")" == "$dt_version" ]] || dt_fail '应用版本不匹配'
codesign --verify --deep --strict "$dt_app" || dt_fail '应用签名完整性检查失败'

dt_stage="$(mktemp -d "$dt_install_dir/.DontsTool-install.XXXXXX")"
ditto "$dt_app" "$dt_stage/DontsTool.app"
codesign --verify --deep --strict "$dt_stage/DontsTool.app" || dt_fail '安装副本签名完整性检查失败'
dt_check_stopped
if [[ -e "$dt_target" ]]; then mv "$dt_target" "$dt_stage/previous.app"; fi
[[ ! -e "$dt_target" && ! -L "$dt_target" ]] || dt_fail '安装位置被其他操作占用，请检查后重试'
mv "$dt_stage/DontsTool.app" "$dt_target"
codesign --verify --deep --strict "$dt_target" || dt_fail '安装后签名完整性检查失败'
dt_installed=1
printf '\n已安装 DontsTool %s：%s\n' "$dt_version" "$dt_target"
printf '请在访达中打开应用，按 ⌥ Space 呼出启动器。\n'
printf '当前发布使用本地签名，未经 Apple 公证。如被系统拦截，请在「系统设置 → 隐私与安全性」允许打开。\n'
