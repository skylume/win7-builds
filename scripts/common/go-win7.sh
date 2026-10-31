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
#   GO_WIN7_URL      产物下载地址（install 必需）
#   GO_WIN7_SHA256   可选，手动指定哈希（覆盖自动解析）
#   GO_WIN7_TAG      版本 tag，写入目标目录 .version 供缓存复用判断
set -euo pipefail

REPO="thongtech/go-legacy-win7"
# runner 是 Linux，工具链必须选 linux 版；目标平台由 GOOS 决定，与工具链平台无关
ASSET_OS="linux_amd64"
API="repos/${REPO}/releases"

# 临时目录用全局变量：函数内的 local 在 EXIT trap 触发时已被销毁，会报 unbound variable
TMP_DIR=""
cleanup() {
  if [ -n "${TMP_DIR:-}" ] && [ -d "${TMP_DIR:-}" ]; then
    rm -rf "$TMP_DIR"
  fi
  return 0
}
trap cleanup EXIT

die() {
  printf '::error::%s\n' "$*"
  exit 1
}

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
    [ -n "$tag" ] && [ "$tag" != "latest" ] || die "无法确定 go-legacy-win7 版本"
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

# 在解压目录里定位 GOROOT：找 bin/go，取其上一级目录
# 注意：tarball 顶层目录是 go-legacy-win7（官方安装文档即 GOROOT=/usr/local/go-legacy-win7），
# 因此 bin/go 位于 顶层/bin/go，深度不能用 maxdepth 2 限制，否则匹配不到。
locate_goroot() {
  local base="$1" cand="" root=""
  cand="$(find "$base" -type f -path '*/bin/go' -print 2>/dev/null | sort | head -n 1 || true)"
  [ -n "$cand" ] || return 1
  [ -f "$cand" ] || return 1

  root="$(dirname "$(dirname "$cand")")"
  # 必须仍在解压目录内，避免 dirname 拿到相对路径 "." 之类
  case "$root" in
    "$base"/*) ;;
    *) return 1 ;;
  esac
  [ -f "$root/bin/go" ] || return 1

  printf '%s' "$root"
}

cmd_install() {
  local DEST="${1:-$HOME/go_win7}"
  local URL="${GO_WIN7_URL:?需要 GO_WIN7_URL}"
  local SHA="${GO_WIN7_SHA256:-}"
  local TAG="${GO_WIN7_TAG:-unknown}"

  if [ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$TAG" ] && [ -x "$DEST/bin/go" ]; then
    echo "工具链已是 $TAG，跳过安装"
    "$DEST/bin/go" version
    return 0
  fi

  TMP_DIR="$(mktemp -d)"
  echo "下载 $URL"
  curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP_DIR/go.tgz" "$URL"
  [ -s "$TMP_DIR/go.tgz" ] || die "下载为空：$URL"

  if [ -n "$SHA" ]; then
    echo "校验 SHA-256 ..."
    echo "$SHA  $TMP_DIR/go.tgz" | sha256sum -c -
  fi

  mkdir -p "$TMP_DIR/unpack"
  tar -xzf "$TMP_DIR/go.tgz" -C "$TMP_DIR/unpack"

  echo "压缩包顶层结构："
  find "$TMP_DIR/unpack" -maxdepth 1 -mindepth 1 | sed 's/^/  /'

  local root=""
  root="$(locate_goroot "$TMP_DIR/unpack")" \
    || die "压缩包里没找到 bin/go，结构可能变了，请检查上面的顶层结构"

  echo "GOROOT：$root"

  rm -rf "$DEST"
  mkdir -p "$DEST"
  cp -a "$root/." "$DEST/"
  chmod +x "$DEST/bin/go" 2>/dev/null || true
  [ -x "$DEST/bin/go" ] || die "安装后 $DEST/bin/go 仍不存在"
  echo "$TAG" > "$DEST/.version"
  "$DEST/bin/go" version
}

case "${1:-}" in
  resolve) cmd_resolve ;;
  install) shift; cmd_install "$@"; exit 0 ;;
  *) echo "用法：$0 {resolve|install} [目标目录]" >&2; exit 1 ;;
esac
