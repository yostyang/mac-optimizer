# v2.17.1 发布验证记录

- 发布提交：`1b0d66d v2.17.1`，Release 建在版本提交 SHA
- 时间：2026-11-18
- 版本：2.17.1（45）

## 功能内容
- Keychron 自报电量陈旧检测（K02）：按报告里的蓝牙地址持久化记录「当前自报值最早出现时间 + 是否曾更新过」。
  从未更新过的通道同一值超过 24 小时、曾更新过的通道超过 7 天，判定固件不再推送，降级为「未取得」并提示按 Fn+B 查看，不再显示假值
- 定性结论：K3 Pro（K3P-H3，CKBT51 模块，固件 1.3.2）HID 3 号报告为死值——放电到约 70% 仍报 100%，
  重连/充电/Fn+B/30 分钟以上轮询均不变；特性报告 0xe00002c7 不支持、无 BLE 广播、IORegistry 无电量字段、
  USB raw-HID 仅 VIA（协议 9）与工厂测试命令（0xA4 回 id_unhandled，0xAB 0x06 只回充电脚状态），无电量查询
- 排查入口保留：`--dump-keychron-hid` / `--watch-keychron` / `--ble-keychron` / `--probe-keychron-raw`
- 详情页脚注更新：说明自报值长期不变会降级、K3 Pro 建议按 Fn+B

## 测试结果（release.sh 内完整流程）
| 项 | 结果 |
|---|---|
| fontlint | 2 通过，0 失败 |
| statelint | 1 通过，0 失败 |
| selftest | 1092 通过，0 失败（新增 6 项陈旧检测断言） |
| uitest | 207 通过，0 失败 |
| snapshot | 175 通过，0 失败 |
| contrast | 72 通过，0 失败，0 未验收 |

## 产物
- DMG：`Mac-Optimizer-2.17.1.dmg` + `.dmg.sha256`
- SHA-256：`4d9106ef8dd67daa984f8e2ec0523e9eb295bb77b6a05c2af861b15c298889a8`（发布脚本已从 GitHub 下载回读校验一致）
- Release：https://github.com/yostyang/mac-optimizer/releases/tag/v2.17.1

## 充电助手
- 源码未变，复用已签名助手 `7fa85c04f483b64d`
- CDHash `8fdf5fd47a67df1aaab355d5ebeaa74184882a94` 与已授权版本一致，升级保留授权

## 本机升级
- 2.17.0 → 2.17.1（45），常亮断言恢复
- `keychron.seen` 已按最早观测时间（当天 16:49）记账；K3 Pro 在 24 小时未更新窗口后自动显示「未取得」+ Fn+B 提示

## 发布过程中的环境问题（非代码问题，供记录）
- `displaysleep=2` 分钟：测试期间 App 退出后常亮断言消失，无输入 2 分钟即息屏并立即锁屏，导致「测试窗口就绪」检查数次失败
- 解锁后持 `caffeinate -d`（PreventUserIdleDisplaySleep）跑完整流程一次全绿
- 已锁的会话无法被断言解开：loginwindow 锁屏界面有自己更短的息屏计时，唤醒后约 30–90 秒再次息屏
