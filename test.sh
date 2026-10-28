#!/bin/bash
# 自动化测试：编译 → 指标/逻辑自检 → 界面交互测试 → 离屏截图（需人工/助手查看）
set -uo pipefail
cd "$(dirname "$0")"
[ "${1:-}" = "--approve" ] && APPROVE=--approve
OUT="$PWD/build-test"; rm -rf "$OUT"; mkdir -p "$OUT"
# 避免与正在运行的实例抢菜单栏/辅助功能树
osascript -e 'quit app "Mac一键优化"' >/dev/null 2>&1 || true
for i in $(seq 1 20); do pgrep -x MacOptimizer >/dev/null || break; sleep 0.3; done
./build.sh > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo "❌ 编译失败"; exit 1; }
BIN="$PWD/build/Mac一键优化.app/Contents/MacOS/MacOptimizer"
"$BIN" --selftest > "$OUT/selftest.log" 2>&1; S=$?
"$BIN" --uitest "$OUT/ui" > "$OUT/uitest.log" 2>&1; U=$?
"$BIN" --snapshot "$OUT/shots" --goldens "$PWD/goldens" ${APPROVE:-} > "$OUT/snapshot.log" 2>&1; P=$?
grep -E "✗" "$OUT"/*.log
for f in selftest uitest snapshot; do tail -1 "$OUT/$f.log"; done | tee "$OUT/summary.txt"
for f in panel panel-dark dashboard battery overview dashboard-default-dark battery-default-dark charge-light charge-dark charge-paused-light charge-paused-dark display-light display-dark network-light network-dark bt-light bt-dark; do [ -s "$OUT/shots/$f.png" ] || { echo "缺少截图 $f.png"; P=1; }; done
if [ $S -eq 0 ] && [ $U -eq 0 ] && [ $P -eq 0 ]; then echo "✅ 全部测试通过（截图在 $OUT/shots，发布前请查看）"; else echo "❌ 测试失败"; exit 1; fi
