import Foundation
import AppKit
import SwiftUI
import Security
import ServiceManagement

final class MockSMC: SMCIO {
    var keys: [String: [UInt8]]
    var failing: Set<String> = []
    var writes: [(String, [UInt8])] = []
    init(_ k: [String: [UInt8]]) { keys = k }
    func read(_ k: String) -> [UInt8]? { guard let v = keys[k], !v.isEmpty else { return nil }; return v }
    func write(_ k: String, _ b: [UInt8]) -> Bool {
        writes.append((k, b))
        guard !failing.contains(k), let v = keys[k], v.count == b.count else { return false }
        keys[k] = b; return true
    }
    static func legacy() -> MockSMC { MockSMC(["CHTE": [0, 0, 0, 0], "CHIE": [0], "ACLC": [0]]) }
    static func tahoe27() -> MockSMC { MockSMC(["CHIE": [0], "ACLC": [0], "CHTE": []]) }   // CHTE 为 0 字节占位
}

extension MOTests {
    static func chargeTests() {
        sec("充电控制：能力检测")
        let real = ChargeCaps.detect(RealSMC())
        info("本机 SMC 充电键：\(real.keys.joined(separator: ", "))；模式：\(real.inhibit != .none ? "停充键 \(real.inhibit.rawValue)" : (real.adapter ? "断开电源（CHIE）" : "不支持"))")
        check(RealSMC().read("BUIC") != nil || RealSMC().read("CHIE") != nil || !real.any, "普通权限可读取 SMC 充电键")
        let lc = ChargeCaps.detect(MockSMC.legacy()); check(lc.inhibit == .chte && lc.adapter && lc.led && !lc.adapterMode, "旧固件：CHTE+CHIE+ACLC")
        let tc = ChargeCaps.detect(MockSMC.tahoe27()); check(tc.inhibit == .none && tc.adapterMode && tc.led, "macOS 27 固件：0 字节 CHTE 视为不存在，改用 CHIE")
        let oc = ChargeCaps.detect(MockSMC(["CH0B": [0], "CH0C": [0]])); check(oc.inhibit == .ch0bc && !oc.adapter, "更旧固件：CH0B/CH0C")
        check(!ChargeCaps.detect(MockSMC([:])).any, "没有任何键 → 不提供控制")

        sec("充电控制：停充键模式（滞回/航行）")
        var m = MockSMC.legacy(); var c = ChargeController(io: m, settings: ChargeSettings(enabled: true, limit: 80, sail: 5, autoDischarge: true, led: true))
        c.evaluate(level: 70, plugged: true); check(!c.inhibited && m.keys["CHTE"] == [0, 0, 0, 0] && m.keys["ACLC"] == [4], "低于上限：充电，橙灯")
        c.evaluate(level: 80, plugged: true); check(c.inhibited && m.keys["CHTE"] == [1, 0, 0, 0] && m.keys["ACLC"] == [3], "到上限：暂停充电，绿灯")
        c.evaluate(level: 77, plugged: true); check(c.inhibited, "航行区间内保持暂停")
        c.evaluate(level: 75, plugged: true); check(!c.inhibited && m.keys["CHTE"] == [0, 0, 0, 0], "降到下沿恢复充电")
        c.evaluate(level: 90, plugged: true); check(c.inhibited && c.adapterCut && m.keys["CHIE"] == [8], "高于上限：自动放电")
        c.evaluate(level: 80, plugged: false); check(!c.adapterCut && c.inhibited && m.keys["CHIE"] == [0], "放到上限后接通电源")
        c.settings.autoDischarge = false; c.evaluate(level: 90, plugged: true); check(!c.adapterCut, "关闭自动放电则不断开电源")
        let wc = m.writes.count; c.evaluate(level: 90, plugged: true); check(m.writes.count == wc, "状态没变时不重复写 SMC")

        sec("充电控制：断开电源模式（macOS 27）")
        m = MockSMC.tahoe27(); c = ChargeController(io: m, settings: ChargeSettings(enabled: true, limit: 80, sail: 5))
        var clk = Date(timeIntervalSince1970: 3_000_000); c.now = { clk }
        c.evaluate(level: 79, plugged: true); check(!c.adapterCut, "未到上限：正常充电")
        c.evaluate(level: 80, plugged: true); check(c.adapterCut && m.keys["CHIE"] == [8] && m.keys["ACLC"] == [3], "到上限：断开电源，绿灯")
        c.evaluate(level: 77, plugged: false); check(c.adapterCut, "断开后系统报告未接电源，不误判为拔线")
        c.evaluate(level: 75, plugged: false); check(!c.adapterCut && m.keys["CHIE"] == [0], "降到下沿接通电源")
        clk = clk.addingTimeInterval(ChargeConst.adapterHold + 1)
        c.evaluate(level: 80, plugged: true); check(c.adapterCut, "回升后再次切断")
        c.willSleep(); check(!c.adapterCut && m.keys["CHIE"] == [0], "睡眠前恢复供电")
        c.evaluate(level: 80, plugged: true); check(c.adapterCut, "唤醒后重新应用")
        c.settings.sail = 0; clk = clk.addingTimeInterval(ChargeConst.adapterHold + 1)
        c.evaluate(level: 70, plugged: false); check(!c.adapterCut, "航行 0 时下沿为上限−1")

        sec("充电控制：一键充满")
        c.settings.sail = 5; c.evaluate(level: 80, plugged: true); c.setTopUp(true); c.evaluate(level: 80, plugged: true)
        check(!c.adapterCut && m.keys["CHIE"] == [0] && m.keys["ACLC"] == [4], "临时充满：接通电源，橙灯")
        c.evaluate(level: 100, plugged: true); check(!c.topUp && c.adapterCut, "充满后自动恢复上限")
        c.evaluate(level: 75, plugged: true); c.setTopUp(true); c.evaluate(level: 85, plugged: true); c.evaluate(level: 85, plugged: false)
        check(!c.topUp, "拔掉电源后结束临时充满")

        sec("充电控制：调高上限立即恢复")
        m = MockSMC.tahoe27(); c = ChargeController(io: m, settings: ChargeSettings(enabled: true, limit: 80, sail: 5))
        c.evaluate(level: 85, plugged: true); check(c.adapterCut, "85% 高于上限 80%：断开")
        c.evaluate(level: 84, plugged: false); check(c.adapterCut, "航行区间内保持断开")
        c.settings.limit = 85; c.evaluate(level: 84, plugged: false); check(!c.adapterCut && m.keys["CHIE"] == [0], "上限调到 85%（高于 84%）：立即接通")
        c.evaluate(level: 84, plugged: true); check(!c.adapterCut, "之后正常充电")
        m = MockSMC.legacy(); c = ChargeController(io: m, settings: ChargeSettings(enabled: true, limit: 80, sail: 5))
        c.evaluate(level: 80, plugged: true); c.evaluate(level: 78, plugged: true); check(c.inhibited, "停充键模式：航行区间保持暂停")
        c.settings.limit = 90; c.evaluate(level: 78, plugged: true); check(!c.inhibited && m.keys["CHTE"] == [0, 0, 0, 0], "停充键模式：调高上限立即恢复充电")
        c.settings.limit = 70; c.evaluate(level: 78, plugged: true); check(c.inhibited, "调低上限到电量以下：暂停")

        sec("充电控制：外接显示器自动暂停")
        m = MockSMC.tahoe27(); c = ChargeController(io: m, settings: ChargeSettings(enabled: true, limit: 80, sail: 5))
        var dclk = Date(timeIntervalSince1970: 5_000_000); c.now = { dclk }
        var disp = true
        let svcD = ChargeService(ctl: c, reader: { (90, true, false) }, persist: { _ in }); svcD.display = { disp }
        svcD.tick(); check(!c.adapterCut && m.writes.filter { $0.0 == "CHIE" && $0.1 == [8] }.isEmpty && c.status.displayPaused == true && c.status.externalDisplay == true, "接着外接屏：高于上限也不切断")
        for _ in 0..<50 { dclk = dclk.addingTimeInterval(61); svcD.tick() }
        check(m.writes.filter { $0.0 == "CHIE" && $0.1 == [8] }.isEmpty, "外接屏期间 50 次判断从不写 CHIE=8")
        disp = false; svcD.tick(); check(!c.adapterCut && c.status.displayPaused == true && c.status.externalDisplay == false, "刚拔掉：防抖期内仍不切断")
        dclk = dclk.addingTimeInterval(ChargeConst.displayDebounce - 1); svcD.tick(); check(!c.adapterCut, "拔掉 9 秒：仍不切断")
        dclk = dclk.addingTimeInterval(2); svcD.tick(); check(c.adapterCut && m.keys["CHIE"] == [8] && c.status.displayPaused == false, "拔掉超过 10 秒：恢复上限")
        disp = true; svcD.tick(); check(!c.adapterCut && m.keys["CHIE"] == [0], "断开期间接上外接屏：立即接通")
        disp = false; svcD.tick(); dclk = dclk.addingTimeInterval(3); disp = true; svcD.tick(); dclk = dclk.addingTimeInterval(3); disp = false; svcD.tick()
        dclk = dclk.addingTimeInterval(5); svcD.tick(); check(!c.adapterCut, "反复插拔：以最后一次变化重新计时")
        dclk = dclk.addingTimeInterval(6); svcD.tick(); check(c.adapterCut, "稳定 10 秒后才恢复")
        disp = true; svcD.tick(); c.willSleep(); check(!c.adapterCut, "暂停 + 睡眠：保持接通")
        c.evaluate(level: 15, plugged: true); check(!c.adapterCut, "暂停 + 低电量兜底")
        // 停充键模式：外接屏只禁止自动放电（切电），停充照常
        m = MockSMC.legacy(); c = ChargeController(io: m, settings: ChargeSettings(enabled: true, limit: 80, sail: 5)); c.setExternalDisplay(true)
        c.evaluate(level: 90, plugged: true); check(c.inhibited && !c.adapterCut && m.keys["CHIE"] == [0], "停充键模式 + 外接屏：停充但不自动放电")
        // 随机：外接屏期间绝不切断
        var dbad = 0
        let mr = MockSMC.tahoe27(); let cr = ChargeController(io: mr, settings: ChargeSettings(enabled: true, limit: 80, sail: 5))
        var rclk = Date(timeIntervalSince1970: 6_000_000); cr.now = { rclk }
        for i in 0..<5000 {
            rclk = rclk.addingTimeInterval(Double.random(in: 1...30))
            if i % 37 == 0 { cr.setExternalDisplay(Bool.random()) }
            if i % 97 == 0 { cr.settings.limit = [60, 70, 80, 90].randomElement()! }
            let w0 = mr.writes.count
            cr.evaluate(level: Int.random(in: 30...100), plugged: Bool.random())
            if cr.displayPaused && (mr.keys["CHIE"] == [8] || mr.writes[w0...].contains { $0.0 == "CHIE" && $0.1 == [8] }) { dbad += 1 }
        }
        check(dbad == 0, "随机 5000 步：外接屏/防抖期间从不切断电源", "违规 \(dbad) 次")
        sec("充电控制：外接显示器检测（只读）")
        info("本机外接显示器：\(DisplayProbe.externalCount()) 台（DCPAVServiceProxy Location=External）")

        sec("充电控制：安全兜底")
        m = MockSMC.legacy(); c = ChargeController(io: m, settings: ChargeSettings(enabled: true, limit: 80, sail: 5))
        c.evaluate(level: 85, plugged: true); c.evaluate(level: nil, plugged: true)
        check(!c.inhibited && !c.adapterCut && m.keys["CHTE"] == [0, 0, 0, 0] && m.keys["CHIE"] == [0] && !c.lastError.isEmpty, "读不到电量：恢复默认")
        c.evaluate(level: 85, plugged: true); c.settings.enabled = false; c.evaluate(level: 85, plugged: true)
        check(!c.inhibited && !c.adapterCut && m.keys["ACLC"] == [0], "关闭开关：恢复默认，灯交还系统")
        c.settings = ChargeSettings(enabled: true, limit: 100); c.evaluate(level: 100, plugged: true); check(!c.inhibited && !c.adapterCut, "上限 100% 不做任何限制")
        c.settings = ChargeSettings(enabled: true, limit: 50, sail: 10); c.evaluate(level: 60, plugged: true); check(c.inhibited, "上限 50% 生效")
        c.evaluate(level: ChargeConst.hardFloor, plugged: true); check(!c.inhibited && !c.adapterCut, "低于 \(ChargeConst.hardFloor)% 无条件恢复")
        c.evaluate(level: 85, plugged: true); c.resetDefaults()
        check(c.settings == ChargeSettings() && m.keys["CHTE"] == [0, 0, 0, 0] && m.keys["CHIE"] == [0] && m.keys["ACLC"] == [0], "恢复默认：允许充电、接通电源、灯交还系统")
        // 写入失败
        m = MockSMC.legacy(); c = ChargeController(io: m, settings: ChargeSettings(enabled: true, limit: 80, sail: 5))
        m.failing = ["CHTE"]; c.evaluate(level: 85, plugged: true); check(!c.inhibited && !c.lastError.isEmpty, "停充写入失败：不记为已暂停并报错")
        m.failing = []; c.evaluate(level: 90, plugged: true); m.failing = ["CHIE"]; let n0 = m.writes.filter { $0.0 == "CHIE" }.count
        c.release(); check(m.writes.filter { $0.0 == "CHIE" }.count - n0 == 2, "恢复失败时会重试")
        m.failing = ["ACLC"]; c.evaluate(level: 70, plugged: true); check(c.status.ledWritable == false, "灯写入被拒（固件限制）时记录为不可用")
        // 随机序列：电量在下沿及以下时绝不保持停充/断电
        var bad = 0
        for mode in 0..<2 {
            let mm = mode == 0 ? MockSMC.legacy() : MockSMC.tahoe27()
            let cc = ChargeController(io: mm, settings: ChargeSettings(enabled: true, limit: 80, sail: 5))
            var lv = 60
            for i in 0..<5000 {
                lv = max(0, min(100, lv + Int.random(in: -3...3)))
                if i % 97 == 0 { cc.settings.limit = [50, 60, 70, 80, 90, 100].randomElement()!; cc.settings.sail = Int.random(in: 0...10) }
                if i % 211 == 0 { cc.setTopUp(Bool.random()) }
                if i % 157 == 0 { cc.willSleep() }
                cc.evaluate(level: lv, plugged: Bool.random())
                let held = (mm.keys["CHTE"].map { $0.first == 1 } ?? false) || mm.keys["CHIE"] == [8]
                if held && (lv <= cc.lower || lv <= ChargeConst.hardFloor) { bad += 1 }
            }
        }
        check(bad == 0, "随机 10000 步：低于下沿从不停充/断电", "违规 \(bad) 次")

        sec("充电控制：CHIE 防抖（保护 USB-C 显示器）")
        m = MockSMC.tahoe27(); c = ChargeController(io: m, settings: ChargeSettings(enabled: true, limit: 80, sail: 5))
        var clock = Date(timeIntervalSince1970: 2_000_000); c.now = { clock }
        c.evaluate(level: 85, plugged: true)
        check(c.adapterCut && m.keys["CHIE"] == [8], "首次到上限切断")
        c.evaluate(level: 70, plugged: false)
        check(!c.adapterCut && m.keys["CHIE"] == [0], "降到下沿立即接通")
        // 航行恢复后短时间内再次冲到上限：防抖，不立刻切断
        let before = m.writes.filter { $0.0 == "CHIE" }.count
        c.evaluate(level: 85, plugged: true)
        check(!c.adapterCut && m.writes.filter { $0.0 == "CHIE" }.count == before, "45 秒内航行回升不重复切断")
        clock = clock.addingTimeInterval(ChargeConst.adapterHold + 1)
        c.evaluate(level: 85, plugged: true)
        check(c.adapterCut && m.keys["CHIE"] == [8], "间隔过后允许切断")
        c.willSleep()
        check(!c.adapterCut, "睡眠强制接通")
        c.evaluate(level: 85, plugged: true)
        check(c.adapterCut, "唤醒后立即重新切断（forceNextCut）")
        c.setTopUp(true); c.evaluate(level: 85, plugged: true)
        check(!c.adapterCut, "临时充满接通")
        c.setTopUp(false); c.evaluate(level: 85, plugged: true)
        check(c.adapterCut, "取消充满后立即恢复切断")

                let enc = try? JSONEncoder().encode(ChargeSettings(enabled: true, limit: 70, sail: 3, autoDischarge: false, led: false))
        check(enc.flatMap { try? JSONDecoder().decode(ChargeSettings.self, from: $0) } == ChargeSettings(enabled: true, limit: 70, sail: 3, autoDischarge: false, led: false), "设置可持久化")
        check(ChargeSettings().enabled == false && ChargeSettings().limit == 80, "默认关闭，默认上限 80%")

        sec("充电助手：XPC 白名单与客户端校验")
        var cnt: UInt32 = 0
        var sels = Set<String>()
        for req in [true, false] {
            if let l = protocol_copyMethodDescriptionList(ChargeHelperProtocol.self, req, true, &cnt) {
                for i in 0..<Int(cnt) { if let n = l[i].name { sels.insert(NSStringFromSelector(n)) } }; free(l)
            }
        }
        check(sels == ChargeValidate.allowedSelectors, "协议只有 7 个白名单方法", sels.sorted().joined(separator: " "))
        xpcTests()
        sec("充电助手：打包与签名")
        helperBundleTests()
    }

