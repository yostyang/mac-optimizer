# 2.16.1 发布与本机升级验证

日期：2026-11-16（Asia/Shanghai）。版本 **2.16.1（43）**。

- 发布代码：`5a71d0c`，版本提交由新版 `release.sh` 推送（分离 HEAD 下 `HEAD:main`，显式目标验证通过）。
- 正式发布：[v2.16.1](https://github.com/yostyang/mac-optimizer/releases/tag/v2.16.1)，含 `Mac-Optimizer-2.16.1.dmg` 与 `.dmg.sha256`。
- DMG SHA-256：`b7bed0591ebb2f7b978d29922ebc62720ed64a5697579a4c3c1adb6c09e028d9`（发布脚本已从 GitHub 下载回读校验一致）。

## 内容

工程收尾，无用户可见新功能：CI 加入 `--selftest-ci` 自检子集（runner 实测 1032/0）；`release.sh` 推送目标显式化；U1–U22 界面优化清单再评估归档（22 项全部交付）。

## 最终验证

`./test.sh` 在 release.sh 流程内完整执行（本机、解锁状态）：

- 自检：**1063 通过、0 失败**；其中 `--selftest-ci` 子集本机 1032/0。
- 界面交互：**205 通过、0 失败**。
- 截图：**175 通过、0 失败**，对比度 **72 通过、0 失败、0 未验收**；黄金图未重拍。
- 字号检查 2、页面状态检查 1，均 0 失败。
- 隔离逻辑回归 47、发布回滚 5 项通过（safety-tests.sh，CI 同步执行）。
- [CI](https://github.com/yostyang/mac-optimizer/actions) main 分支连续绿。

## 本机升级

- 由 2.16.0（42）升级到 2.16.1（43），安装后进程正常启动。
- 充电助手 CDHash 未变（`8fdf5fd47a67df1aaab355d5ebeaa74184882a94`），升级保留授权，助手已随新版本重启。
- 常亮与接显示器模式断言在测试结束后已自动恢复。
