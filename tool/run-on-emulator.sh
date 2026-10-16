#!/usr/bin/env bash
# 起模拟器 + 装 + 起 App（在模拟器里验收用）。默认装最新的 arm64 包对应的 x64 构建？
# —— 不：模拟器是 x86_64，必须用 x64 包。所以这里默认先构建 x64 包再装。
#
# 用法: tool/run-on-emulator.sh [--keep] [--abi x64] [--no-build]
#   --keep     跑完不关模拟器（自己接着 adb 玩）
#   --no-build 直接用 dist/ 里已有的包
#
# ★ 三条血泪（2026-10-16 实测）：
#   1) 必须 `-gpu swiftshader`：宿主侧软件光栅在 Impeller 负载下会让模拟器进程 SIGSEGV/SIGILL
#   2) App 侧必须在 AndroidManifest.xml 里关 Impeller（`am start --ez enable-impeller false` 在 release 包无效）
#   3) 装完必须 sleep 20 再启动：包替换会让正在启动的 App 撞 "FlutterJNI is not attached to native"
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ABI=x64; KEEP=0; BUILD=1
while [ $# -gt 0 ]; do case "$1" in
  --keep) KEEP=1; shift ;; --no-build) BUILD=0; shift ;; --abi) ABI="$2"; shift 2 ;;
  *) echo "未知参数: $1" >&2; exit 2 ;; esac; done

export JAVA_HOME="${JAVA_HOME:-$HOME/tools/jdk17}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/tools/android-sdk}"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_AVD_HOME="$HOME/.android/avd"
export TMPDIR="$HOME/tmp"
export PATH="$HOME/tools/flutter/bin:$JAVA_HOME/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH"

AVD="${AVD:-hermes35}"
PKG=ai.ailigent.hermes_mobile
SCREEN="${SCREEN:-720x1280}"

VER="$(python3 -c "import re;print(re.search(r'^version:\s*([^+]+)',open('pubspec.yaml').read(),re.M).group(1).strip())")"
CODE="$(python3 -c "import re;print(re.search(r'^version:.*\+(\d+)',open('pubspec.yaml').read(),re.M).group(1).strip())")"
APK="dist/hermes-mobile-${VER}-${CODE}-${ABI}-demo.apk"

if [ "$BUILD" = "1" ]; then
  bash tool/build-apk.sh --abi "$ABI" --demo --no-copy
fi
[ -f "$APK" ] || { echo "!! 找不到 $APK（先跑 tool/build-apk.sh --abi $ABI --demo）" >&2; exit 3; }

mkdir -p "$TMPDIR/emu-run"
( cd "$TMPDIR/emu-run" && ulimit -c unlimited && \
  sg kvm -c "ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT ANDROID_HOME=$ANDROID_HOME ANDROID_AVD_HOME=$ANDROID_AVD_HOME \
    $ANDROID_SDK_ROOT/emulator/emulator -avd $AVD -no-window -no-audio -no-snapshot -no-boot-anim \
    -gpu swiftshader -accel on -memory 2560 -cores 2 -skin $SCREEN -crash-report-mode disabled" \
    > emulator.log 2>&1 & )

adb wait-for-device
for i in $(seq 1 60); do
  [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
  sleep 4
done
echo "== 模拟器已启动（屏幕 $SCREEN，日志 $TMPDIR/emu-run/emulator.log）"
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0

adb install -r "$APK" | tail -1
echo "== 等 20s（避免包替换/启动竞态：FlutterJNI is not attached）"
sleep 20
adb shell am start -n "$PKG/.MainActivity" | tail -1
sleep 8
echo "== App pid=$(adb shell pidof $PKG | tr -d '\r')  屏幕: adb exec-out screencap -p > shot.png"
echo "== 读界面/点按: python3 tool/drive.py texts | tap <文字> | long <文字> | swipe up|down"

if [ "$KEEP" = "0" ]; then
  read -r -p "回车关闭模拟器（或 Ctrl-C 保留）… " _ || true
  adb emu kill >/dev/null 2>&1 || true
fi
