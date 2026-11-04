// v1.9 测试：提醒防抖、磁盘与电池阈值、改动记录（不发真实通知、不删文件）
import SwiftUI
import AppKit

extension MOTests {
    static func v19Tests() {
        sec("提醒：防抖与阈值")
        let now = Date()
        check(AlertCheck.cpuSustained(samples: [95, 96, 97, 98, 99], threshold: 90, minSamples: 5, lastAlert: nil, now: now, cooldown: 3600), "CPU 连续 5 次高于阈值才提醒")
        check(!AlertCheck.cpuSustained(samples: [95, 50, 97, 98, 99], threshold: 90, minSamples: 5, lastAlert: nil, now: now, cooldown: 3600), "中间掉下来一次就不提醒")
        check(!AlertCheck.cpuSustained(samples: [95, 96], threshold: 90, minSamples: 5, lastAlert: nil, now: now, cooldown: 3600), "样本不够不提醒")
        check(!AlertCheck.cpuSustained(samples: [95, 96, 97, 98, 99], threshold: 90, minSamples: 5, lastAlert: now.addingTimeInterval(-600), now: now, cooldown: 3600), "冷却期内不重复弹")
        check(AlertCheck.cpuSustained(samples: [95, 96, 97, 98, 99], threshold: 90, minSamples: 5, lastAlert: now.addingTimeInterval(-3700), now: now, cooldown: 3600), "冷却期过后可再提醒")
        check(AlertCheck.diskAlmostFull(freeFraction: 0.05, freeGB: 100), "可用比例低于 10% 提醒")
        check(AlertCheck.diskAlmostFull(freeFraction: 0.5, freeGB: 10), "可用绝对值低于 20 GB 也提醒")
        check(!AlertCheck.diskAlmostFull(freeFraction: 0.5, freeGB: 100), "磁盘充足不提醒")
        check(AlertCheck.batteryHealthDrop(oldHealth: 85, newHealth: 79), "电池健康从 80 以上掉到 80 以下提醒")
        check(!AlertCheck.batteryHealthDrop(oldHealth: 79, newHealth: 78), "本来就低于 80 不重复提醒")
        check(!AlertCheck.batteryHealthDrop(oldHealth: nil, newHealth: 79), "读不到旧值不乱提醒")
        check(!AlertCheck.debounceChanged(true, lastValue: false, stableCount: 1, required: 3), "阈值附近只变一次不算真正变化")
        check(AlertCheck.debounceChanged(true, lastValue: false, stableCount: 3, required: 3), "连续 3 次同值才算变化")
        sec("改动记录")
        let log = ChangeLog()
        log.records = []
        log.add(kind: .clean, title: "清理测试", detail: "测试路径", reversible: true, restoreNote: "从废纸篓恢复")
        check(log.records.count == 1 && log.records[0].kind == .clean, "改动记入记录")
        let r = log.records[0]
        log.remove(r)
        check(log.records.isEmpty, "记录可删除")
        check(V19Settings().alertsOn == false, "异常提醒默认关闭")
    }
}
