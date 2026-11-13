#!/bin/bash
# 自动化测试：编译 → 指标/逻辑自检 → 界面交互测试 → 离屏截图（需人工/助手查看）
set -uo pipefail
cd "$(dirname "$0")"
APPROVE=""; REUSE=0
for arg in "$@"; do
  case "$arg" in
    --approve) APPROVE=--approve ;;
    --reuse-build) REUSE=1 ;;
    *) echo "用法：./test.sh [--approve] [--reuse-build]"; exit 2 ;;
  esac
done
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
reuse_ok() {
  [ "$REUSE" = 1 ] && [ -f build/source.sha256 ] && [ -f build/binaries.sha256 ] &&
    [ -f build/swiftflags.txt ] && [ "$(cat build/swiftflags.txt)" = "${SWIFTFLAGS:-}" ] &&
    shasum -a 256 -c build/source.sha256 >/dev/null 2>&1 &&
    shasum -a 256 -c build/binaries.sha256 >/dev/null 2>&1 &&
    codesign --verify --strict "build/Mac一键优化.app" >/dev/null 2>&1
}
if reuse_ok; then
  echo "复用已核对源码、参数、二进制和签名的测试包" | tee "$OUT/build.log"
else
  ./build.sh > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo "❌ 编译失败"; mo_relaunch; exit 1; }
fi
BIN="$PWD/build/Mac一键优化.app/Contents/MacOS/MacOptimizer"
"$BIN" --selftest > "$OUT/selftest.log" 2>&1; S=$?
# 2.13 门槛 A 的字号部分：说明文字 ≥ 12 pt（源码检查）
./fontlint.sh > "$OUT/fontlint.log" 2>&1 || S=1
# 2.14：页面状态统一用 StateLine（源码检查）
./statelint.sh > "$OUT/statelint.log" 2>&1 || S=1
{ echo "== uitest 前环境 $(date +%T)"; echo "残留 MacOptimizer: $(pgrep -lx MacOptimizer | tr '\n' ' ')"
  echo "前台: $(osascript -e 'tell application "System Events" to get {name, unix id} of first process whose frontmost is true' 2>&1)"
  ioreg -n Root -d1 | grep -o '"CGSSessionScreenIsLocked"=[A-Za-z]*' || echo "未锁屏"
  ioreg -c IOHIDSystem -d4 | awk '/HIDIdleTime/{print "空闲 " int($NF/1e9) "s";exit}'; } > "$OUT/env.log" 2>&1
# 通过 Launch Services 前台启动，避免直接 exec 的测试 App 被系统留在后台。
# open 的退出码不代表子 App 测试成功，因此必须同时核对完整测试汇总。
: > "$OUT/uitest.log"
/usr/bin/open -W -n -a "$PWD/build/Mac一键优化.app" --stdout "$OUT/uitest.log" --stderr "$OUT/uitest-stderr.log" --args --uitest "$OUT/ui"; U=$?
grep -q '^uitest: .*通过, 0 失败$' "$OUT/uitest.log" || U=1
echo "== uitest 后 $(date +%T) 前台: $(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>&1)" >> "$OUT/env.log"
"$BIN" --snapshot "$OUT/shots" --goldens "$PWD/goldens" ${APPROVE:-} > "$OUT/snapshot.log" 2>&1; P=$?
grep -E "✗" "$OUT"/*.log
for f in fontlint statelint selftest uitest snapshot; do tail -1 "$OUT/$f.log"; done | tee "$OUT/summary.txt"
for f in panel panel-dark dashboard battery overview dashboard-default-dark battery-default-dark charge-light charge-dark charge-paused-light charge-paused-dark charge-dock-light charge-dock-dark display-light display-dark network-light network-dark network-details-light network-details-dark bt-light bt-dark verdict-light verdict-dark verdict-smooth-light dock-light dock-dark clean-light clean-dark changes-light changes-dark power-paused-light power-paused-dark display-color-min-light display-color-min-dark power-charging-light power-charging-dark speed24-light speed24-dark traffic24-light traffic24-dark uninstall24-light uninstall24-dark apptraffic24-light apptraffic24-dark tiles24-light tiles24-dark tools25-light tools25-dark settings25-light settings25-dark search25-light search25-dark trend28-light trend28-dark states28-light states28-dark panel28-long-light panel28-long-dark panel213-short-light panel213-short-dark panel213-expanded-light panel213-expanded-dark clean214-long-light clean214-long-dark charge214-summary-light charge214-summary-dark; do [ -s "$OUT/shots/$f.png" ] || { echo "缺少截图 $f.png"; P=1; }; done
[ "${MO_NO_RELAUNCH:-}" = 1 ] || mo_relaunch || P=1
if [ $S -eq 0 ] && [ $U -eq 0 ] && [ $P -eq 0 ]; then echo "✅ 全部测试通过（截图在 $OUT/shots，发布前请查看）"; else echo "❌ 测试失败"; exit 1; fi
