// 2.16 N1：不依赖辅助功能树的对比度验收
//
// 文字区域来自 `.contrastTarget` 布局标记（ContrastGate.swift），不读 AX；取样在真实渲染图里做：
// 区域内出现最多的亮度当作实际背景（含透明叠加、选中底、卡片色），再取离背景最远的墨迹像素（90 分位）作为前景。
// 每个必测用例必须给出 passed / failed / unverified：缺少文字区域、截图失败、只检查到部分必测目标都记 unverified，
// 并写明原因与目标标识。未验收不是通过，test.sh 与发布检查都不放行。
import SwiftUI
import AppKit

struct ContrastTargetResult: Codable, Equatable {
    var targetID: String
    var role: ContrastRole
    var status: ContrastStatus
    var measuredRatio: Double?      // 未验收时为空：不写 0，也不补造
    var threshold: Double
    var reason: String
}
enum ContrastStatus: String, Codable { case passed, failed, unverified }
struct ContrastCaseResult: Codable, Equatable {
    var caseID: String
    var appearance: String
    var size: String
    var status: ContrastStatus
    var reason: String
    var targets: [ContrastTargetResult]
}

enum ContrastCheck {
    /// 本轮必测用例（发布门槛）与自检探针（故意缺目标，验证会记为未验收；不计入门槛）
    static var cases: [ContrastCaseResult] = []
    static var probes: [ContrastCaseResult] = []

    // MARK: 必测目标
    /// 每个必测用例必须出现并测到的目标（前缀匹配：`sidebar.item` 匹配 `sidebar.item` 与 `sidebar.item:…`）
    static func required(for name: String) -> [String] {
        let main = ["dashboard-", "battery-", "overview-"]
        if main.contains(where: { name.hasPrefix($0) }) { return ["page.title", "sidebar.item", "sidebar.item.selected", "section.label", "bottom.status", "bottom.action"] }
        if name.hasPrefix("面板") { return ["panel.tile.title", "panel.tile.value", "panel.tile.footer"] }
        if name.hasPrefix("充电卡片") { return ["card.title"] }
        if name.hasPrefix("states216") { return statesRequired }
        return []
    }
    /// 状态样例：选中、禁用、错误、长名称、低电量与未知
    static let statesRequired = ["listrow.title", "listrow.title.selected", "listrow.sub", "listrow.sub.selected", "kbd", "kbd.on",
                                 "pill.filled", "pill.plain", "pill.disabled", "chip.on", "chip.off", "chip.sub.on",
                                 "segment.on", "segment.off", "state.failed", "state.stale", "state.done", "state.detail",
                                 "battery.level.critical", "battery.level.low", "battery.level.normal", "battery.value.unknown", "battery.value.stale",
                                 "battery.badge.critical", "battery.badge.low", "proc.name", "proc.name.selected"]

