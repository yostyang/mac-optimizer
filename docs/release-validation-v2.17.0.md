# v2.17.0 发布验证记录

- 发布提交：版本提交在 `main` 上，Release 建在版本提交 SHA
- 时间：2026-11-17
- 版本：2.17.0（44）

## 功能内容
- 菜单栏面板新增输出设备菜单与输入行（麦克风静音 + 输入设备菜单），CoreAudio 事件实时刷新
- 设置页快捷键四槽位：命令面板（默认 ⌥Space）+ 麦克风静音 + 输出/输入轮换，统一 HotKeyCenter 注册分发，失败提示
- 修复 `--selftest` 中 BatteryAlerts 测试实例写 UserDefaults.standard、清除用户 battery.settings 的问题（注入存储 + 回归断言）
- 界面测试不再依赖用户存量的 menuIndicator（检查前显式设为 cpu）
- 设置页改 PageScaffold（摘要不滚动、详情局部滚动）；热键键位文字补全字母/数字/F 键映射

## 测试结果（release.sh 内完整流程）
| 项 | 结果 |
|---|---|
| fontlint | 2 通过，0 失败 |
| statelint | 1 通过，0 失败 |
| selftest | 1085 通过，0 失败 |
| uitest | 207 通过，0 失败 |
| snapshot | 175 通过，0 失败 |
| contrast | 72 通过，0 失败，0 未验收 |

## 产物
- DMG：`Mac-Optimizer-2.17.0.dmg`（6.59 MB）+ `.dmg.sha256`
- SHA-256：`5c9952e5028888c70d0df3e00115707be879acaf9170169f42475e04bc0fe5d7`（发布脚本已从 GitHub 下载回读校验一致）
- Release：https://github.com/yostyang/mac-optimizer/releases/tag/v2.17.0

## 充电助手
- 源码未变，复用已签名助手 `7fa85c04f483b64d`
- CDHash `8fdf5fd47a67df1aaab355d5ebeaa74184882a94` 与已授权版本一致，升级保留授权

## 本机升级
- 2.16.1 → 2.17.0（44），常亮与接显示器模式断言均恢复
- 真机确认：面板输出/输入设备菜单可见可切换，快捷键录制有 HUD 提示

## 过程中的测试修复（已提交）
- `329211f` 界面测试不依赖用户存量的 menuIndicator（发布中第一轮 uitest 因此失败一次，修复后全绿）
- `f299a5c` BatteryAlerts 注入存储，自检不再清用户电池设置
