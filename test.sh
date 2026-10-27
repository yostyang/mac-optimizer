#!/bin/bash
# 自动化测试：编译 → 指标/逻辑自检 → 界面交互测试 → 离屏截图（需人工/助手查看）
set -uo pipefail
cd "$(dirname "$0")"
OUT="$PWD/build-test"; rm -rf "$OUT"; mkdir -p "$OUT"
./build.sh > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo "❌ 编译失败"; exit 1; }
BIN="$PWD/build/Mac一键优化.app/Contents/MacOS/MacOptimizer"
"$BIN" --selftest > "$OUT/selftest.log" 2>&1; S=$?
"$BIN" --uitest "$OUT/ui" > "$OUT/uitest.log" 2>&1; U=$?
"$BIN" --snapshot "$OUT/shots" > "$OUT/snapshot.log" 2>&1; P=$?
grep -E "✗" "$OUT"/*.log
for f in selftest uitest snapshot; do tail -1 "$OUT/$f.log"; done | tee "$OUT/summary.txt"
for f in panel dashboard battery overview; do [ -s "$OUT/shots/$f.png" ] || { echo "缺少截图 $f.png"; P=1; }; done
if [ $S -eq 0 ] && [ $U -eq 0 ] && [ $P -eq 0 ]; then echo "✅ 全部测试通过（截图在 $OUT/shots，发布前请查看）"; else echo "❌ 测试失败"; exit 1; fi
