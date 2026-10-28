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
# 原地同步（包路径始终存在，每个文件原子替换），避免助手在空档期被 launchd 判为配置错误
if [ -d "/Applications/Mac一键优化.app" ]; then rsync -a --delete --delay-updates "build/Mac一键优化.app/" "/Applications/Mac一键优化.app/"; else cp -R "build/Mac一键优化.app" /Applications/; fi
open "/Applications/Mac一键优化.app"
sleep 5; pgrep -x MacOptimizer >/dev/null || { echo "安装后没有启动"; exit 1; }
# 新版本 App 启动时会自己重新注册充电助手（与用户升级同一路径），这里只等待并确认
if [ -n "$(defaults read com.yost.macoptimizer chargeHelperBuild 2>/dev/null)" ]; then   # 之前装过助手
  for n in $(seq 1 45); do sleep 2; [ "$(defaults read com.yost.macoptimizer chargeHelperBuild 2>/dev/null)" = "$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)" ] && "/Applications/Mac一键优化.app/Contents/MacOS/MacOptimizer" --charge status >/dev/null 2>&1 && break; done
  pgrep -f MacOptimizerChargeHelper >/dev/null && echo "充电助手已随新版本重启" || { echo "⚠️ 充电助手没有启动（可能需要在 系统设置 › 登录项与扩展 里重新允许）"; exit 1; }
fi
echo "✅ 已在本机安装 ${V}（未发布）"
