# 2.15.1 发布与本机升级验证

日期：2026-11-14（Asia/Shanghai）。版本 **2.15.1（41）**。

- 修复合并：[PR #30](https://github.com/yostyang/mac-optimizer/pull/30)。
- 发布代码：`3900d49a8fca5ee090c2a7570b27b2a8f10d84e4`，代码树与通过测试的 `81879df` 一致。
- 正式发布：[v2.15.1](https://github.com/yostyang/mac-optimizer/releases/tag/v2.15.1)，设为最新版本。

## 修复范围

卸载路径边界与应用标识校验、白名单子目录保护、DNS 原值读取与备份、未完成 DNS 恢复的备份保留、普通日志文件扫描，以及发布失败后的版本回滚。扫描取消检查同步补齐。

## 最终验证

使用已核对源码、编译参数、二进制和签名的同一测试包执行：

```bash
SWIFTFLAGS=-disable-sandbox NODMG=1 ./test.sh --reuse-build
```

- 自检：**990 通过、0 失败**。
- 界面交互：**196 通过、0 失败**。
- 浅深色截图：**156 通过、0 失败**；4 张基准图差异均为 0.00%，未重拍基准图。
- 2 次指标卡对比度检查因离屏辅助功能树缺失而跳过；对应浅、深色截图已逐张查看。该部分不能记作自动对比度检查通过。
- 字号和页面状态检查各 1 通过、0 失败。
- 隔离逻辑回归 47 通过、0 失败，包含在完整自检内；独立发布回滚 5 通过、0 失败。
- [分支 CI](https://github.com/yostyang/mac-optimizer/actions/runs/43442978811) 与 [PR CI](https://github.com/yostyang/mac-optimizer/actions/runs/43443102751) 均成功。

最终测试在解锁状态执行；此前锁屏导致的前台窗口检查失败，不作为通过结果。

## 安装包与分发

- 正式主程序与后台助手均为 `arm64 + x86_64`，目标为 macOS 13。
- 固定证书签名及 `codesign --verify --strict` 通过；助手启用强化运行时。
- 发布配置不包含 `MOTests.selftest` 或 `SafetyCoreTests` 测试符号。
- DMG 完整性检查通过；只读挂载后，包内 `Contents` 与正式构建逐文件一致，`Applications` 链接正确。
- 文件：`Mac-Optimizer-2.15.1.dmg`，**6,393,218 字节**。
- SHA-256：`ef4a04d3ff0b1733b1d1ce3b7ed78e7146fb93784325a119e46533c30e201f35`。
- Release 同时提供 DMG 和 `.sha256` 文件，GitHub API 记录的 DMG digest 与本机哈希一致。

## 本机升级与助手授权

- 已从 2.15.0（40）更新到 2.15.1（41），本机 `Contents` 与正式构建逐文件一致。
- 本次助手代码变化，需要在系统「登录项与扩展」中重新允许既有后台项目。系统确认完成后，界面显示该项目已开启并正在运行。
- 重新打开 App 后，其真实助手核验流程将 `chargeHelperBuild` 更新为 **41**，XPC 状态读取正常。
- 助手 CDHash：`8fdf5fd47a67df1aaab355d5ebeaa74184882a94`。
- 升级前后 `ChargeSettings` 全字段相等，常亮状态已恢复。没有通过修改版本登记值来代替真实助手核验。

## 限制

应用继续使用本地固定签名，未经过 Apple 公证。此次没有重测常驻 CPU/RSS，也没有在 macOS 13/14 或 Intel 真机上运行；这些平台完成的是通用编译验证。
