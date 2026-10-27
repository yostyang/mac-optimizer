#!/bin/bash
# 测量菜单栏常驻（空闲）与面板打开时的 CPU / 内存
APP="${1:-build/Mac一键优化.app}"; BIN="$APP/Contents/MacOS/MacOptimizer"
m() { # $1 = 参数, $2 = 秒
  "$BIN" $1 >/dev/null 2>&1 & P=$!; sleep 15
  t0=$(ps -o cputime= -p $P); sleep $2; t1=$(ps -o cputime= -p $P); rss=$(ps -o rss= -p $P)
  kill -TERM $P; wait $P 2>/dev/null
  python3 -c "
def s(t):
  p=t.strip().split(':'); return float(p[-1])+60*float(p[-2])+(3600*float(p[-3]) if len(p)>2 else 0)
print('$3: CPU %.3f%% (%.2fs/%ds)  RSS %.1f MB' % ((s('$t1')-s('$t0'))/$2*100, s('$t1')-s('$t0'), $2, $rss/1024))"
}
m "--background" ${2:-60} "菜单栏常驻（面板关闭）"
m "--background --open-panel" ${2:-60} "面板打开"