    static func xpcTests() {
        func run(_ requirement: String?, _ body: (ChargeHelperProtocol, inout Bool) -> Void) -> (MockSMC, ChargeService, Bool) {
            let mm = MockSMC.legacy()
            let svc = ChargeService(ctl: ChargeController(io: mm), reader: { (85, true, false) }, persist: { _ in })
            svc.requirement = requirement
            let l = NSXPCListener.anonymous(); l.delegate = svc; l.resume()
            let conn = NSXPCConnection(listenerEndpoint: l.endpoint)
            conn.remoteObjectInterface = NSXPCInterface(with: ChargeHelperProtocol.self); conn.resume()
            var failed = false
            let p = conn.remoteObjectProxyWithErrorHandler { _ in failed = true } as! ChargeHelperProtocol
            body(p, &failed)
            conn.invalidate(); l.invalidate()
            return (mm, svc, failed)
        }
        // 1. 匹配的签名（测试进程就是用固定证书签名的 App 本身）
        var r: [String: Any] = [:]
        let (mm, svc, f1) = run(ChargeConst.clientRequirement) { p, _ in
            p.setLimit(80, enabled: true) { ok, _ in r["a"] = ok }
            p.setLimit(30, enabled: true) { ok, _ in r["b"] = ok }
            p.setLimit(101, enabled: true) { ok, _ in r["b2"] = ok }
            p.setSailing(20) { ok, _ in r["c"] = ok }
            p.setSailing(-1) { ok, _ in r["c2"] = ok }
            p.status { d in r["d"] = try? JSONDecoder().decode(ChargeStatus.self, from: d) }
            _ = waitUntil(5) { r.count == 6 }
        }
        check(!f1 && r["a"] as? Bool == true, "同证书客户端可调用", "\(ChargeConst.clientRequirement)")
        check(r["b"] as? Bool == false && r["b2"] as? Bool == false && r["c"] as? Bool == false && r["c2"] as? Bool == false, "越界参数被拒绝（上限 30/101、航行 20/-1）")
        check(svc.ctl.settings.limit == 80 && svc.ctl.inhibited && mm.keys["CHTE"] == [1, 0, 0, 0], "合法调用生效并立即判断")
        check((r["d"] as? ChargeStatus)?.settings.enabled == true, "状态可读取")
        // 2. 签名要求不匹配 → 连接被拒，状态不变
        var got = false
        let (m2, s2, f2) = run("identifier \"com.example.evil\" and anchor apple generic") { p, failed in
            p.setLimit(60, enabled: true) { _, _ in got = true }
            _ = waitUntil(3) { failed || got }
        }
        check(f2 && !got && s2.ctl.settings.enabled == false && m2.writes.isEmpty, "签名不符的客户端被拒绝，没有任何写入")
        // 3. 没有设置要求 → 一律拒绝
        var got3 = false
        let (_, s3, f3) = run(nil) { p, failed in p.setTopUp(true) { _, _ in got3 = true }; _ = waitUntil(3) { failed || got3 } }
        check(f3 && !got3 && !s3.ctl.topUp, "未配置签名要求时拒绝所有连接")
    }

