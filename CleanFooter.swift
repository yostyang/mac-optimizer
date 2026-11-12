// 2.14 清理页底栏：固定显示已选汇总和主按钮（不随清单滚走）；清理记录与恢复挪到「改动与提醒」
import SwiftUI
import AppKit

/// 底栏汇总文字（纯逻辑，便于自检）
enum CleanSummary {
    static func line(selected: Int, bytes: Int64, failures: Int) -> String {
        "已选 \(selected) 项 · 共 \(CleanLogic.fmtSize(bytes))" + (failures > 0 ? " · \(failures) 项未完成" : "")
    }
    static func button(selected: Int, failures: Int, trashing: Bool) -> String {
        trashing ? "处理中…" : (failures == 0 ? "移到废纸篓（\(selected) 项）" : "重试所选未完成项")
    }
}

struct CleanFooter: View {
    @ObservedObject var store: CleanStore
    @State private var showConfirm = false
    var body: some View {
        let picked = store.items.filter { $0.selected }
        let bytes = picked.reduce(Int64(0)) { $0 + $1.size }
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CleanSummary.line(selected: picked.count, bytes: bytes, failures: store.failures.count))
                    .font(DS.body(.semibold)).monospacedDigit().accessibilityIdentifier("clean.footer.summary")
                if !store.note.isEmpty {
                    Text(store.note).font(DS.sub()).foregroundColor(store.failures.isEmpty ? DS.text.secondary : DS.text.warn).lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("clean.result")
                }
            }
            Spacer(minLength: 8)
            if store.trashing { ProgressView().controlSize(.small) }
            Button(CleanSummary.button(selected: picked.count, failures: store.failures.count, trashing: store.trashing)) { showConfirm = true }
                .buttonStyle(PillButton()).disabled(picked.isEmpty || store.trashing || store.scanning).accessibilityIdentifier("clean.trash")
                .alert("移到废纸篓？", isPresented: $showConfirm) {
                    Button("移到废纸篓", role: .destructive) { store.trashSelected() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("只会移到废纸篓，不会直接删除，之后可以在「改动与提醒」里恢复。")
                }
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity).card()
        .background(PinnedFooterMarker().allowsHitTesting(false))
        .accessibilityElement(children: .contain).accessibilityIdentifier("clean.footer")
    }
}

/// 固定底栏的位置标记（真实 NSView，不接收点击）：截图测试据此核对长列表时底栏仍在窗口内
final class PinnedFooterMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }
}
struct PinnedFooterMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> PinnedFooterMarkerView { PinnedFooterMarkerView() }
    func updateNSView(_ v: PinnedFooterMarkerView, context: Context) {}
}

/// 「改动与提醒」里的清理记录卡：仍在废纸篓里的可以恢复
struct CleanRecordsCard: View {
    static let restoreHint = "在本页上方「清理记录」里点恢复"
    @ObservedObject var store: CleanStore
    var limit = 20
    var body: some View {
        Card(title: "清理记录", icon: "arrow.uturn.backward.circle") {
            if store.records.isEmpty {
                StateLine(kind: .empty, text: "还没有清理记录", detail: "在「清理预览」里移到废纸篓的项会出现在这里，仍在废纸篓里的可以一键恢复。", id: "changes.clean.state")
            } else {
                ForEach(Array(store.records.suffix(limit).reversed())) { r in CleanRecordRow(record: r, store: store) }
                if store.records.count > limit { Text("只显示最近 \(limit) 条，共 \(store.records.count) 条").font(DS.sub()).foregroundColor(DS.text.secondary) }
            }
            if !store.restoreNote.isEmpty {
                StateLine(kind: store.restoreNote.hasPrefix("已") ? .done : .failed, text: store.restoreNote, id: "clean.restore.state")
            }
            Text("只有还在废纸篓里的项可以恢复；原位置已有同名文件时不覆盖，会改名放回。").font(DS.sub()).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("changes.clean")
    }
}
