#!/bin/bash
# 发布：必须先通过 test.sh，然后改版本号、重新编译签名、安装、打包、提交、推送、建 GitHub Release
# 用法：./release.sh 2.15.0 "发布说明"
# 只提交 Info.plist 版本号；其余改动应当已经随 PR 合并进当前分支
set -euo pipefail
cd "$(dirname "$0")"
V="${1:-}"; NOTES="${2:-}"
[[ "$V" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "版本号格式不对：$V"; exit 1; }
GH="$(command -v gh || true)"; [ -x "$GH" ] || GH="$HOME/.local/bin/gh"
[ -x "$GH" ] || { echo "找不到 gh（PATH 和 ~/.local/bin/gh 都没有）"; exit 1; }
# 除 Info.plist 外，已跟踪文件必须是干净的：历史上有用 git add -A 把无关文件一起提交的问题
DIRTY=$(git status --porcelain --untracked-files=no | grep -v ' Info\.plist$' || true)
[ -z "$DIRTY" ] || { echo "工作区还有 Info.plist 之外的改动，请先提交或清理："; echo "$DIRTY"; exit 1; }
B=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
# 版本号写入后，提交成功前任一步失败都恢复原值
VERSION_BACKUP=$(mktemp)
cp Info.plist "$VERSION_BACKUP" || { rm -f "$VERSION_BACKUP"; exit 1; }
COMMITTED=0
cleanup() {
  local status=$?
  trap - EXIT
  if [ "$COMMITTED" = 0 ]; then
    cp "$VERSION_BACKUP" Info.plist || { echo "恢复版本文件失败，原文件保存在 $VERSION_BACKUP"; exit 1; }
  fi
  rm -f "$VERSION_BACKUP"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" -c "Set :CFBundleVersion $B" Info.plist
./test.sh || { echo "❌ 测试没通过，停止发布"; exit 1; }
# test.sh 验证的是带测试代码的包；发布前重新出发布包（不含测试入口与替换口），再核对助手与安装
./build.sh
osascript -e 'quit app "Mac一键优化"' || true
for i in $(seq 1 20); do pgrep -x MacOptimizer >/dev/null || break; sleep 0.5; done
pgrep -x MacOptimizer >/dev/null && { echo "Mac一键优化没有正常退出，停止发布"; exit 1; }
# 发布包里的助手必须和本机已授权的是同一份（cdhash 相同），否则用户升级要重新允许
cdh() { codesign -dvvv "$1" 2>&1 | grep CDHash= ; }
NEWH=$(cdh "build/Mac一键优化.app/Contents/MacOS/MacOptimizerChargeHelper"); OLDH=$(cdh "/Applications/Mac一键优化.app/Contents/MacOS/MacOptimizerChargeHelper" || true)
[ "$NEWH" = "$OLDH" ] && echo "充电助手未变（${NEWH}）：升级保留授权" || echo "⚠️ 充电助手有变化（${OLDH} → $NEWH）：用户升级后需重新允许一次"
if [ -d "/Applications/Mac一键优化.app" ]; then rsync -a --delete --delay-updates "build/Mac一键优化.app/" "/Applications/Mac一键优化.app/"; else cp -R "build/Mac一键优化.app" /Applications/; fi
open "/Applications/Mac一键优化.app"
cp "build/Mac一键优化.dmg" "/tmp/Mac-Optimizer-$V.dmg"
sleep 5; pgrep -x MacOptimizer >/dev/null || { echo "安装后没有启动"; exit 1; }
# 升级路径：新版本 App 启动时自己重新注册充电助手，这里确认它已重启
if [ -n "$(defaults read com.yost.macoptimizer chargeHelperBuild 2>/dev/null)" ]; then
  for n in $(seq 1 45); do sleep 2; [ "$(defaults read com.yost.macoptimizer chargeHelperBuild 2>/dev/null)" = "$B" ] && "/Applications/Mac一键优化.app/Contents/MacOS/MacOptimizer" --charge status >/dev/null 2>&1 && break; done
  [ "$(defaults read com.yost.macoptimizer chargeHelperBuild 2>/dev/null)" = "$B" ] && echo "充电助手已随新版本重启" || { echo "⚠️ 充电助手没有随新版本重启，停止发布"; exit 1; }
fi
git commit -qm "v$V" -- Info.plist
COMMITTED=1
git push -q origin HEAD
SHA=$(git rev-parse HEAD)
SUMMARY=$(cat build-test/summary.txt)
"$GH" release create "v$V" "/tmp/Mac-Optimizer-$V.dmg" --repo yostyang/mac-optimizer --title "Mac一键优化 $V" --target "$SHA" --notes "$NOTES

---
自动化测试（发布前通过）：
$SUMMARY"
H1=$(shasum -a 256 "/tmp/Mac-Optimizer-$V.dmg" | cut -d' ' -f1)
H2=$(curl -sL "https://github.com/yostyang/mac-optimizer/releases/download/v$V/Mac-Optimizer-$V.dmg" | shasum -a 256 | cut -d' ' -f1)
[ "$H1" = "$H2" ] && echo "✅ 发布完成，下载校验一致 $H1" || { echo "下载校验不一致"; exit 1; }
