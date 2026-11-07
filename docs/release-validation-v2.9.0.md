# Mac 一键优化 2.9.0 发布验证

发布日期：2026-11-07

Release：[v2.9.0](https://github.com/yostyang/mac-optimizer/releases/tag/v2.9.0)

## 发布基线

- 版本：2.9.0（28）
- 主程序：`arm64 + x86_64`
- 充电助手：`arm64 + x86_64`
- 主程序标识：`com.yost.macoptimizer`
- 充电助手标识：`com.yost.macoptimizer.chargehelper`

## 自动化与发布包检查

- 最终固定签名构建：selftest 640 / uitest 156 / snapshot 134，全部 0 失败。
- 已目检浅色、深色和最小窗口的电池详情、功率页“未取得”、充电中与显示器色彩页；没有截断、错位或把缺失读数写成 0。
- DMG：`hdiutil verify` 通过。
- 只读挂载后，主程序、充电助手与 `Info.plist` 同构建产物逐字节一致。
- 包内自检：640 通过，0 失败。

## 真机硬件检查

Kuycon P40W 通过 DDC 身份匹配。

- `0x14` 色彩预设：9300 K、用户预设 1、用户预设 2 均写入成功并通过回读；随后恢复 6500 K。
- `0xDC` 显示模式：影片 `0x03`、游戏 `0x05` 均写入成功并通过回读；随后恢复标准 `0x00`。
- 混合模式 `0x02`：显示器能力字符串声明支持，但连续写入后回读仍为标准 `0x00`。候选包显示“可能不兼容”、保留实际值和重试入口，没有误报成功。

电池完成接电未充电、正在充电、拔电和重新接电状态核对。正在充电时读到约 65.9 W 实时输入、43.5 W 充入电池和 22.4 W 系统功耗估算，界面状态与计算关系一致。拔电时控制器短暂返回 0 A，应用显示“未取得”，没有误称“未放电”。

Keychron K3 Pro 当前仍无法取得有效经典蓝牙电量，界面保持「未取得」，不把 0 当作百分比。

## 签名与分发

App 与充电助手仍使用固定本地证书 `FileButler Local Signing`，签名标识和 CDHash 与包内文件一致：

```text
App:    fadd238523229e89dd8175a08e80312bc6ec91df
Helper: bdf247b20c72ab21a60814be6c59dcb5df919860
```

当前 Mac 的信任设置没有把该自签名证书标为受信任根，因此 `codesign --verify --strict` 只在证书信任评估处返回 `CSSMERR_TP_NOT_TRUSTED`。本次没有擅自修改系统信任设置；安装包也未经过 Apple 公证，首次打开时仍需按发布说明处理系统安全提示。

## 安装包

`Mac-Optimizer-2.9.0.dmg`

SHA-256：

```text
eaacc4d2a8732fe79dc169bd9f355feced7d6b260dba109f6a5a53ad0dc441b2
```

发布后将从 GitHub 实际下载 Release 资产并再次核对哈希。
