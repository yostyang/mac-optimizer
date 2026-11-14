// 2.16 可读性与操作闭环：N2–N10 的逻辑自检、界面交互与截图（N1 见 ContrastTests.swift）
import SwiftUI
import AppKit

enum V216 {
    typealias T = MOTests

    static func tests() {
        T.sec("2.16 N2 / N3 电量状态唯一判断与非颜色提示")
        let lv = [0, 10, 11, 20, 21].map { BatteryLevel.of($0) }
        T.check(lv == [.critical, .critical, .low, .low, .normal], "分界：≤10% 危险、11–20% 注意、21% 正常", "\(lv)")
        T.check(BatteryLevel.critical.label == "电量极低" && BatteryLevel.low.label == "电量低" && BatteryLevel.normal.label == nil
                && BatteryLevel.critical.symbol != BatteryLevel.low.symbol, "低电量有文字与不同形状的图标（灰度可区分）")
        T.check(batteryColor(6) == bad && batteryColor(15) == warn && batteryColor(84) == good, "页面图形色走状态令牌，不再用系统红/橙")
        T.check(TrioIcon.batteryColor(6, charging: false) == badNS && TrioIcon.batteryColor(15, charging: true) == warnNS
                && TrioIcon.batteryColor(84, charging: true) == goodNS && TrioIcon.batteryColor(84, charging: false) == goodNS, "合并图标与页面同一状态色（AppKit 令牌）")
        T.check(BatteryLevel.normal.text == .primary && BatteryLevel.low.text == DS.text.warn && BatteryLevel.critical.text == DS.text.bad, "数值文字用 DS.text，不把图形色当文字色")
        T.check(BatterySpeech.label(name: "妙控鼠标", percent: 18, freshness: .fresh) == "妙控鼠标，电量 18%，电量低", "朗读：设备名 + 数值 + 低电量")
        T.check(BatterySpeech.label(name: "K3", percent: nil, freshness: .unknown) == "K3，电量未取得" && !BatterySpeech.label(name: "K3", percent: nil, freshness: .unknown).contains("0%"), "未知不读成 0%")
        T.check(BatterySpeech.label(name: "MX", percent: 5, freshness: .expired) == "MX，电量读数已过期", "过期不按旧值报低电量")
        T.check(BatterySpeech.label(name: "MX", percent: 9, freshness: .cached).hasSuffix("电量极低，缓存读数"), "缓存读数朗读时注明")
        T.check(TrioIcon.describe(battery: 15, charging: false, wifi: WifiState(link: .off), volume: VolumeState(level: 0.3)).hasPrefix("电池 15%，电量低"), "菜单栏合并图标的说明文字含低电量")

        T.sec("2.16 N5 外设读数：逐设备来源、时效与原因")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let bt = BTBattery(); bt.persist = false
        let a = BTDevice(name: "鼠标", address: "aa", kind: "computermouse", connected: true, ble: true, percent: 64, source: "系统电量（IORegistry）")
        let k = BTDevice(name: "Keychron K3", address: "bb", kind: "keyboard", connected: true, ble: false, percent: nil, reason: "未取得经典蓝牙电量，可能与型号或固件有关", reasonKind: .unsupported)
        bt.record([a, k], at: t0)
        T.check(bt.states["aa"]?.lastSuccessAt == t0 && bt.states["bb"]?.lastAttemptAt == t0 && bt.states["bb"]?.lastSuccessAt == nil, "部分设备失败：只给读到的设备记成功时间")
        T.check(bt.states["aa"]?.sourceReportedAt == nil, "来源没给上报时间时保持未知")
        var a2 = a; a2.percent = nil; a2.reason = "未取得标准电量服务读数"; a2.reasonKind = .noReport
        bt.record([a2], at: t0.addingTimeInterval(300))
        let cached = BTBattery.display(a2, state: bt.states["aa"], now: t0.addingTimeInterval(300))
        T.check(cached.freshness == .cached && cached.percent == 64 && cached.lastSuccessAt == t0 && cached.lastAttemptAt == t0.addingTimeInterval(300), "本次失败、旧值在 10 分钟内：标为缓存")
        let expired = BTBattery.display(a2, state: bt.states["aa"], now: t0.addingTimeInterval(BTBattery.cacheWindow + 1))
        T.check(expired.freshness == .expired && expired.percent == nil && expired.lastPercent == 64, "超过有效窗口：主值隐藏，详情保留最近成功值")
        T.check(BTBattery.cacheWindow == 2 * BTBattery.interval && BTBattery.cacheWindow == 600, "缓存窗口 = 刷新间隔 × 2（10 分钟）")
        var gone = a; gone.connected = false; gone.percent = nil; gone.reasonKind = .notConnected
        let off = BTBattery.display(gone, state: bt.states["aa"], now: t0.addingTimeInterval(60))
        T.check(off.freshness == .unknown && off.percent == nil && off.reasonKind == .notConnected, "断连：不再冒充实时值")
        let back = BTBattery.display(a, state: bt.states["aa"], now: t0.addingTimeInterval(900))
        T.check(back.freshness == .fresh && back.percent == 64, "重连后再次读到：恢复有效")
        let unk = BTBattery.display(k, state: bt.states["bb"], now: t0)
        T.check(unk.freshness == .unknown && unk.reasonKind == .unsupported, "未取得：带原因分类")
        let pl = BTParse.profiler(Data(#"{"SPBluetoothDataType":[{"device_connected":[{"BLE 鼠标":{"device_address":"11","device_services":"0x400020 < HID BLE >"}},{"经典键盘":{"device_address":"22","device_minorType":"Keyboard"}}],"device_not_connected":[{"旧耳机":{"device_address":"33"}}]}]}"#.utf8))
        let mg = BTParse.merge(paired: pl, ioreg: [:], gatt: [:], gattIssue: nil)
        T.check(mg.first { $0.name == "BLE 鼠标" }?.reasonKind == .noReport && mg.first { $0.name == "经典键盘" }?.reasonKind == .unsupported
                && mg.first { $0.name == "旧耳机" }?.reasonKind == .notConnected, "原因区分：未取得上报 / 不支持读取路径 / 未连接")
        let denied = BTParse.merge(paired: pl, ioreg: [:], gatt: [:], gattIssue: "没有蓝牙权限（系统设置 › 隐私与安全性 › 蓝牙）")
        T.check(denied.first { $0.name == "BLE 鼠标" }?.reasonKind == .unauthorized, "没有蓝牙权限：未授权")
        let kc = [BTDevice(name: "Keychron K3", address: "6c:93", kind: "keyboard", connected: true, ble: false, percent: nil)]
        T.check(BTParse.apply(hid: [], to: kc, access: .denied).first?.reasonKind == .unauthorized
                && BTParse.apply(hid: [], to: kc, access: .granted).first?.reasonKind == .noReport, "Keychron：未授权与已授权但无上报分开")

        T.sec("2.16 N4 提醒关闭后折叠，配置不丢")
        let suite = "mo.test.alerts216.\(getpid())"
        let ud = UserDefaults(suiteName: suite)!; ud.removePersistentDomain(forName: suite)
        var s = BatterySettings(); s.alertsOn = true; s.lowThresholds = [5, 15]; s.upper = 85; s.sounds["low"] = "Funk"; s.deviceLow = 25; s.save(ud)
        var r = BatterySettings.load(ud); r.alertsOn = false; r.save(ud)
        var r2 = BatterySettings.load(ud); r2.alertsOn = true; r2.save(ud); r2.alertsOn = false; r2.save(ud)
        let back2 = BatterySettings.load(ud)   // 相当于重启后读取
        T.check(!back2.alertsOn && back2.lowThresholds == [5, 15] && back2.upper == 85 && back2.sounds["low"] == "Funk" && back2.deviceLow == 25, "关闭 → 开启 → 再关闭并重新读取：阈值、提示音、外设设置都保留")
        ud.removePersistentDomain(forName: suite)
        T.check(BatteryAlerts.permissionNote(.denied).blocked && BatteryAlerts.permissionNote(.notDetermined).blocked && !BatteryAlerts.permissionNote(.authorized).blocked
                && BatteryAlerts.permissionNote(.authorized).text.contains("已生效") && !BatteryAlerts.permissionNote(.denied).text.contains("已生效"), "系统不允许通知时不显示「已生效」")

        T.sec("2.16 N8 清理与卸载记录完整浏览")
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_050_000)
        let cleans = (0..<700).map { i in CleanRecord(date: now.addingTimeInterval(-Double(i) * 3600), path: "/Users/me/Downloads/文件\(i).dmg", size: Int64(i * 1000), trashed: true, trashPath: "/不存在/文件\(i).dmg") }
        let uns = (0..<300).map { i in UninstallRecord(date: now.addingTimeInterval(-Double(i) * 7200 - 60), app: "应用\(i)", bundleID: "com.x.a\(i)", entries: [UninstallEntry(original: "/Applications/应用\(i).app", trashed: nil)]) }
        let t1 = Date()
        let all = RecordsHistory.entries(clean: cleans, uninstall: uns)
        let gs = RecordsHistory.groups(all, calendar: cal, now: now)
        let dt = Date().timeIntervalSince(t1)
        T.check(all.count == 1000 && Set(all.map(\.id)).count == 1000, "1000 条固定样例全部列出，标识唯一", "\(all.count)")
        T.check(zip(all, all.dropFirst()).allSatisfy { $0.date >= $1.date }, "默认时间倒序")
        T.check(gs.count > 1 && gs.allSatisfy { g in g.items.allSatisfy { cal.isDate($0.date, inSameDayAs: g.day) } } && zip(gs, gs.dropFirst()).allSatisfy { $0.day > $1.day }, "按本地日期分组，组也倒序", "\(gs.count) 组")
        T.check(all.contains { $0.name == "文件699.dmg" }, "早于摘要数量（20 条）的记录也能找到")
        T.check(dt < 1.0, "1000 条整理耗时", String(format: "%.0f ms（只记录，预算在测基线后再定）", dt * 1000))
        T.check(RecordsHistory.groups([], calendar: cal, now: now).isEmpty && RecordsHistory.entries(clean: [], uninstall: []).isEmpty, "空记录")
        T.check(RecordsHistory.dayTitle(now, calendar: cal, now: now) == "今天" && RecordsHistory.dayTitle(now.addingTimeInterval(-86400), calendar: cal, now: now) == "昨天", "今天 / 昨天")
        T.check(all.first { $0.kind == .uninstall }?.state == .gone("记录没有废纸篓位置，需手动放回") && all.first { $0.kind == .clean }?.state == .gone("废纸篓里已不在"), "不能恢复的写明原因，不给恢复按钮")
        // 真实文件：卸载恢复冲突 / 部分可恢复
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("mo-216-hist-\(getpid())"); try? fm.removeItem(at: tmp)
        try? fm.createDirectory(at: tmp.appendingPathComponent("trash"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: tmp.appendingPathComponent("orig"), withIntermediateDirectories: true)
        for n in ["a", "b"] { try? Data(n.utf8).write(to: tmp.appendingPathComponent("trash/\(n)")) }
        try? Data("占位".utf8).write(to: tmp.appendingPathComponent("orig/b"))   // b 原位置已有同名
        let ur = UninstallRecord(date: now, app: "测试", bundleID: "com.t", entries: [UninstallEntry(original: tmp.appendingPathComponent("orig/a").path, trashed: tmp.appendingPathComponent("trash/a").path),
                                                                                  UninstallEntry(original: tmp.appendingPathComponent("orig/b").path, trashed: tmp.appendingPathComponent("trash/b").path)])
        T.check(RecordsHistory.uninstallState(ur) == .partial("部分可恢复（1/2 项）"), "卸载记录：原位置有同名的项不计入可恢复")
        let mv = Uninstaller.moveBack(ur)
        T.check(mv.ok == 1 && mv.skipped == 1 && (try? String(contentsOf: tmp.appendingPathComponent("orig/b"), encoding: .utf8)) == "占位", "恢复不覆盖同名文件")
        try? fm.removeItem(at: tmp)
        // 异步恢复：执行中重复点击不会再执行
        let cs = CleanStore(); cs.records = []
        let tmp2 = fm.temporaryDirectory.appendingPathComponent("mo-216-restore-\(getpid())"); try? fm.removeItem(at: tmp2)
        try? fm.createDirectory(at: tmp2, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: tmp2.appendingPathComponent("t.txt"))
        let rec = CleanRecord(date: now, path: tmp2.appendingPathComponent("o/t.txt").path, size: 1, trashed: true, trashPath: tmp2.appendingPathComponent("t.txt").path)
        cs.records = [rec]
        var calls = 0
        cs.restoreAsync(rec) { _ in calls += 1 }; cs.restoreAsync(rec) { _ in calls += 1 }
        T.check(cs.restoringIDs.contains(rec.id), "恢复中标记该项（按钮禁用）")
        T.check(T.waitUntil(3) { calls == 1 && !cs.restoringIDs.contains(rec.id) } && cs.records.first?.restored == true && fm.fileExists(atPath: rec.path), "重复点击只执行一次，成功后原地更新为已恢复")
        try? fm.removeItem(at: tmp2)

        T.sec("2.16 N9 分区上下比例、重置与旧偏好")
        T.check(SplitRows.valid([]) && SplitRows.valid([50, 50]) && SplitRows.valid([20, 80]) && !SplitRows.valid([15, 85]) && !SplitRows.valid([60, 30]), "上下各至少 20%、合计 100%")
        T.check(SplitRows.move([50, 50], by: 5) == [55, 45] && SplitRows.move([50, 50], by: -1, snap: false) == [49, 51] && SplitRows.move([80, 20], by: 5) == [80, 20] && SplitRows.move([22, 78], by: -5) == [20, 80], "键盘步进 5%、细调 1%、不越过下限")
        T.check(SplitRows.drag(to: 0.62) == [60, 40] && SplitRows.drag(to: 0.62, snap: false) == [62, 38] && SplitRows.drag(to: 0.02) == [20, 80], "拖动吸附 5%，按住 ⌥ 不吸附，越界钳到 20%")
        T.check(SplitRows.parse("35") == .ok([35, 65]) && SplitRows.parse(" 40% ") == .ok([40, 60]), "输入框接受整数与百分号")
        if case .rejected(let w1) = SplitRows.parse("12.5"), case .rejected(let w2) = SplitRows.parse("90"), case .rejected = SplitRows.parse("abc") {
            T.check(w1.contains("整数") && w2.contains("20%–80%"), "非整数、越界拒绝并说明可用范围", w1 + " / " + w2)
        } else { T.check(false, "非法输入拒绝") }
        let area = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let z = SplitLayout.rects(weights: [1, 1], rowPercents: [[60, 40], []], in: area, gap: 8)
        T.check(z.count == 3 && z[0].minY > z[1].maxY && abs(z[0].height / (z[0].height + z[1].height) - 0.6) < 0.01 && z[2].height == 884, "60/40：上区在前且约占 60%", "\(z.map { Int($0.height) })")
        T.check(SplitLayout.rects(weights: [1, 2], rowPercents: [[50, 50], []], in: area) == SplitLayout.rects(weights: [1, 2], rows: [2, 1], in: area), "50/50 与旧的平分结果完全一致")
        let fz = SplitLayout.rects(weights: [1], rowPercents: [[70, 30]], in: CGRect(x: 0, y: 0, width: 100, height: 100), gap: 0, flipped: true)
        T.check(fz.count == 2 && fz[0].minY == 0 && fz[0].height == 70, "预览坐标（y 向下）里上区画在上面且比例正确")
        T.check(SplitNames.names(columns: [67, 33], rows: []) == ["左侧 2/3", "右侧 1/3"] && SplitNames.names(columns: [50, 50], rows: [[50, 50], []]) == ["左侧 1/2 上方", "左侧 1/2 下方", "右侧 1/2"]
                && SplitNames.names(columns: [30, 70], rows: [[], [60, 40]]) == ["左侧 30%", "右侧 70% 上方 60%", "右侧 70% 下方 40%"], "区名：空间描述，复杂比例用百分比")
        T.check(SplitNames.names(columns: [25, 25, 25, 25], rows: []) == ["左侧 1/4", "左中 1/4", "右中 1/4", "右侧 1/4"], "四栏区名不重复")
        // 偏好：旧数据迁移、写入隔离、重置作用域、非法数据
        let su = "mo.test.split216.\(getpid())"
        let sd = UserDefaults(suiteName: su)!; sd.removePersistentDomain(forName: su)
        sd.set(["A": [40, 60], "B": [50, 50]], forKey: "split.customPct"); sd.set(["A": [2, 1], "B": [1, 2]], forKey: "split.customRows"); sd.set(12, forKey: "split.gap")
        let p = SplitPrefs(sd)
        T.check(p.rowPercents("A") == [[50, 50], []] && p.rows("A") == [2, 1], "旧的上下平分迁为 50/50")
        T.check(p.setRowPercents([65, 35], column: 0, for: "A") && p.rowPercents("A") == [[65, 35], []], "设置上下比例后可读回")
        T.check((sd.dictionary(forKey: "split.customRows") as? [String: [Int]])?["A"] == [2, 1], "旧键只写 1 / 2，不写新比例")
        T.check(!p.setRowPercents([10, 90], column: 0, for: "A") && p.rowPercents("A") == [[65, 35], []], "非法比例不保存，保留最后成功值")
        T.check(p.signature("A") != nil && p.signature("A") != { () -> String? in let q = SplitPrefs(sd); _ = q; return "x" }(), "布局签名存在")
        let sigBefore = p.signature("A")
        p.resetCustom("A")
        T.check(p.custom("A") == [50, 50] && p.rows("A") == [1, 1] && p.weights("A") != nil, "恢复默认：两栏 50/50、不拆分、仍保持自定义启用")
        T.check(p.custom("B") == [50, 50] && p.rowPercents("B") == [[], [50, 50]] && Int(p.gap) == 12, "恢复默认只作用于当前屏幕，间距与其他屏幕不变")
        T.check(p.signature("A") != sigBefore, "布局变化后签名改变（旧命令不会执行旧区域）")
        // 回退旧版改过宽度：以旧版最后保存的为准
        sd.set(["A": [30, 70], "B": [50, 50]], forKey: "split.customPct")
        T.check(p.custom("A") == [30, 70] && !p.v2Invalid("A"), "回退旧版改了宽度后再升级：采用旧版最后保存的宽度")
        // 非法新数据：提示、不覆盖、不影响其他屏
        var raw = (sd.dictionary(forKey: "split.layout.v2") as? [String: Data]) ?? [:]
        raw["C"] = Data(#"{"schemaVersion":9,"displayID":"C","columnPercents":[90,5,5],"rowPercentsByColumn":[[],[],[]]}"#.utf8); sd.set(raw, forKey: "split.layout.v2")
        T.check(p.v2Invalid("C") && p.custom("C") == nil && p.custom("B") == [50, 50], "无法识别的新数据：标记出来，不当作有效布局，也不影响其他屏")
        T.check((sd.dictionary(forKey: "split.layout.v2") as? [String: Data])?["C"] != nil, "非法数据保留原样，不被静默覆盖")
        sd.removePersistentDomain(forName: su)

        T.sec("2.16 N10 底栏对象：稳定身份与执行前核对")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let key = ProcIdentity.key(pid: 4321, start: start)
        T.check(ProcIdentity.check(key, pid: 4321, name: "Chrome", start: { _ in start }) == nil, "同一进程：可以执行")
        T.check(ProcIdentity.check(key, pid: 4321, name: "Chrome", start: { _ in start.addingTimeInterval(30) })?.contains("进程号已被其他进程使用") == true, "进程号被复用：拒绝执行并说明")
        T.check(ProcIdentity.check(key, pid: 4321, name: "Chrome", start: { _ in nil })?.contains("已经退出") == true, "进程已退出：清除选择")
        let fc = FooterContext()
        var ran = 0
        fc.set(FooterObject(page: .monitor, id: "proc:1:1", name: "A", type: "进程", primary: CmdAction(title: "退出 A", run: { ran += 1 }), verify: { nil }))
        fc.runPrimary(.monitor); fc.runPrimary(.monitor)
        T.check(ran == 1 && fc.busyID == "proc:1:1", "执行中同一对象不能重复触发")
        fc.busyID = nil
        fc.set(FooterObject(page: .monitor, id: "proc:2:2", name: "B", type: "进程", primary: CmdAction(title: "退出 B", run: { ran += 10 }), verify: { "「B」已经退出，已取消选择" }))
        fc.runPrimary(.monitor)
        T.check(ran == 1 && fc.object == nil && fc.note.contains("已经退出"), "对象消失：不执行、清除选择并解释")
        fc.set(FooterObject(page: .monitor, id: "x", name: "C", type: "进程", primary: nil))
        fc.clear(page: .battery)
        T.check(fc.current(.monitor)?.id == "x" && fc.current(.battery) == nil, "切页只清本页选择，不保留上一页对象到新页")
        T.check(fc.actionItem(.monitor)?.actions.contains { $0.group == ContextActions.goGroup } == true, "⌘K：对象操作之后仍能找到页面与前往动作")
    }

    // MARK: 界面交互
    static func ui(_ w: NSWindow) {
        let root = w.contentView!
        T.sec("2.16 N4 电量提醒关闭时折叠")
        let al = BatteryAlerts.shared, keep = al.settings
        al.settings.alertsOn = false
        Nav.shared.sel = .monitor; T.settle(0.3); Nav.shared.sel = .battery
        if let tab = T.find(root, id: "bat.tab.0") { tab.press() }
        T.check(T.find(root, id: "bat.alertsOn") != nil && T.find(root, id: "bat.alerts.off") != nil, "关闭时只有总开关和一句说明")
        T.check(T.find1(root, id: "bat.low.20") == nil, "关闭时阈值等选项不在界面里（不占布局、不进焦点）")
        al.settings.alertsOn = true; T.settle(0.4)
        T.check(T.waitUntil(3) { T.find1(root, id: "bat.low.20") != nil }, "开启后展开原有选项")
        al.settings = keep; T.settle(0.2)

        T.sec("2.16 N8 改动记录页「查看全部」")
        let store = CleanStore.shared, keepRecords = store.records
        store.records = (0..<30).map { i in CleanRecord(date: Date().addingTimeInterval(-Double(i) * 86400), path: "/Users/me/示例\(i).txt", size: 10, trashed: true, trashPath: "/不存在/\(i)") }
        Nav.shared.sel = .monitor; T.settle(0.3); Nav.shared.sel = .changes
        if let all = T.find(root, id: "changes.clean.all") {
            all.press()
            T.check(T.waitUntil(3) { NSApp.windows.contains { $0.isVisible && T.find1($0.contentView ?? NSView(), id: "history.list") != nil } }, "打开完整记录视图")
            if let sheetWin = NSApp.windows.first(where: { $0.isVisible && T.find1($0.contentView ?? NSView(), id: "history.close") != nil }) {
                T.find1(sheetWin.contentView!, id: "history.close")?.press()
                T.check(T.waitUntil(3) { !sheetWin.isVisible || T.find1(sheetWin.contentView ?? NSView(), id: "history.list") == nil }, "「返回」回到改动记录页")
            }
        } else { T.check(false, "改动记录页有「查看全部」") }
        store.records = keepRecords

        T.sec("2.16 N10 底栏跟随选中对象")
        ProcActions.override = { p in .quitApp(pid: p.id, name: p.name, memMB: p.memMB) }
        defer { ProcActions.override = nil }
        Nav.shared.sel = .monitor; T.settle(0.6)
        T.check(T.find(root, id: "bottom.action.0") != nil && T.find1(root, id: "bottom.primary") == nil, "无选中对象：回退到页面主操作")
        if let row = T.find(root, id: "proc.row.0") {
            _ = row
            let first = Monitor.shared.s.top.first
            if let first {
                // 通过键盘路径选择（与鼠标走同一个 select）
                let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: Key.down)
                if let down { _ = Shell.shared.handle(down) }
                T.check(T.waitUntil(2) { FooterContext.shared.current(.monitor)?.name == first.name }, "↓ 选中第一个进程，底栏显示它的名称", FooterContext.shared.current(.monitor)?.name ?? "nil")
                T.check(T.waitUntil(2) { T.find1(root, id: "bottom.primary") != nil }, "底栏出现该进程的主操作（具体动词）")
            }
        } else { T.info("没有进程行（采样未就绪），跳过底栏选择检查") }
        Nav.shared.sel = .battery; T.settle(0.3)
        T.check(FooterContext.shared.current(.battery) == nil && T.find1(root, id: "bottom.primary") == nil, "切页后不保留上一页的对象")
        Nav.shared.sel = .monitor
    }

    // MARK: 截图
    static func snapshots(_ out: String) {
        let realBT = BTBattery.shared
        let fx = BTBattery(); fx.persist = false
        let t = Date()
        fx.devices = [BTDevice(name: "妙控鼠标", address: "m1", kind: "computermouse", connected: true, ble: false, percent: 8, source: "系统电量（IORegistry）"),
                      BTDevice(name: "妙控键盘", address: "k1", kind: "keyboard", connected: true, ble: false, percent: 18, source: "系统电量（IORegistry）"),
                      BTDevice(name: "AirPods Pro", address: "a1", kind: "airpodspro", connected: true, ble: true, percent: nil, reason: "未取得标准电量服务读数", reasonKind: .noReport),
                      BTDevice(name: "MX Master 3S", address: "x1", kind: "computermouse", connected: true, ble: true, percent: nil, reason: "未取得标准电量服务读数", reasonKind: .noReport),
                      BTDevice(name: "Keychron K3 Pro", address: "c1", kind: "keyboard", connected: true, ble: false, percent: nil, reason: "需要在系统设置里允许「输入监控」，才能读取键盘自报的电量", reasonKind: .unauthorized)]
        fx.states = ["a1": BTReadingState(lastAttemptAt: t, lastSuccessAt: t.addingTimeInterval(-240), lastPercent: 55, lastSource: "系统蓝牙信息"),
                     "x1": BTReadingState(lastAttemptAt: t, lastSuccessAt: t.addingTimeInterval(-1500), lastPercent: 40, lastSource: "蓝牙标准电量服务")]
        fx.updated = t
        BTBattery.shared = fx
        defer { BTBattery.shared = realBT }
        let realClean = CleanStore.shared.records, realUn = Uninstaller.shared.records
        CleanStore.shared.records = (0..<600).map { i in CleanRecord(date: t.addingTimeInterval(-Double(i) * 5400), path: "/Users/me/Downloads/很长的文件名称-用来检查截断-第\(i)个.dmg", size: Int64(i * 4096 + 1), trashed: true, trashPath: "/不存在/\(i)") }
        Uninstaller.shared.records = (0..<400).map { i in UninstallRecord(date: t.addingTimeInterval(-Double(i) * 9000 - 30), app: "示例应用 \(i)", bundleID: "com.example.\(i)", entries: [UninstallEntry(original: "/Applications/示例应用 \(i).app", trashed: nil)]) }
        defer { CleanStore.shared.records = realClean; Uninstaller.shared.records = realUn }
        for (mode, ap) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: ap)
            func shot<V: View>(_ v: V, _ name: String, width: CGFloat, height: CGFloat? = nil) {
                let host = NSHostingView(rootView: AnyView(v.frame(width: width, height: height).background(DS.window)))
                let size = host.fittingSize; host.frame = NSRect(origin: .zero, size: CGSize(width: width, height: height ?? size.height))
                let cw = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: host.frame.width, height: host.frame.height), styleMask: [.titled], backing: .buffered, defer: false)
                cw.appearance = NSAppearance(named: ap); cw.contentView = host; cw.orderFrontRegardless(); T.settle(1.0)
                T.contrast(host, T.pngRep(host, out + "/\(name)-\(mode).png"), "\(name) \(mode)")
                cw.orderOut(nil)
            }
            shot(BTCard(macLevel: 9, now: t).padding(20), "bt216", width: 520)
            shot(RecordsHistoryView(clean: CleanStore.shared, uninstall: Uninstaller.shared, close: {}), "history216", width: 820, height: 600)
        }
        NSApp.appearance = NSAppearance(named: .aqua)
    }
}
