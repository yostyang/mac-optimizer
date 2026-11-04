# v2.1（17）发布验证

- macOS 13 最低部署目标，主程序与充电助手均包含 arm64、x86_64。
- App 与充电助手通过 `codesign --verify --deep --strict` 校验；充电助手与原已签名助手二进制相同。
- `hdiutil verify` 校验发布 DMG 通过；从 DMG 只读挂载运行 `--selftest` 通过。
- `--uitest` 和 `--snapshot --goldens` 在相同二进制上执行；47 张输出截图已查看，没有更新黄金图来掩盖失败。

```text
selftest: 318 通过, 0 失败
uitest: 84 通过, 0 失败
snapshot: 70 通过, 0 失败
```

验证中修正了显示器模拟测试的设置隔离。临时构建目录复制助手时丢失的可执行权限已恢复，恢复后重新打包并对实际 DMG 中的应用补跑自检；此处记录的是修复后的各项结果。

DMG SHA-256：

```text
d0fce93263295171834b5e7c541dfd2ee1fdcb86f95ff20c8a116bd63efd364d
```

人工端到端边界：熄屏后 VPN 持续连接尚未完成干净实测；部分外接显示器的充电助手检测有限制。当前测速提供传输平均值，应用网络列表显示连接数。这些限制保留在 README 和 Release 说明中。
