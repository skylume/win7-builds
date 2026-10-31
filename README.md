# Win7 兼容构建

为已放弃 Windows 7 支持的 Go 项目构建 Win7 可用二进制，基于 [go-legacy-win7](https://github.com/thongtech/go-legacy-win7)。产物见 [Releases](../../releases)。

| 项目 | 短名 | 上游源码 | Tag 查询 | 产物 |
|---|---|---|---|---|
| CFData-WEB | `cfdata` | [PoemMisty/CFData-WEB](https://github.com/PoemMisty/CFData-WEB) | [tags](https://github.com/PoemMisty/CFData-WEB/tags) | `cfdata-v<版本>-win7-amd64.zip` |
| sing-box reF1nd | `singbox` | [reF1nd/sing-box](https://github.com/reF1nd/sing-box) | [tags](https://github.com/reF1nd/sing-box/tags) | `singbox-v<版本>-win7-{amd64,386}.zip` |

## 触发构建

Actions → 选对应工作流 → Run workflow

| 字段 | 说明 |
|---|---|
| `version` | 版本号，如 `1.8.5`。留空自动按源码 ref 推导 |
| `source_ref` | 源码 tag 或分支，如 `v1.8.5`。**留空自动取上游最新 tag**（从上表 Tag 查询页可复制完整名） |
| `create_release` | 测试不勾，正式发布勾选 |

`source_ref` 无论手填还是留空，产物与 Release 完全一致：留空时脚本会解析出真实 tag 再写入 Release 说明，与手填的效果没有区别。

工具链版本自动跟随上游最新，要固定改 workflow 顶部的 `GO_WIN7_VERSION`。

## 结构

```
.github/workflows/          # 只识别这一层，不支持子目录，靠文件名区分
scripts/common/
    go-win7.sh              # 解析最新版 + 下载校验 go-legacy-win7
    upstream.sh             # 查询源码仓库最新 tag
```

新增项目：复制最接近的 workflow，改 `SLUG`、`SRC_REPO` 和「项目特有部分」之间的构建命令。

> 源码 checkout 必须带 `path: src`，否则会覆盖本仓库的 `scripts/`。
> 同一版本重跑会覆盖已有 Release，需保留就给 version 加后缀（如 `1.8.5-r2`）。
