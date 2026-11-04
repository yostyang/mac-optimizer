// v1.7 测试：测速计算、抖动、流量聚合裁剪、lsof 解析、Wi-Fi 解析（全部 Mock，不碰真实网络）
import SwiftUI
import AppKit

extension MOTests {
    static func v17Tests() {
        sec("测速计算与档位")
        check(SpeedCalc.mbps(bytes: 12_500_000, seconds: 1) == 100, "12.5 MB / 1 秒 = 100 Mbps")
        check(SpeedCalc.mbps(bytes: 0, seconds: 1) == 0 && SpeedCalc.mbps(bytes: 100, seconds: 0) == 0, "0 字节或 0 秒不谎报速度")
        check(abs(SpeedCalc.jitter([10, 10, 10]) - 0) < 0.001, "延迟都一样时抖动为 0")
        check(abs(SpeedCalc.jitter([0, 20]) - 10) < 0.001, "抖动 = 样本标准差")
        check(SpeedCalc.tier(5).hasPrefix("基础宽带") && SpeedCalc.tier(80).hasPrefix("百兆宽带") && SpeedCalc.tier(1000).hasPrefix("千兆级"), "档位只给文字说明，不编排名")
        check(!SpeedCalc.tier(80).contains("超过") && !SpeedCalc.tier(80).contains("%"), "档位不含排名和百分比宣传")
        sec("流量聚合与裁剪")
        var store = TrafficStore()
        store.buckets = []
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        store.add(downBps: 1000, upBps: 100, tun: false, date: base)
        store.add(downBps: 3000, upBps: 300, tun: true, date: base.addingTimeInterval(10))
        check(store.buckets.count == 1 && store.buckets[0].count == 2 && abs(store.buckets[0].downAvg - 2000) < 0.001 && store.buckets[0].tun, "同一分钟合并成一桶，TUN 标记保留")
        store.add(downBps: 100, upBps: 10, tun: false, date: base.addingTimeInterval(31 * 24 * 3600))
        check(store.buckets.count == 1 && store.buckets[0].minute == TrafficParse.bucketKey(base.addingTimeInterval(31 * 24 * 3600)), "30 天外自动删除")
        let baseMinute = TrafficParse.bucketKey(base)
        store.buckets = (0..<5).map { TrafficBucket(minute: baseMinute - 4 + Int64($0), downAvg: Double($0), upAvg: 0, count: 1, tun: false) }
        store.maxBuckets = 3; store.prune(now: base)
        check(store.buckets.count == 3 && store.buckets.last?.minute == baseMinute, "超过上限只留最新")
        store.maxBuckets = 43200
        sec("按应用与 Wi-Fi 解析")
        let apps = TrafficParse.parseLsof("COMMAND  PID USER\nSafari  123 yost\nSafari  124 yost\nEdge  200 yost\n")
        check(apps.count == 2 && apps[0].name == "Safari" && apps[0].connections == 2, "lsof 按应用数连接数，不冒充字节数")
        let a = NetInfoParse.airport("  SSID: MyWiFi\n  agrCtlRSSI: -55\n  channel: 36\n  lastTxRate: 866\n")
        check(a.ssid == "MyWiFi" && a.rssi == "-55" && a.channel == "36" && a.tx == "866", "airport 输出解析")
        check(TrafficParse.bucketKey(Date(timeIntervalSince1970: 120)) == 2, "分钟桶键 = 纪元秒 / 60")
    }
}
