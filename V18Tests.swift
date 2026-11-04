// v1.8 测试：白名单、保护目录、卸载残留、大小格式、大文件排序（不删真实用户文件）
import SwiftUI
import AppKit

extension MOTests {
    static func v18Tests() {
        sec("清理：保护、白名单、残留")
        let h = NSHomeDirectory()
        check(CleanLogic.isProtected(h + "/Documents/重要.docx"), "文稿默认保护")
        check(CleanLogic.isProtected("/System/Library/Fonts"), "系统目录默认保护")
        check(!CleanLogic.isProtected(h + "/Library/Caches/com.example"), "缓存不在默认保护里")
        check(CleanLogic.isWhitelisted(h + "/Library/Caches/keep", whitelist: [h + "/Library/Caches/keep"]), "白名单精确匹配")
        check(CleanLogic.isWhitelisted(h + "/Library/Caches/keep/sub", whitelist: [h + "/Library/Caches/keep"]), "白名单覆盖子路径")
        check(!CleanLogic.isWhitelisted(h + "/Library/Caches/other", whitelist: [h + "/Library/Caches/keep"]), "白名单不误伤其他路径")
        check(CleanLogic.fmtSize(500) == "500 B" && CleanLogic.fmtSize(2048) == "2 KB" && CleanLogic.fmtSize(2_097_152) == "2.0 MB", "大小格式")
        let left = CleanLogic.leftoversFor(appName: "TestApp", bundleID: "com.test.app")
        check(left.contains(h + "/Library/Caches/com.test.app") && left.contains(h + "/Library/Preferences/com.test.app.plist"), "卸载残留按 Bundle ID 推导")
        check(left == left.sorted() && Set(left).count == left.count, "残留清单去重排序")
        sec("大文件排序（临时目录，不碰用户文件）")
        let tmp = NSTemporaryDirectory() + "mo-clean-test-\(getpid())"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try? Data(repeating: 0, count: 300).write(to: URL(fileURLWithPath: tmp + "/small.bin"))
        try? Data(repeating: 0, count: 3000).write(to: URL(fileURLWithPath: tmp + "/big.bin"))
        let large = CleanLogic.largeFiles(root: tmp, minSize: 1000, maxCount: 10, isCancelled: { false })
        check(large.count == 1 && large[0].path.hasSuffix("big.bin"), "小于阈值的文件不进大文件清单", large.map(\.path).joined(separator: ","))
        let cancelled = CleanLogic.largeFiles(root: tmp, minSize: 0, maxCount: 10, isCancelled: { true })
        check(cancelled.isEmpty, "取消后立即停，不继续扫")
        try? FileManager.default.removeItem(atPath: tmp)
    }
}
