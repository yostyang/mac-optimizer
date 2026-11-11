// 2.12 测试：文字承载色静态对比度（P0 可读性）与菜单栏电池充电符号
import SwiftUI
import AppKit

enum V212 {
    typealias T = MOTests
    /// 在指定外观下把颜色解析成 sRGB；带透明度的前景按 alpha 合成到背景上（与屏幕上实际看到的一致）
    static func resolve(_ c: Color, _ ap: NSAppearance.Name) -> NSColor { resolve(NSColor(c), ap) }
    static func resolve(_ c: NSColor, _ ap: NSAppearance.Name) -> NSColor {
        var out = NSColor.black
        NSAppearance(named: ap)!.performAsCurrentDrawingAppearance { out = c.usingColorSpace(.sRGB) ?? .black }
        return out
    }
    static func over(_ fg0: NSColor, _ bg0: NSColor) -> NSColor {
        // 白色等灰阶颜色没有 RGB 分量，先统一转成 sRGB，否则读 redComponent 会抛异常
        let fg = fg0.usingColorSpace(.sRGB) ?? fg0, bg = bg0.usingColorSpace(.sRGB) ?? bg0
        let a = fg.alphaComponent
        return NSColor(srgbRed: fg.redComponent * a + bg.redComponent * (1 - a), green: fg.greenComponent * a + bg.greenComponent * (1 - a),
                       blue: fg.blueComponent * a + bg.blueComponent * (1 - a), alpha: 1)
    }
    static func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let x = T.lum(a), y = T.lum(b); return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    static func hex(_ c0: NSColor) -> String { let c = c0.usingColorSpace(.sRGB) ?? c0; return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded())) }

    struct Pair { let name: String; let fg: Color; var tintFill: Color? = nil; let bg: Color; let bgName: String; var old: NSColor? = nil; var oldOverBG = true }

    static func tests() {
        T.sec("2.12 文字承载色：静态对比度（WCAG，小字 ≥ 4.5:1）")
        let surfaces: [(String, Color)] = [("window", DS.window), ("card", DS.card), ("raised", DS.raised), ("sidebar", DS.sidebar)]
        var rows: [String] = []
        var worst = 99.0, total = 0, passed = 0
        for ap in [NSAppearance.Name.aqua, .darkAqua] {
            let mode = ap == .aqua ? "浅色" : "深色"
            var pairs: [Pair] = []
            for (bn, bg) in surfaces {
                pairs.append(Pair(name: "次级文字", fg: DS.text.secondary, bg: bg, bgName: bn, old: resolve(NSColor.secondaryLabelColor, ap)))
                pairs.append(Pair(name: "正常状态文字", fg: DS.text.good, bg: bg, bgName: bn, old: resolve(good, ap)))
                pairs.append(Pair(name: "注意状态文字", fg: DS.text.warn, bg: bg, bgName: bn, old: resolve(warn, ap)))
                pairs.append(Pair(name: "危险状态文字", fg: DS.text.bad, bg: bg, bgName: bn, old: resolve(bad, ap)))
                pairs.append(Pair(name: "品牌紫文字", fg: accentText, bg: bg, bgName: bn))
            }
            // 状态标签：文字压在同色 13% 底上（面板指标卡右上角、电池健康度）
            for (n, t, g) in [("正常标签", DS.text.good, good), ("注意标签", DS.text.warn, warn), ("危险标签", DS.text.bad, bad),
                              ("次级标签", DS.text.secondary, DS.text.secondary),
                              ("网络类型标签", DS.text.tone(DS.metric.network), DS.metric.network), ("风扇个数标签", DS.text.tone(DS.metric.fan), DS.metric.fan)] {
                pairs.append(Pair(name: n, fg: t, tintFill: g, bg: DS.card, bgName: "card+13%"))
            }
            // 选中行（列表、操作面板、进程）与主按钮：字压在 selectionFill 上
            pairs.append(Pair(name: "选中行主字", fg: DS.text.onSelection, bg: DS.selectionFill, bgName: "selection", old: .white))
            pairs.append(Pair(name: "选中行副字", fg: DS.text.onSelectionSecondary, bg: DS.selectionFill, bgName: "selection", old: NSColor.white.withAlphaComponent(0.8)))
            pairs.append(Pair(name: "主按钮白字", fg: .white, bg: DS.selectionFill, bgName: "selection", old: .white))
            for p in pairs {
                var bg = resolve(p.bg, ap)
                if let tf = p.tintFill { bg = over(resolve(tf, ap).withAlphaComponent(0.13), bg) }
                let fg = over(resolve(p.fg, ap), bg)
                let r = ratio(fg, bg)
                total += 1; if r >= 4.5 { passed += 1 }; worst = min(worst, r)
                var oldText = ""
                if let o = p.old {
                    // 旧值：选中行的底是品牌紫 accent，其余是同一块背景
                    let oldBG = p.bgName == "selection" ? resolve(accent, ap) : bg
                    oldText = String(format: "旧 %.2f → ", ratio(over(o, oldBG), oldBG))
                }
                let line = "\(mode) \(p.name) \(hex(fg)) on \(p.bgName) \(hex(bg))：\(oldText)新 " + String(format: "%.2f:1", r)
                rows.append(line)
                T.check(r >= 4.5, "\(mode) \(p.name) on \(p.bgName)", String(format: "%.2f:1 %@ / %@", r, hex(fg), hex(bg)))
            }
        }
        T.info(String(format: "共 %d 组，%d 组 ≥ 4.5:1，最低 %.2f:1", total, passed, worst))
        // 具体取值与方案一致（方案 #62626E、#08744F、#8B5100、#5846D6、#EEECFB）
        T.check(hex(resolve(DS.text.secondary, .aqua)) == "#62626E" && hex(resolve(DS.text.good, .aqua)) == "#08744F" && hex(resolve(DS.text.warn, .aqua)) == "#8B5100",
                "浅色次级 / 正常 / 注意文字取方案值", [hex(resolve(DS.text.secondary, .aqua)), hex(resolve(DS.text.good, .aqua)), hex(resolve(DS.text.warn, .aqua))].joined(separator: " "))
        T.check(hex(resolve(DS.selectionFill, .darkAqua)) == "#5846D6" && hex(resolve(DS.text.onSelectionSecondary, .darkAqua)) == "#EEECFB", "深色选中底 #5846D6、副字 #EEECFB")
        T.check(DS.text.tone(good) == DS.text.good && DS.text.tone(warn) == DS.text.warn && DS.text.tone(bad) == DS.text.bad && DS.text.tone(.primary) == .primary,
                "状态图形色可换成对应文字色，其他颜色原样返回")
        T.check(good != DS.text.good && warn != DS.text.warn, "图形用的 good / warn 保留原值（图标、圆环、曲线不变）")

        T.sec("2.12 卡片内边距令牌")
        T.check(DS.cardPadding == 16 && DS.titledCardPadding == 12 && DS.tilePadding == 10, "指标卡 16、带标题 Card 12（2.13 再统一）、面板指标卡 / 电池宽卡 / Tile 10")

        T.sec("2.12 菜单栏电池：充电符号")
        var mono = TrioConfig(); mono.color = false; mono.percent = true
        T.check(TrioIcon.batteryMarks(charging: true, config: mono) == (true, true), "单色 + 百分比 + 充电：数字和闪电都画")
        T.check(TrioIcon.batteryMarks(charging: false, config: mono) == (true, false), "不充电只画数字")
        var noPct = mono; noPct.percent = false
        T.check(TrioIcon.batteryMarks(charging: true, config: noPct) == (false, true), "不显示百分比时充电仍画闪电（2.11 行为不变）")
        func render(_ charging: Bool, _ c: TrioConfig, _ p: Int) -> NSBitmapImageRep? {
            let size = CGSize(width: 32, height: 16)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            TrioIcon.drawBattery(in: CGRect(origin: .zero, size: CGSize(width: 28, height: 14)), percent: p, charging: charging, config: c, ink: .black)
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        func inked(_ rep: NSBitmapImageRep?) -> Int {
            guard let rep else { return -1 }
            var n = 0
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide { if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { n += 1 } } }
            return n
        }
        for p in [100, 76, 8] {
            let a = inked(render(false, mono, p)), b = inked(render(true, mono, p))
            T.check(a > 0 && b > a, "单色 \(p)%：充电时多画了闪电", "不充电 \(a) px，充电 \(b) px")
        }
        var color = TrioConfig(); color.color = true; color.percent = true
        let ca = inked(render(false, color, 76)), cb = inked(render(true, color, 76))
        T.check(ca > 0 && cb > 0, "彩色 + 百分比 + 充电也能正常绘制", "不充电 \(ca) px，充电 \(cb) px")
        T.check(TrioIcon.volumeSymbol(VolumeState(level: 0.5, muted: true)).name == "speaker.slash.fill", "回归：静音仍是带斜杠的喇叭（2.11）")

        // 对照表（供发布记录引用）
        T.info("对比度对照表：")
        rows.forEach { T.info("  " + $0) }
    }
}