    // MARK: 标记查找（NSView 层级，不读 AX）
    struct Found { let id: String; let role: ContrastRole; let rect: CGRect?; let hiddenReason: String }
    static func markers(in root: NSView) -> [Found] {
        var out: [Found] = []
        func walk(_ v: NSView) {
            if let m = v as? ContrastMarkerView {
                let vis = m.visibleRect
                let full = m.bounds.width * m.bounds.height
                if m.isHiddenOrHasHiddenAncestor || full < 4 {
                    out.append(Found(id: m.targetID, role: m.role, rect: nil, hiddenReason: "目标没有显示（隐藏或尺寸为 0）"))
                } else if vis.width * vis.height < full * 0.5 {
                    out.append(Found(id: m.targetID, role: m.role, rect: nil, hiddenReason: "目标不在可见范围内（被滚动或裁切）"))
                } else {
                    var r = root.convert(vis, from: m)
                    if !root.isFlipped { r.origin.y = root.bounds.height - r.maxY }   // 统一成 y 向下，和位图行序一致
                    out.append(Found(id: m.targetID, role: m.role, rect: r, hiddenReason: ""))
                }
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    // MARK: 取样
    /// 位图一次性转成 sRGB 亮度表（透明处按白底合成），避免逐像素 NSColor 换算
    struct LumaMap {
        let w: Int, h: Int
        var l: [Float]
        init?(_ rep: NSBitmapImageRep) {
            guard let cg = rep.cgImage, let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            let W = cg.width, H = cg.height
            guard W > 0, H > 0 else { return nil }
            var buf = [UInt8](repeating: 0, count: W * H * 4)
            let ok: Bool = buf.withUnsafeMutableBytes { p in
                guard let ctx = CGContext(data: p.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
                return true
            }
            guard ok else { return nil }
            let lut: [Float] = (0..<256).map { i in
                let v = Double(i) / 255
                return Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4))
            }
            var out = [Float](repeating: 0, count: W * H)
            for i in 0..<(W * H) {
                let o = i * 4
                out[i] = 0.2126 * lut[Int(buf[o])] + 0.7152 * lut[Int(buf[o + 1])] + 0.0722 * lut[Int(buf[o + 2])]
            }
            w = W; h = H; l = out
        }
    }
    static func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
    /// 在像素矩形里测对比度：最多的亮度档 = 实际背景；离背景最远的墨迹像素 90 分位 = 前景。
    /// 没有可辨认的墨迹时返回 nil 与原因（不当作通过，也不写 0）。
    static func measure(_ map: LumaMap, _ px: CGRect) -> (ratio: Double?, reason: String) {
        let x0 = max(0, Int(px.minX.rounded(.down))), x1 = min(map.w, Int(px.maxX.rounded(.up)))
        let y0 = max(0, Int(px.minY.rounded(.down))), y1 = min(map.h, Int(px.maxY.rounded(.up)))
        guard x1 - x0 >= 3, y1 - y0 >= 3 else { return (nil, "取样区域不足 3×3 像素") }
        var bins = [Int](repeating: 0, count: 64), sums = [Double](repeating: 0, count: 64)
        var ls: [Double] = []; ls.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 { for x in x0..<x1 {
            let v = Double(map.l[y * map.w + x]); ls.append(v)
            let b = min(63, Int(v * 64)); bins[b] += 1; sums[b] += v
        } }
        guard let mode = bins.indices.max(by: { bins[$0] < bins[$1] }), bins[mode] > 0 else { return (nil, "取样失败") }
        let bg = sums[mode] / Double(bins[mode])
        let ink = ls.map { ratio($0, bg) }.filter { $0 >= 1.2 }.sorted()
        guard ink.count >= max(3, ls.count / 200) else { return (nil, "区域内没有渲染出可辨认的文字或图形") }
        return (ink[Int(Double(ink.count - 1) * 0.9)], "")
    }

    // MARK: 判定（纯函数）
    struct Measured { let id: String; let role: ContrastRole; let ratio: Double?; let reason: String }
    static func matches(_ id: String, _ req: String) -> Bool { id == req || id.hasPrefix(req + ":") }
    static func evaluate(caseID: String, appearance: String, size: String, measured: [Measured], required: [String], setupError: String? = nil) -> ContrastCaseResult {
        var targets = measured.map { m -> ContrastTargetResult in
            guard let r = m.ratio else {
                return ContrastTargetResult(targetID: m.id, role: m.role, status: .unverified, measuredRatio: nil, threshold: m.role.threshold, reason: m.reason)
            }
            let ok = r >= m.role.threshold
            return ContrastTargetResult(targetID: m.id, role: m.role, status: ok ? .passed : .failed, measuredRatio: r, threshold: m.role.threshold,
                                        reason: ok ? "" : String(format: "%.2f:1 低于 %.1f:1", r, m.role.threshold))
        }
        var reasons: [String] = []
        if let setupError { reasons.append(setupError) }
        for req in required {
            let hits = targets.filter { matches($0.targetID, req) }
            if hits.isEmpty {
                reasons.append("缺少必测目标 \(req)")
                targets.append(ContrastTargetResult(targetID: req, role: .text, status: .unverified, measuredRatio: nil, threshold: ContrastRole.text.threshold, reason: "没有找到这个文字区域"))
            } else if !hits.contains(where: { $0.measuredRatio != nil }) {
                reasons.append("必测目标 \(req) 未测到（\(hits.first?.reason ?? "")）")
            }
        }
        if !targets.contains(where: { $0.measuredRatio != nil }) { reasons.append("没有测到任何文字区域") }
        let failed = targets.filter { $0.status == .failed }
        let status: ContrastStatus = !failed.isEmpty ? .failed : (reasons.isEmpty ? .passed : .unverified)
        let why = (failed.prefix(6).map { "\($0.targetID) \($0.reason)" } + reasons).joined(separator: "；")
        return ContrastCaseResult(caseID: caseID, appearance: appearance, size: size, status: status, reason: why, targets: targets)
    }

    // MARK: 执行
    static func dims(_ name: String) -> (appearance: String, size: String) {
        (name.contains("dark") ? "dark" : "light", name.contains("min") ? "min" : "default")
    }
    /// 对一张已渲染的视图做检测并记录；probe = true 时只进自检，不计入发布门槛
    @discardableResult
    static func run(_ v: NSView, _ rep: NSBitmapImageRep?, caseID: String, required req: [String]? = nil, probe: Bool = false) -> ContrastCaseResult {
        let d = dims(caseID), required = req ?? required(for: caseID)
        let result: ContrastCaseResult
        if let rep, let map = LumaMap(rep), v.bounds.width > 0, v.bounds.height > 0 {
            let sx = CGFloat(map.w) / v.bounds.width, sy = CGFloat(map.h) / v.bounds.height
            let measured = markers(in: v).map { f -> Measured in
                guard let r = f.rect else { return Measured(id: f.id, role: f.role, ratio: nil, reason: f.hiddenReason) }
                let m = measure(map, CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy))
                return Measured(id: f.id, role: f.role, ratio: m.ratio, reason: m.reason)
            }
            result = evaluate(caseID: caseID, appearance: d.appearance, size: d.size, measured: measured, required: required)
        } else {
            result = evaluate(caseID: caseID, appearance: d.appearance, size: d.size, measured: [], required: required, setupError: "截图失败或无法读取像素")
        }
        if probe { probes.append(result) } else { cases.append(result) }
        return result
    }

    // MARK: 汇总
    static func counts(_ xs: [ContrastCaseResult]) -> (passed: Int, failed: Int, unverified: Int) {
        (xs.filter { $0.status == .passed }.count, xs.filter { $0.status == .failed }.count, xs.filter { $0.status == .unverified }.count)
    }
    static func summaryLine() -> String {
        let c = counts(cases)
        return "contrast: \(c.passed) 通过, \(c.failed) 失败, \(c.unverified) 未验收"
    }
    static func writeReport(_ dir: String) {
        struct Report: Codable { var summary: String; var cases: [ContrastCaseResult]; var probes: [ContrastCaseResult] }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(Report(summary: summaryLine(), cases: cases, probes: probes)) {
            try? d.write(to: URL(fileURLWithPath: dir + "/contrast-report.json"))
        }
        var lines = [summaryLine()]
        for c in cases where c.status != .passed { lines.append("\(c.status.rawValue)\t\(c.caseID)\t\(c.reason)") }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: dir + "/contrast-summary.txt", atomically: true, encoding: .utf8)
    }

