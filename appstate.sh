# 测试/安装前记录用户正在运行的 Mac一键优化 的「常亮」与「接显示器模式」，结束后重新打开并核对（只正常退出，不强制）
MO_APP="/Applications/Mac一键优化.app"
# install-local.sh 用 set -euo pipefail：没有运行实例时 pgrep 返回 1，
# pipefail 会让整个管道失败并静默终止脚本，因此用 || true 把「查不到」变成正常的空结果。
mo_pid() { pgrep -x MacOptimizer 2>/dev/null | head -1 || true; }
mo_has() { pmset -g assertions | grep -E "pid $1\(MacOptimizer\)" | grep -q "$2"; }
mo_record() {
  MO_WAS_RUNNING=0; MO_AWAKE=0; MO_DOCK=0
  local P; P=$(mo_pid); [ -z "$P" ] && { echo "退出前：Mac一键优化未运行"; return 0; }
  MO_WAS_RUNNING=1
  mo_has "$P" PreventUserIdleDisplaySleep && MO_AWAKE=1
  mo_has "$P" PreventUserIdleSystemSleep && MO_DOCK=1
  # 2.4 及以前不保存常亮状态：按退出前实际状态写入，2.4.1 起启动时据此恢复
  [ "$MO_AWAKE" = 1 ] && defaults write com.yost.macoptimizer keepAwake.enabled -bool true
  echo "退出前：常亮=${MO_AWAKE} 接显示器模式断言=${MO_DOCK}（pid ${P}）"
}
mo_verify() {
  [ "${MO_WAS_RUNNING:-0}" = 1 ] || return 0
  local P ok i
  for i in $(seq 1 30); do
    P=$(mo_pid)
    if [ -n "$P" ]; then
      ok=1
      [ "$MO_AWAKE" = 1 ] && ! mo_has "$P" PreventUserIdleDisplaySleep && ok=0
      [ "$MO_DOCK" = 1 ] && ! mo_has "$P" PreventUserIdleSystemSleep && ok=0
      [ $ok = 1 ] && { echo "✅ 已恢复：常亮=${MO_AWAKE} 接显示器模式=${MO_DOCK}（pid ${P}）"; return 0; }
    fi
    sleep 1
  done
  echo "❌ 重新打开后没有恢复原状态（常亮应为 ${MO_AWAKE}，接显示器模式应为 ${MO_DOCK}）"
  pmset -g assertions | grep MacOptimizer
  return 1
}
mo_relaunch() { [ "${MO_WAS_RUNNING:-0}" = 1 ] || return 0; pgrep -x MacOptimizer >/dev/null || open -g "$MO_APP" --args --background; mo_verify; }
