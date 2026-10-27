#!/bin/bash
# 发布：必须先通过 test.sh，然后改版本号、重新编译签名、安装、打包、提交、推送、建 GitHub Release
# 用法：./release.sh 1.3 "发布说明"
set -euo pipefail
cd "$(dirname "$0")"
V="$1"; NOTES="${2:-}"
[[ "$V" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "版本号格式不对：$V"; exit 1; }
B=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" -c "Set :CFBundleVersion $B" Info.plist
./test.sh || { echo "❌ 测试没通过，停止发布"; git checkout Info.plist; exit 1; }
osascript -e 'quit app "Mac一键优化"' || true
for i in $(seq 1 20); do pgrep -x MacOptimizer >/dev/null || break; sleep 0.5; done
pgrep -x MacOptimizer >/dev/null && { echo "Mac一键优化没有正常退出，停止发布"; exit 1; }
rm -rf "/Applications/Mac一键优化.app" && cp -R "build/Mac一键优化.app" /Applications/ && open "/Applications/Mac一键优化.app"
cp "build/Mac一键优化.dmg" "/tmp/Mac-Optimizer-$V.dmg"
sleep 5; pgrep -x MacOptimizer >/dev/null || { echo "安装后没有启动"; exit 1; }
git add -A && git commit -qm "v$V" && git push -q
SUMMARY=$(cat build-test/summary.txt)
~/.local/bin/gh release create "v$V" "/tmp/Mac-Optimizer-$V.dmg" --repo yostyang/mac-optimizer --title "Mac一键优化 $V" --notes "$NOTES

---
自动化测试（发布前通过）：
$SUMMARY"
H1=$(shasum -a 256 "/tmp/Mac-Optimizer-$V.dmg" | cut -d' ' -f1)
H2=$(curl -sL "https://github.com/yostyang/mac-optimizer/releases/download/v$V/Mac-Optimizer-$V.dmg" | shasum -a 256 | cut -d' ' -f1)
[ "$H1" = "$H2" ] && echo "✅ 发布完成，下载校验一致 $H1" || { echo "下载校验不一致"; exit 1; }
