#!/usr/bin/env bash
# 构建一个 APK 并**当场核验**，然后把产物 + 清单写进 dist/。
#
# 用法: tool/build-apk.sh [--abi arm64|x64] [--demo] [--no-copy]
#   默认: --abi arm64，正式包（不带 HERMES_DEMO）
#
# 这个脚本存在的理由（都是踩过的坑）：
#   ① 构建与模拟器必须串行（qemu 常驻 3GB，mem-guard 会杀 Gradle daemon）
#   ② 构建脚本必须 set -e：失败/被 kill 后继续 cp 会把上一次残留的包当成新产物交付
#   ③ 产物必须核验三件事：versionCode/versionName、ABI、sha256 —— 只信 sha256 不看版本号会翻车
set -euo pipefail

ABI=arm64
DEMO=""
COPY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --abi) ABI="$2"; shift 2 ;;
    --demo) DEMO=1; shift ;;
    --no-copy) COPY=0; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export JAVA_HOME="${JAVA_HOME:-$HOME/tools/jdk17}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/tools/android-sdk}"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export PATH="$HOME/tools/flutter/bin:$JAVA_HOME/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH"
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

# ① 模拟器还在跑就别构建
if pgrep -x qemu-system-x86_64 >/dev/null 2>&1 || pgrep -x qemu-system-x86_64-headless >/dev/null 2>&1; then
  echo "!! 模拟器还在运行：先停掉再构建（否则 mem-guard 会杀 Gradle daemon）" >&2
  exit 3
fi

VERSION_NAME="$(python3 -c "import re,sys;print(re.search(r'^version:\s*([^+]+)',open('pubspec.yaml').read(),re.M).group(1).strip())")"
VERSION_CODE="$(python3 -c "import re,sys;print(re.search(r'^version:.*\+(\d+)',open('pubspec.yaml').read(),re.M).group(1).strip())")"
TARGET="android-$ABI"
SUFFIX=""
DEFINES=()
[ -n "$DEMO" ] && { SUFFIX="-demo"; DEFINES=(--dart-define=HERMES_DEMO=true); }

echo "== 构建 hermes-mobile ${VERSION_NAME}+${VERSION_CODE} (${ABI}${SUFFIX:-})"
~/selfhosted/mem-guard/heavy flutter build apk --release --target-platform "$TARGET" "${DEFINES[@]}" 2>&1 | tail -2

SRC="build/app/outputs/flutter-apk/app-release.apk"
[ -f "$SRC" ] || { echo "!! 没有产物: $SRC" >&2; exit 4; }

OUT="dist/hermes-mobile-${VERSION_NAME}-${VERSION_CODE}-${ABI}${SUFFIX}.apk"
mkdir -p dist
cp "$SRC" "$OUT"

# ② 核验：版本号 / ABI / 签名 / sha256
python3 - "$OUT" "$VERSION_NAME" "$VERSION_CODE" "$ABI" "$ROOT" <<'PY'
import hashlib, json, os, re, subprocess, sys, zipfile, datetime
apk, want_name, want_code, want_abi, root = sys.argv[1:6]
sdk = os.environ.get("ANDROID_SDK_ROOT", os.path.expanduser("~/tools/android-sdk"))
bt = sorted(os.listdir(os.path.join(sdk, "build-tools")))[-1]
aapt2 = os.path.join(sdk, "build-tools", bt, "aapt2")
apksigner = os.path.join(sdk, "build-tools", bt, "apksigner")

badging = subprocess.run([aapt2, "dump", "badging", apk], capture_output=True, text=True).stdout
m = re.search(r"versionCode='(\d+)' versionName='([^']*)'", badging)
assert m, "badging 读不出 versionCode/versionName"
code, name = m.group(1), m.group(2)
assert code == want_code and name == want_name, f"版本不符: APK={name}+{code} pubspec={want_name}+{want_code}"

libs = [n for n in zipfile.ZipFile(apk).namelist() if "libflutter.so" in n]
assert libs and f"lib/{('arm64-v8a' if want_abi == 'arm64' else 'x86_64')}/libflutter.so" in libs, f"ABI 不符: {libs}"
cert = subprocess.run([apksigner, "verify", "--print-certs", apk], capture_output=True, text=True).stdout
digest = re.search(r"certificate SHA-256 digest: ([0-9a-f]+)", cert)
h = hashlib.sha256(open(apk, "rb").read()).hexdigest()
commit = subprocess.run(["git", "-C", root, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
dirty = bool(subprocess.run(["git", "-C", root, "status", "--porcelain"], capture_output=True, text=True).stdout.strip())
flutter = subprocess.run(["flutter", "--version"], capture_output=True, text=True).stdout.splitlines()[0]
man = {
    "file": os.path.basename(apk),
    "package": "ai.ailigent.hermes_mobile",
    "versionName": name,
    "versionCode": int(code),
    "abi": "arm64-v8a" if want_abi == "arm64" else "x86_64",
    "sha256": h,
    "size": os.path.getsize(apk),
    "signer_sha256": digest.group(1) if digest else None,
    "commit": commit,
    "worktree_dirty": dirty,
    "built_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "flutter": flutter,
}
p = os.path.join("dist", os.path.splitext(os.path.basename(apk))[0] + ".json")
json.dump(man, open(p, "w"), indent=2, ensure_ascii=False)
print("✓ 核验通过:", man["file"], f"{name}+{code}", man["abi"], h[:16], "->", p)
PY

if [ "$COPY" = "1" ] && [ -n "${DELIVER_DIR:-}" ]; then
  mkdir -p "$DELIVER_DIR"
  cp "$OUT" "$DELIVER_DIR/"
  cp "dist/$(basename "${OUT%.apk}").json" "$DELIVER_DIR/"
  echo "== 已投递到 $DELIVER_DIR"
fi
