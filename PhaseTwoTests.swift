import AppKit

enum PhaseTwo {
    static func tests() {
        typealias T = MOTests
        T.sec("第二期：网络读数口径与缺失状态")
        let empty = NetworkSummary.latency(targets: [], resolves: [])
        T.check(empty.publicMS == nil && empty.routerMS == nil && empty.dnsMS == nil && empty.loss == nil,
                "未检测时延迟与丢包均未知，不能显示为 0")
        let ping = PingResult(avgMs: 31, loss: 20, sent: 5)
        let targets = [PingTarget(name: "路由器（网关）", host: "192.168.1.1", result: PingResult(avgMs: 3, loss: 0, sent: 5)),
                       PingTarget(name: "阿里 DNS", host: "223.5.5.5", result: ping)]
        let resolve = ResolveResult(host: "www.baidu.com", ms: 17, addrs: ["1.2.3.4"], verdict: .ok)
        let values = NetworkSummary.latency(targets: targets, resolves: [resolve])
        T.check(values.publicMS == 31 && values.routerMS == 3 && values.dnsMS == 17 && values.loss == 20,
                "公网 ICMP、路由器 ICMP、域名解析来自不同检测结果")
        T.check(NetworkSummary.latency(targets: targets, resolves: []).dnsMS == nil,
                "ping 到 DNS 服务器不冒充 DNS 解析耗时")
        let failed = ResolveResult(host: "www.baidu.com", ms: 0, addrs: [], verdict: .failed)
        T.check(NetworkSummary.latency(targets: targets, resolves: [failed]).dnsMS == nil,
                "解析失败不展示成零延迟")
        T.check(NetworkSummary.bytes(1_048_576).unit == "MiB" && NetworkSummary.bytes(1_073_741_824).unit == "GiB"
                && NetworkSummary.rate(1_048_576).unit == "MiB/s", "二进制流量使用 MiB/GiB 单位")
        T.check(TrafficRange.day1.title == "24 小时" && TrafficRange.day30.title == "30 天",
                "滚动时段不伪称今天或本月")
        T.check(AppTraffic.liveInterval == 2 && AppTraffic.backgroundInterval == 60,
                "网络总览复用既有按应用采样器与查看者计数")
        let now = Date(timeIntervalSince1970: 1000 * 3600)
        let hours = [THour(t: 976, i: 900, o: 900, apps: [:]), THour(t: 977, i: 100, o: 20, apps: [:]), THour(t: 1000, i: 200, o: 30, apps: [:])]
        let totals = NetworkSummary.hourlyTotals(hours, range: .day1, now: now)
        T.check(totals.inB == 300 && totals.outB == 50 && totals.buckets == 2,
                "总量与应用排行使用相同的滚动 24 小时桶边界，不混用分钟覆盖")
        let source = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
            NSColor.systemRed.setFill(); rect.fill(); return true
        }
        let icon = IconCache.thumbnail(source)
        let bitmap = icon?.representations.first as? NSBitmapImageRep
        T.check(icon?.size == NSSize(width: 16, height: 16) && bitmap?.pixelsWide == 32 && bitmap?.pixelsHigh == 32,
                "进程图标只保留 16 pt / 2x 小图，不缓存完整 1024 像素图")
        T.check((bitmap?.colorAt(x: 16, y: 16)?.alphaComponent ?? 0) > 0.9,
                "小图仍保留有效图像内容")
        T.check(Set(QuickActionList.all().map(\.id)).count == 6, "菜单面板保留全部六项现有快捷动作")
    }
}
