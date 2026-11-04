import Foundation
import AppKit

extension MOTests {
    static func v241Tests() {
        sec("2.4.1 启动时恢复常亮与接显示器模式")
        let name = "mo-v241-" + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let a = KeepAwake(defaults: d)
        a.toggle(); check(a.on && d.bool(forKey: KeepAwake.key), "点常亮后保存开启状态")
        a.stop(); check(!a.on && d.bool(forKey: KeepAwake.key) && !KeepAwake.systemSeesAssertion(), "退出时只释放断言，保存的状态仍是开启")
        let dock = DockMode(defaults: d); dock.observe = false; dock.assertion = MockAssertion()
        dock.readPower = { true }; dock.readExternal = { true }
        dock.setEnabled(true); dock.setEnabled(false)
        d.set(true, forKey: DockMode.key)
        let b = KeepAwake(defaults: d), dock2 = DockMode(defaults: d); dock2.observe = false
        let mock = MockAssertion(); dock2.assertion = mock; dock2.readPower = { true }; dock2.readExternal = { true }
        LaunchRestore.run(keepAwake: b, dock: dock2)
        check(b.on && KeepAwake.systemSeesAssertion(), "重新启动后按保存状态重新持有常亮断言")
        settle(1.2)
        check(b.on && KeepAwake.systemSeesAssertion(), "恢复后持续持有（1 秒后仍在，不会立即释放）")
        check(dock2.active, "重新启动后按保存状态恢复接显示器模式断言")
        b.toggle(); check(!b.on && !d.bool(forKey: KeepAwake.key) && !KeepAwake.systemSeesAssertion(), "再点关闭并保存")
        let c = KeepAwake(defaults: d); LaunchRestore.run(keepAwake: c, dock: dock2)
        check(!c.on && !KeepAwake.systemSeesAssertion(), "保存为关闭时启动不创建常亮断言")
        dock2.setEnabled(false)
        let dock3 = DockMode(defaults: d); dock3.observe = false; dock3.assertion = MockAssertion(); dock3.readPower = { true }; dock3.readExternal = { true }
        LaunchRestore.run(keepAwake: c, dock: dock3)
        check(!dock3.active, "接显示器模式保存为关闭时启动不创建断言")
    }
}
