#!/usr/bin/env bash
# go-legacy-win7 工具链：自动取上游最新版，无需手动改版本号
#
# 子命令：
#   resolve   查询版本，输出 tag / 下载地址 / SHA-256（供缓存 key 与校验用）
#   install   下载、校验、解压到目标目录
#
# 环境变量：
#   GO_WIN7_VERSION  指定版本 tag（如 v1.26.4-1）；留空自动取上游最新
#   GH_TOKEN         可选，给 gh 用；Actions 里传 secrets.GITHUB_TOKEN 可大幅提高 API 额度
#   GO_WIN7_SHA256   可选，手动指定哈希（覆盖自动解析）
set -euo pipefail

REPO="thongtech/go-legacy-win7"
# runner 是 Linux，工具链必须选 linux 版；目标平台由 GOOS 决定，与工具链平台无关
ASSET_OS="linux_amd64"
API="repos/${REPO}/releases"

# 取 release JSON：优先 gh（自带认证、额度高），失败用 curl
fetch_json() {
  local path="$1"
  if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}" ]; then
    gh api "$path" 2>/dev/null && return 0
  fi
  curl -fsSL --retry 3 --connect-timeout 15 \
    -H "User-Agent: win7-builds" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/${path}" 2>/dev/null
}

# 兜底：API 不可用时，靠 /releases/latest 的 302 跳转拿 tag
fetch_tag_by_redirect() {
  local loc
  loc="$(curl -sIL -o /dev/null -w '%{url_effective}' --max-time 25 \
    -A "win7-builds" \
    "https://github.com/${REPO}/releases/latest" 2>/dev/null || true)"
  [ -n "$loc" ] || return 1
  printf '%s' "${loc##*/}"
}

cmd_resolve() {
  local json="" tag="" ver="" asset="" url="" body="" sha=""

  if [ -n "${GO_WIN7_VERSION:-}" ]; then
    json="$(fetch_json "${API}/tags/${GO_WIN7_VERSION}" || true)"
  else
    json="$(fetch_json "${API}/latest" || true)"
  fi

  if [ -n "$json" ]; then
    tag="$(printf '%s' "$json" | jq -r '.tag_name // empty')"
  fi

  # 兜底：只解析出 tag，SHA-256 拿不到就跳过校验并告警
  if [ -z "$tag" ]; then
    echo "::warning::API 不可用（可能限流），改用重定向获取版本号，本次跳过哈希校验"
    tag="$(fetch_tag_by_redirect || true)"
    [ -n "$tag" ] && [ "$tag" != "latest" ] || { echo "::error::无法确定 go-legacy-win7 版本"; exit 1; }
  fi

  ver="${tag#v}"
  asset="go-legacy-win7-${ver}.${ASSET_OS}.tar.gz"

  if [ -n "$json" ]; then
    url="$(printf '%s' "$json" | jq -r --arg a "$asset" \
      '.assets[] | select(.name == $a) | .browser_download_url' | head -n 1)"
    # 从发布说明的表格里抓该文件对应的 SHA-256
    body="$(printf '%s' "$json" | jq -r '.body // ""')"
    sha="$(printf '%s' "$body" | grep -F "$asset" | grep -oE '[0-9a-f]{64}' | head -n 1 || true)"
  fi

  # 兜底拼 URL：/releases/latest/download/ 在 tag 未知时也能用固定文件名
  [ -n "$url" ] || url="https://github.com/${REPO}/releases/download/${tag}/${asset}"
  [ -n "${GO_WIN7_SHA256:-}" ] && sha="$GO_WIN7_SHA256"
  [ -n "$sha" ] || echo "::warning::未拿到 $asset 的 SHA-256，跳过校验"

  echo "go-legacy-win7 版本：$tag"
  {
    echo "tag=$tag"
    echo "asset=$asset"
    echo "url=$url"
    echo "sha256=$sha"
  } >> "${GITHUB_OUTPUT:-/dev/stdout}"
}

cmd_install() {
  local DEST="${1:-$HOME/go_win7}"
  local URL="${GO_WIN7_URL:?需要 GO_WIN7_URL}"
  local SHA="${GO_WIN7_SHA256:-}"
  local TAG="${GO_WIN7_TAG:-unknown}"

  if [ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$TAG" ] && [ -x "$DEST/bin/go" ]; then
    echo "工具链已是 $TAG，跳过安装"
    "$DEST/bin/go" version
    exit 0
  fi

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "下载 $URL"
  curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp/go.tgz" "$URL"

  if [ -n "$SHA" ]; then
    echo "校验 SHA-256 ..."
    echo "$SHA  $tmp/go.tgz" | sha256sum -c -
  fi

  mkdir -p "$tmp/unpack"
  tar -xzf "$tmp/go.tgz" -C "$tmp/unpack"

  local root
  root="$(dirname "$(find "$tmp/unpack" -maxdepth 2 -type f -path '*/bin/go' | head -n 1)")"
  [ -n "$root" ] || { echo "::error::压缩包里没找到 bin/go"; exit 1; }

  rm -rf "$DEST"
  mkdir -p "$DEST"
  cp -a "$root/." "$DEST/"
  echo "$TAG" > "$DEST/.version"
  "$DEST/bin/go" version
}

case "${1:-}" in
  resolve) cmd_resolve ;;
  install) shift; cmd_install "$@" ;;
  *) echo "用法：$0 {resolve|install} [目标目录]" >&2; exit 1 ;;
esac