    static func helperBundleTests() {
        let b = Bundle.main.bundleURL
        let helper = b.appendingPathComponent("Contents/MacOS/MacOptimizerChargeHelper")
        let plist = b.appendingPathComponent("Contents/Library/LaunchDaemons/\(ChargeConst.plistName)")
        check(FileManager.default.isExecutableFile(atPath: helper.path), "助手可执行文件在包内")
        let d = NSDictionary(contentsOf: plist) as? [String: Any]
        check(d?["Label"] as? String == ChargeConst.label && d?["BundleProgram"] as? String == "Contents/MacOS/MacOptimizerChargeHelper" && (d?["MachServices"] as? [String: Bool])?[ChargeConst.label] == true, "launchd plist 正确", plist.lastPathComponent)
        check((d?["AssociatedBundleIdentifiers"] as? [String]) == [ChargeConst.appID] && d?["ProgramArguments"] == nil, "plist 关联 App，无额外参数")
        func valid(_ url: URL, _ req: String) -> Bool {
            var code: SecStaticCode?; var r: SecRequirement?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecRequirementCreateWithString(req as CFString, [], &r) == errSecSuccess, let r else { return false }
            return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), r) == errSecSuccess
        }
        check(valid(helper, "identifier \"\(ChargeConst.label)\" and certificate leaf = H\"\(ChargeConst.certLeaf)\""), "助手用固定证书签名（升级后授权保持）")
        check(valid(b, ChargeConst.clientRequirement), "App 满足助手的客户端要求")
        check(!valid(helper, ChargeConst.clientRequirement), "助手标识与 App 不同")
        var code: SecStaticCode?; var info: CFDictionary?
        SecStaticCodeCreateWithPath(helper as CFURL, [], &code)
        if let code { SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) }
        let flags = ((info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        check(flags & 0x10000 != 0, "助手启用强化运行时", String(format: "flags 0x%x", flags))
        let bin = (try? Data(contentsOf: helper)) ?? Data()
        // v1.5 起助手要调用 networksetup 改 DNS：只允许固定的 4 个系统命令，不含任何 shell
        let banned = ["/bin/sh", "/bin/bash", "/bin/zsh", "system\0", "dlopen", "osascript"]
        let found = banned.filter { bin.range(of: Data($0.utf8)) != nil }
        check(!bin.isEmpty && found.isEmpty, "助手不含 shell / 任意命令能力", found.isEmpty ? "\(bin.count / 1024) KB" : found.joined(separator: ","))
        let allowed = ["/usr/sbin/networksetup", "/usr/sbin/ipconfig", "/usr/bin/dscacheutil", "/usr/bin/killall"]
        check(allowed.allSatisfy { bin.range(of: Data($0.utf8)) != nil }, "助手只含固定的系统命令路径")
    }

    static func chargeFixture() -> ChargeClient {
        let c = ChargeClient(caps: ChargeCaps(inhibit: .none, adapter: true, led: true, keys: ["CHIE", "ACLC"]))
        c.offline = true; c.phase = .ready
        c.st = ChargeStatus(settings: ChargeSettings(enabled: true, limit: 80, sail: 5, autoDischarge: true, led: true), caps: c.localCaps, topUp: false, inhibited: false, adapterCut: true, level: 80, plugged: true)
        return c
    }
}
