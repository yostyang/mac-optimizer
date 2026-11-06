#!/bin/bash
# 真机测量：15 秒预热，再测 CPU 时间、RSS 均值/峰值；逐段核对面板可见性。
set -euo pipefail
cd "$(dirname "$0")"
APP="${1:-build/Mac一键优化.app}"; BIN="$APP/Contents/MacOS/MacOptimizer"
DURATION="${2:-60}"; MEASURE_MODE="${3:-all}"
case "$MEASURE_MODE" in all|panel|background) ;; *) echo "模式应为 all / panel / background"; exit 2 ;; esac
[[ "$DURATION" =~ ^[0-9]+$ ]] && [ "$DURATION" -ge 5 ] || { echo "测量秒数必须 >= 5"; exit 2; }
[ -x "$BIN" ] || { echo "找不到可执行文件：$BIN"; exit 2; }
if pgrep -x MacOptimizer >/dev/null; then echo "请先记录状态并退出已有实例，避免双实例影响测量"; exit 2; fi
TMP=$(mktemp -d /private/tmp/mo-measure.XXXXXX)
OUT="${MO_MEASURE_OUT:-$TMP/results}"; mkdir -p "$OUT"
P=""
cleanup() {
  if [ -n "$P" ]; then kill -TERM "$P" 2>/dev/null || true; wait "$P" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
swiftc ${SWIFTFLAGS:-} MeasureWindows.swift -o "$TMP/windows"
m() {
  local mode="$1" label="$2" expected="$3"
  if [ "$mode" = panel ]; then "$BIN" --background --measure-hold-panel --open-panel > "$OUT/$mode-app.log" 2>&1 &
  else "$BIN" --background --measure-hold-panel > "$OUT/$mode-app.log" 2>&1 & fi
  P=$!
  sleep 15
  kill -0 "$P"
  # 同一 Python 进程内取起止时间，兼容旧 macOS Python 的进程相对 monotonic 时钟。
  python3 - "$OUT" "$mode" "$label" "$P" "$DURATION" "$TMP/windows" "$expected" <<'PY'
import pathlib,statistics,subprocess,sys,time
out,mode,label=pathlib.Path(sys.argv[1]),sys.argv[2],sys.argv[3]
pid,duration,probe,expected=sys.argv[4],int(sys.argv[5]),sys.argv[6],sys.argv[7]
def read_ps(column): return subprocess.check_output(['/bin/ps','-o',column+'=','-p',pid],text=True).strip()
def save(name,value): (out/f'{mode}-{name}.txt').write_text(str(value)+'\n')
def cpu(value): return sum(v*60**i for i,v in enumerate(reversed(list(map(float,value.split(':'))))))
def state():
    actual=subprocess.check_output([probe,pid],text=True).strip()
    if actual != expected: raise SystemExit(f'无效测量：{label} 期望 {expected}，实际 {actual}')
    return actual
state()
raw_start=read_ps('cputime'); start=time.monotonic()
save('cpu-start',raw_start); save('time-start',start)
rss=[]
with (out/f'{mode}-samples.txt').open('w') as samples:
    while time.monotonic()-start < duration:
        actual=state(); value=int(read_ps('rss'))
        rss.append(value/1024)
        samples.write(f'{time.monotonic()-start:.3f} {value} {actual}\n'); samples.flush()
        time.sleep(min(5,max(0,duration-(time.monotonic()-start))))
state()
raw_end=read_ps('cputime'); end=time.monotonic(); elapsed=end-start
save('cpu-end',raw_end); save('time-end',end)
end_rss=int(read_ps('rss')); save('rss-end',end_rss)
if not duration*.95 <= elapsed <= duration+5:
    raise SystemExit(f'无效测量：计时 {elapsed:.3f}s，与目标 {duration}s 不一致')
used=cpu(raw_end)-cpu(raw_start)
if used < 0: raise SystemExit('无效测量：CPU 时间倒退')
result=f'{label}: CPU {used/elapsed*100:.3f}% ({used:.2f}s/{elapsed:.2f}s) RSS 均值 {statistics.mean(rss):.1f} MiB / 峰值 {max(rss):.1f} MiB / 结束 {end_rss/1024:.1f} MiB；面板状态 {len(rss)+2} 次核对一致'
save('summary',result); print(result)
PY
  kill -TERM "$P"; wait "$P" 2>/dev/null || true; P=""
}
if [ "$MEASURE_MODE" != panel ]; then m background '菜单栏常驻（面板关闭）' panel-hidden; fi
if [ "$MEASURE_MODE" != background ]; then m panel '面板打开' panel-visible; fi
