#!/usr/bin/env bash
# 查询上游源码仓库的最新 tag
# 用法：ref="$(bash scripts/common/upstream.sh latest-tag <owner/repo>)"
# stdout 只输出 tag 本身；日志走 stderr；若设置了 GITHUB_OUTPUT 也会写入 upstream_tag
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }

REPO="${2:?需要 owner/repo}"
API="repos/${REPO}/tags"

json=""
if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}" ]; then
  json="$(gh api "$API" --paginate 2>/dev/null || true)"
fi
if [ -z "$json" ]; then
  json="$(curl -fsSL --retry 3 --connect-timeout 15 \
    -H "User-Agent: win7-builds" \
    "https://api.github.com/${API}?per_page=30" 2>/dev/null || true)"
fi

tag=""
if [ -n "$json" ]; then
  # 取第一个符合 v数字.数字... 的 tag，跳过 beta/rc 之类
  tag="$(printf '%s' "$json" | jq -r '.[].name // empty' \
    | grep -E '^v?[0-9]+(\.[0-9]+)+(-[0-9A-Za-z.]+)?$' | head -n 1 || true)"
fi

[ -n "$tag" ] || { log "::error::无法获取 ${REPO} 的 tag，请手动填写 source_ref"; exit 1; }

log "上游最新 tag：$tag"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "upstream_tag=$tag" >> "$GITHUB_OUTPUT"
printf '%s' "$tag"
