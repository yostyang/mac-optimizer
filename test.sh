#!/bin/bash
# 自动化测试：编译 → 指标/逻辑自检 → 界面交互测试 → 离屏截图（需人工/助手查看）
set -uo pipefail
cd "$(dirname "$0")"
[ "${1:-}" = "--approve" ] && APPROVE=--approve
OUT="$PWD/build-test"; rm -rf "$OUT"; mkdir -p "$OUT"
# 避免与正在运行的实例抢菜单栏/辅助功能树；先记下常亮/接显示器模式，测完重新打开并核对
. ./appstate.sh; mo_record
# quit 偶尔会被系统弹窗/权限挡住并一直挂着，限 5 秒后走 TERM 兜底
osascript -e 'quit app "Mac一键优化"' >/dev/null 2>&1 &
Q=$!
for i in $(seq 1 20); do kill -0 "$Q" 2>/dev/null || break; sleep 0.25; done
if kill -0 "$Q" 2>/dev/null; then kill -TERM "$Q" 2>/dev/null || true; fi
wait "$Q" 2>/dev/null || true
for i in $(seq 1 20); do pgrep -x MacOptimizer >/dev/null || break; sleep 0.3; done
# osascript 在部分系统上会返回 -10004（权限）却没退出；残留实例会抢走前台，导致辅助功能树缺失、界面测试大面积误报
if pgrep -x MacOptimizer >/dev/null; then
  pkill -TERM -x MacOptimizer 2>/dev/null || true
  for i in $(seq 1 15); do pgrep -x MacOptimizer >/dev/null || break; sleep 0.2; done
fi
./build.sh > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo "❌ 编译失败"; mo_relaunch; exit 1; }
BIN="$PWD/build/Mac一键优化.app/Contents/MacOS/MacOptimizer"
"$BIN" --selftest > "$OUT/selftest.log" 2>&1; S=$?
"$BIN" --uitest "$OUT/ui" > "$OUT/uitest.log" 2>&1; U=$?
"$BIN" --snapshot "$OUT/shots" --goldens "$PWD/goldens" ${APPROVE:-} > "$OUT/snapshot.log" 2>&1; P=$?
grep -E "✗" "$OUT"/*.log
for f in selftest uitest snapshot; do tail -1 "$OUT/$f.log"; done | tee "$OUT/summary.txt"
for f in panel panel-dark dashboard battery overview dashboard-default-dark battery-default-dark charge-light charge-dark charge-paused-light charge-paused-dark display-light display-dark network-light network-dark bt-light bt-dark verdict-light verdict-dark verdict-smooth-light dock-light dock-dark clean-light clean-dark changes-light changes-dark power-paused-light power-paused-dark display-color-min-light display-color-min-dark power-charging-light power-charging-dark speed24-light speed24-dark traffic24-light traffic24-dark uninstall24-light uninstall24-dark apptraffic24-light apptraffic24-dark tiles24-light tiles24-dark tools25-light tools25-dark settings25-light settings25-dark search25-light search25-dark; do [ -s "$OUT/shots/$f.png" ] || { echo "缺少截图 $f.png"; P=1; }; done
[ "${MO_NO_RELAUNCH:-}" = 1 ] || mo_relaunch || P=1
if [ $S -eq 0 ] && [ $U -eq 0 ] && [ $P -eq 0 ]; then echo "✅ 全部测试通过（截图在 $OUT/shots，发布前请查看）"; else echo "❌ 测试失败"; exit 1; fi
