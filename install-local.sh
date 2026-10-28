#!/bin/bash
# 本机安装（不提交、不发布）：先通过 test.sh，再正常退出旧版、替换、重新打开
# 用法：./install-local.sh 1.4
set -euo pipefail
cd "$(dirname "$0")"
V="$1"
[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)" = "$V" ] || {
  B=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" -c "Set :CFBundleVersion $B" Info.plist; }
./test.sh || { echo "❌ 测试没通过，不安装"; exit 1; }
osascript -e 'quit app "Mac一键优化"' || true
for i in $(seq 1 20); do pgrep -x MacOptimizer >/dev/null || break; sleep 0.5; done
pgrep -x MacOptimizer >/dev/null && { echo "Mac一键优化没有正常退出，停止安装"; exit 1; }
rm -rf "/Applications/Mac一键优化.app" && cp -R "build/Mac一键优化.app" /Applications/ && open "/Applications/Mac一键优化.app"
sleep 5; pgrep -x MacOptimizer >/dev/null || { echo "安装后没有启动"; exit 1; }
# 新版本 App 启动时会自己重新注册充电助手（与用户升级同一路径），这里只等待并确认
if launchctl print system/com.yost.macoptimizer.chargehelper >/dev/null 2>&1; then
  for n in $(seq 1 45); do sleep 2; [ "$(defaults read com.yost.macoptimizer chargeHelperBuild 2>/dev/null)" = "$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)" ] && "/Applications/Mac一键优化.app/Contents/MacOS/MacOptimizer" --charge status >/dev/null 2>&1 && break; done
  pgrep -f MacOptimizerChargeHelper >/dev/null && echo "充电助手已随新版本重启" || { echo "⚠️ 充电助手没有启动"; exit 1; }
fi
echo "✅ 已在本机安装 ${V}（未发布）"
