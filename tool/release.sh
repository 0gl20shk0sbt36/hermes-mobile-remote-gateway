#!/usr/bin/env bash
# 出一次"可交付"的包：正式包 + 离线演示包（arm64），核验后投递到共享目录。
#
# 用法: tool/release.sh [交付目录]（默认 ~/share/apk/hermes-mobile）
# 产物命名: hermes-mobile-<versionName>-<versionCode>-arm64[-demo].apk + 同名 .json 清单
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT_DIR="${1:-$HOME/share/apk/hermes-mobile}"
mkdir -p "$OUT_DIR"

bash tool/build-apk.sh --abi arm64 --no-copy
bash tool/build-apk.sh --abi arm64 --demo --no-copy

# 汇总校验（同时给出新旧两种文件名，方便老路径继续可用）
( cd dist && sha256sum hermes-mobile-*.apk > SHA256SUMS && cat SHA256SUMS )
cp -f dist/hermes-mobile-*.apk dist/*.json dist/SHA256SUMS "$OUT_DIR/"

# 兼容旧路径（用户手机上一直用的名字）
VER="$(python3 -c "import re;print(re.search(r'^version:\s*([^+]+)',open('pubspec.yaml').read(),re.M).group(1).strip())")"
CODE="$(python3 -c "import re;print(re.search(r'^version:.*\+(\d+)',open('pubspec.yaml').read(),re.M).group(1).strip())")"
cp -f "dist/hermes-mobile-${VER}-${CODE}-arm64.apk" "$HOME/share/apk/hermes-mobile-i18n-fixes-arm64.apk"
cp -f "dist/hermes-mobile-${VER}-${CODE}-arm64-demo.apk" "$HOME/share/apk/hermes-mobile-i18n-fixes-demo-arm64.apk"
( cd "$HOME/share/apk" && sha256sum hermes-mobile-i18n-fixes-arm64.apk > hermes-mobile-i18n-fixes-arm64.sha256 \
  && sha256sum hermes-mobile-i18n-fixes-demo-arm64.apk > hermes-mobile-i18n-fixes-demo-arm64.sha256 )

echo "== 交付完毕"
ls -la "$OUT_DIR"

# 交付目录里放一份给用户看的中文说明（每次发版重写，避免过期）
cat > "$OUT_DIR/README-zh.md" <<EOF
# Hermes 手机客户端 · 当前交付包（${VER}+${CODE}）

| 文件 | 用途 |
|---|---|
| \`hermes-mobile-${VER}-${CODE}-arm64.apk\` | **装这个**（覆盖安装，登录态/会话保留） |
| \`hermes-mobile-${VER}-${CODE}-arm64-demo.apk\` | 离线演示包：不连服务器，打开就是内置假数据（看完装回上面那个） |
| \`*.json\` | 同名清单：版本号/versionCode/ABI/sha256/签名证书/git commit/构建时间 |
| \`SHA256SUMS\` | 校验总表（\`sha256sum -c SHA256SUMS\`） |

版本 **${VER} + code ${CODE}**（code 递增才能顺利覆盖安装）｜包名 \`ai.ailigent.hermes_mobile\`
｜签名 \`CN=Android Debug\`（与历史包同一张证书，可直接覆盖）

改了什么见 \`../FIXES-20261016-zh.md\` 与仓库里的 \`CHANGELOG.md\`。
手机访问：\`\\\\192.168.1.50\\share\\apk\\hermes-mobile\\\`（Tailscale 外网：\`\\\\100.93.152.114\\share\\...\`）
EOF

echo "== 旧路径（兼容）"
ls -la "$HOME/share/apk"/hermes-mobile-i18n-fixes-*.apk
