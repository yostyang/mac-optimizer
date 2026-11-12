// 2.14 电池页顶部：充电「目标」和「实际」分开，暂停原因压成一句。电池页摘要和充电卡共用这份判断。
import SwiftUI

struct ChargeSummary: Equatable {
    /// 本机读数（来自监控采样）；读不到时退回助手报告的电量
    struct Reading: Equatable { var level: Int?; var charging = false; var onAC = false; var full = false }

    var target: String
    var actual: String
    /// 只描述状态的短语（不带电量），充电卡右侧使用
    var state: String
    var pause: String?
    /// 上限正在起作用（保持 / 用电池降到下沿）：状态字用 good 色
    var holding = false

    static func make(phase: ChargeClient.Phase, st: ChargeStatus, reading r: Reading) -> ChargeSummary {
        let set = st.settings
        let active = phase == .ready && set.enabled
        let target: String
        switch phase {
        case .unsupported: target = "系统默认（本机不支持充电上限）"
        case .ready: target = !set.enabled ? "未启用 · 按系统默认充电" : (st.topUp ? "临时充到 100%" : "上限 \(set.limit)%")
        default: target = "系统默认（未启用充电助手）"
        }
        var pause: String? = nil
        if active && st.caps.adapterMode {
            let wait = Int(ChargeConst.displayDebounce)
            if st.dockProtected == true { pause = "已暂停：保护扩展坞供电 · 关闭再开启上限可重新检测" }
            else if st.displayPaused == true {
                pause = st.externalDisplay == true ? "已暂停：接了外接显示器 · 拔掉后约 \(wait) 秒恢复上限" : "外接显示器已拔掉 · 约 \(wait) 秒内恢复上限"
            }
        }
        let state: String, holding: Bool
        if active && pause == nil && !st.topUp && st.adapterCut {
            state = "用电池供电，降到 \(set.limit - max(set.sail, 1))% 再接通电源"; holding = true
        } else if active && pause == nil && !st.topUp && st.inhibited {
            state = "保持在上限，暂停充电"; holding = true
        } else if active && st.topUp {
            state = "正在充到 100%，充满或拔掉电源后恢复上限"; holding = false
        } else {
            let onAC = r.level == nil ? st.plugged : r.onAC
            state = r.charging ? "正在充电" : (onAC ? (r.full ? "已充满" : "接电未充") : "电池供电"); holding = false
        }
        let level = r.level ?? st.level
        let actual = (level.map { "\($0)%" } ?? "电量未取得") + " · " + state
        return ChargeSummary(target: target, actual: actual, state: state, pause: pause, holding: holding)
    }

    /// 从监控快照取读数
    static func reading(_ s: Snapshot) -> Reading {
        Reading(level: s.battery, charging: s.charging, onAC: s.onAC, full: s.batteryFullyCharged)
    }

    /// 充电卡右侧那一句：暂停时说原因，启用时说状态，否则说目标
    func cardLine(enabled: Bool) -> String { pause ?? (enabled ? state : target) }
}

/// 电池页摘要里的一行：目标 | 实际，暂停时下面多一句原因
struct ChargeSummaryRow: View {
    let sum: ChargeSummary
    var health: Int? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 18) {
                field("目标", sum.target, tint: .primary, id: "bat.target")
                field("实际", sum.actual, tint: sum.holding ? DS.text.good : .primary, id: "bat.actual")
                if let health { field("健康度", "\(health)%", tint: .primary, id: "bat.health") }
                Spacer(minLength: 0)
            }
            if let p = sum.pause {
                Label(p, systemImage: "pause.circle").font(DS.sub()).foregroundColor(DS.text.warn).lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("bat.pause")
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("bat.charge.summary")
    }
    private func field(_ k: String, _ v: String, tint: Color, id: String) -> some View {
        HStack(spacing: 6) {
            Text(k).font(DS.sub()).foregroundColor(DS.text.secondary)
            Text(v).font(DS.sub(.semibold)).foregroundColor(tint).lineLimit(1).truncationMode(.tail)
        }
        .accessibilityElement(children: .combine).accessibilityLabel(k + "：" + v).accessibilityIdentifier(id)
    }
}
