# 2.9 电池参数来源审计（进行中）

代码基线：2.8.0。以下结论来自当前实现，尚未覆盖所有机型的实测差异。

| 界面参数 | 当前来源 | 当前处理 | 待改进 |
|---|---|---|---|
| 电量 | `AppleSmartBattery.CurrentCapacity` | 直接显示百分比 | 缺少字段范围校验和来源说明；需与系统电源读数核对。 |
| 最大/设计容量 | `AppleRawMaxCapacity` → `NominalChargeCapacity`；`DesignCapacity` | 显示为“容量 A / B mAh” | 分成两行并明确“当前最大容量 / 设计容量”；单侧缺失时不能显示另一侧为 0。 |
| 健康度 | 最大容量 ÷ 设计容量 | 四舍五入并封顶 100% | 标为“容量比（估算）”，与系统健康状况分开；核对不同电池报告的容量单位和口径。 |
| 健康状况 | `IOPSGetPowerSourceDescription` 的 `kIOPSBatteryHealthKey` | Good/Fair/Poor 翻译，否则显示原字符串 | 未取得时说明系统没有返回该字段；不能据估算健康度推断系统维修状态。 |
| 循环次数 | `AppleSmartBattery.CycleCount` | 直接显示 | 缺失时标“未取得”，避免与 0 次混淆。 |
| 温度 | `AppleSmartBattery.Temperature`，缺失时回退 HID 传感器 | 统一显示 °C | 补来源标注与异常范围校验；HID 回退应明确是不同来源。 |
| 电压/电流 | `Voltage`、`InstantAmperage`，后备 `Amperage` | 换算为 V/A | 明确电流正负方向；过期读数应与功率一起置为未知。 |
| 实时输入 | `PowerTelemetryData.SystemPowerIn` | 接电时显示 DC 输入功率 | 无数据时保留“不可读”原因；不能用适配器额定功率替代。 |
| 适配器功率 | 系统公开适配器详情 `Watts`，后备 SmartBattery/ACPI | 显示上报功率 | 明确它是额定/上报值，不是插座功率或协商功率。 |
| 预计充满 | 电量、最大容量、电压、充电功率计算 | 仅充电且数据齐全时展示 | 需核对是否与电池实际剩余容量一致；避免把该估算当系统承诺。 |

下一步按“容量与健康度语义 → 电压电流时效 → 温度来源”顺序修改界面和采集，并用接电、停充、拔电三种真实状态回归。