    // MARK: 纯逻辑自检（--selftest，不需要窗口）
    static func selftest(_ check: (Bool, String, String) -> Void) {
        // 1) 合成位图：白底上画 #62626E 的「字」与 #CCCCCC 的「字」
        func rep(_ fg: NSColor, bg: NSColor = .white) -> NSBitmapImageRep? {
            guard let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 24, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: r)
            bg.usingColorSpace(.sRGB)?.setFill(); NSRect(x: 0, y: 0, width: 80, height: 24).fill()
            fg.usingColorSpace(.sRGB)?.setFill()
            for i in 0..<8 { NSRect(x: 4 + i * 9, y: 6, width: 3, height: 12).fill() }   // 8 根「笔画」
            NSGraphicsContext.restoreGraphicsState(); return r
        }
        let grey = NSColor(srgbRed: 0x62 / 255.0, green: 0x62 / 255.0, blue: 0x6E / 255.0, alpha: 1)
        let pale = NSColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1)
        if let r1 = rep(grey), let m1 = LumaMap(r1), let r2 = rep(pale), let m2 = LumaMap(r2), let r3 = rep(.white), let m3 = LumaMap(r3) {
            let a = measure(m1, CGRect(x: 0, y: 0, width: 80, height: 24)).ratio ?? 0
            check(abs(a - 6.0) < 0.3, "N1 取样：白底 #62626E 约 6.0:1", String(format: "%.2f", a))
            let b = measure(m2, CGRect(x: 0, y: 0, width: 80, height: 24)).ratio ?? 99
            check(b < 2, "N1 取样：浅灰字判为低对比", String(format: "%.2f", b))
            let c = measure(m3, CGRect(x: 0, y: 0, width: 80, height: 24))
            check(c.ratio == nil && !c.reason.isEmpty, "N1 取样：没有墨迹记为无法测量而不是通过", c.reason)
        } else { check(false, "N1 合成位图", "无法创建") }
        // 2) 判定：通过 / 失败 / 缺目标未验收 / 全空未验收
        let ok = evaluate(caseID: "t", appearance: "light", size: "default", measured: [Measured(id: "page.title", role: .largeText, ratio: 3.2, reason: ""),
                                                                                   Measured(id: "listrow.title:Xcode", role: .text, ratio: 7, reason: "")], required: ["page.title", "listrow.title"])
        check(ok.status == .passed, "N1 判定：大字 3.2:1 与正文 7:1 通过", ok.reason)
        let low = evaluate(caseID: "t", appearance: "light", size: "default", measured: [Measured(id: "page.sub", role: .text, ratio: 4.2, reason: "")], required: [])
        check(low.status == .failed && low.targets.first?.measuredRatio == 4.2, "N1 判定：正文 4.2:1 失败并保留实测值", low.reason)
        let missing = evaluate(caseID: "t", appearance: "light", size: "default", measured: [Measured(id: "page.title", role: .largeText, ratio: 5, reason: "")], required: ["page.title", "bottom.status"])
        check(missing.status == .unverified && missing.reason.contains("bottom.status")
              && missing.targets.contains { $0.targetID == "bottom.status" && $0.measuredRatio == nil }, "N1 判定：缺少必测文字区域记为未验收并写明目标", missing.reason)
        let empty = evaluate(caseID: "t", appearance: "light", size: "default", measured: [], required: [])
        check(empty.status == .unverified, "N1 判定：一个目标都没有测到不算通过", empty.reason)
        let partial = evaluate(caseID: "t", appearance: "light", size: "default", measured: [Measured(id: "page.title", role: .largeText, ratio: nil, reason: "目标不在可见范围内（被滚动或裁切）")], required: ["page.title"])
        check(partial.status == .unverified, "N1 判定：必测目标被裁切记为未验收", partial.reason)
        check(ContrastRole.forFont(size: 17, bold: true) == .largeText && ContrastRole.forFont(size: 17, bold: false) == .text
              && ContrastRole.forFont(size: 18, bold: false) == .largeText && ContrastRole.forFont(size: 12, bold: true) == .text,
              "N1 大字口径固定：≥18 pt 或 ≥14 pt 粗体", "")
        check(ContrastRole.text.threshold == 4.5 && ContrastRole.largeText.threshold == 3 && ContrastRole.graphic.threshold == 3, "N1 阈值：正文 4.5、大字 3、图形 3", "")
    }

    // MARK: 截图阶段：状态样例与 AX 不可用探针
    /// 选中 / 禁用 / 错误 / 长名称 / 低电量与未知：浅深两套各测一次
    struct StatesSample: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ListRow(icon: nil, symbol: "gearshape", title: "普通行", subtitle: "副标题说明")
                ListRow(icon: nil, symbol: "gearshape", title: "选中行", subtitle: "选中行副标题", selected: true) { Kbd(text: "↵", on: true) }
                HStack { Kbd(text: "⌘K"); Spacer() }
                ListRow(icon: nil, symbol: "doc", title: "一个非常非常长的文件名称-用于检查截断后仍然清楚可读-2026-11-14-最终版本.dmg", subtitle: "/Users/me/Downloads/很长的目录/更长的子目录")
                    .frame(width: 360)
                HStack(spacing: 8) {
                    Button("主按钮") {}.buttonStyle(PillButton())
                    Button("次按钮") {}.buttonStyle(PillButton(filled: false))
                    Button("禁用按钮") {}.buttonStyle(PillButton()).disabled(true)
                    ChoiceChip(text: "60 Hz", on: true, sub: "当前") {}
                    ChoiceChip(text: "120 Hz", on: false) {}
                }
                InlineSegment(items: [("今天", 0), ("7 天", 1)], selection: .constant(0))
                StateLine(kind: .failed, text: "恢复失败：原位置已有同名文件", detail: "没有覆盖任何文件。", actions: [.retry {}])
                StateLine(kind: .stale, text: "读数已过期", detail: "最近一次成功读取在 12 分钟前。")
                StateLine(kind: .done, text: "已恢复到原位置")
                HStack(spacing: 12) {
                    BatteryLevelView(name: "妙控鼠标", percent: 6, freshness: .fresh)
                    BatteryLevelView(name: "妙控键盘", percent: 18, freshness: .fresh)
                    BatteryLevelView(name: "AirPods", percent: 64, freshness: .fresh)
                    BatteryLevelView(name: "Keychron K3", percent: nil, freshness: .unknown)
                    BatteryLevelView(name: "MX Master", percent: 40, freshness: .expired)
                }
                ContrastProcSample()
            }.padding(16)
        }
    }
    struct ContrastProcSample: View {
        var body: some View {
            VStack(spacing: 2) {
                Text("Google Chrome Helper").font(DS.sub()).contrastTarget("proc.name").frame(maxWidth: .infinity, alignment: .leading).padding(6)
                Text("Xcode").font(DS.sub()).foregroundColor(DS.text.onSelection).contrastTarget("proc.name.selected")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous).fill(DS.selectionFill))
            }
        }
    }
    /// AC01：整棵树对辅助功能隐藏（AX 文字树不可用），并故意缺一个必测目标
    struct AXlessProbe: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("探针标题").font(DS.title()).contrastTarget("probe.title", .largeText)
                Text("探针正文，用于确认不依赖辅助功能树也能取样").font(DS.sub()).foregroundColor(DS.text.secondary).contrastTarget("probe.body")
            }.padding(16).accessibilityHidden(true)
        }
    }

    static func snapshots(_ out: String) {
        for (mode, ap) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: ap)
            func render<V: View>(_ v: V, width: CGFloat, _ file: String) -> (NSHostingView<AnyView>, NSWindow, NSBitmapImageRep?) {
                let host = NSHostingView(rootView: AnyView(v.frame(width: width).background(DS.window)))
                let size = host.fittingSize; host.frame = NSRect(origin: .zero, size: size)
                let cw = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
                cw.appearance = NSAppearance(named: ap); cw.contentView = host; cw.orderFrontRegardless(); MOTests.settle(1.0)
                return (host, cw, MOTests.pngRep(host, out + "/\(file)-\(mode).png"))
            }
            let (h1, w1, r1) = render(StatesSample(), width: 640, "states216")
            let res = run(h1, r1, caseID: "states216 \(mode)")
            MOTests.check(res.status == .passed, "对比度必测 states216 \(mode)", res.status.rawValue + (res.reason.isEmpty ? "" : "：" + res.reason))
            w1.orderOut(nil)
            // 探针：AX 不可用 + 故意缺 probe.missing，必须得到 unverified，且已有的两段文字仍能测出数值
            let (h2, w2, r2) = render(AXlessProbe(), width: 420, "axless216")
            let axNodes = MOTests.axNodes(w2)
            let p = run(h2, r2, caseID: "axless216 \(mode)", required: ["probe.title", "probe.body", "probe.missing"], probe: true)
            let measuredWithoutAX = p.targets.filter { $0.targetID.hasPrefix("probe.") && $0.targetID != "probe.missing" && $0.measuredRatio != nil }.count
            MOTests.check(p.status == .unverified && p.reason.contains("probe.missing") && measuredWithoutAX == 2,
                          "AC01 探针 \(mode)：AX 不可用仍能取样，缺必测目标记为未验收",
                          "status=\(p.status.rawValue) 已测 \(measuredWithoutAX)/2 AX 节点=\(axNodes) \(p.reason)")
            w2.orderOut(nil)
        }
        NSApp.appearance = NSAppearance(named: .aqua)
    }
}
