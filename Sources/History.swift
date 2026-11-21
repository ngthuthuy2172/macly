import SwiftUI
import AppKit

// MARK: - Danh sách bỏ qua

enum IgnoreList {
    static let key = "ignorePaths"

    /// Hàm kiểm tra nhanh, chụp danh sách 1 lần cho mỗi lượt quét
    static func matcher() -> (URL) -> Bool {
        let ps = (UserDefaults.standard.stringArray(forKey: key) ?? []).map { ($0 as NSString).standardizingPath }
        if ps.isEmpty { return { _ in false } }
        return { u in
            let p = u.path
            return ps.contains { p == $0 || p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
    }
}

// MARK: - Lịch sử dọn dẹp

struct CleanRecord: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let module: String
    let detail: String
    let freed: Int64
}

@MainActor
final class HistoryModel: ObservableObject {
    @Published var records: [CleanRecord] = []

    private var fileURL: URL {
        let dir = FS.lib("Application Support/CCMM")
        try? FS.fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    init() {
        if let d = try? Data(contentsOf: fileURL),
           let r = try? JSONDecoder().decode([CleanRecord].self, from: d) {
            records = r
        }
    }

    var totalFreed: Int64 { records.reduce(0) { $0 + $1.freed } }

    func add(_ module: String, _ detail: String, _ freed: Int64) {
        guard freed > 0 else { return }
        records.insert(CleanRecord(date: Date(), module: module, detail: detail, freed: freed), at: 0)
        if records.count > 1000 { records = Array(records.prefix(1000)) }
        save()
        Shared.monitor.refreshDisk()
    }

    func clear() {
        records = []
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(records) { try? d.write(to: fileURL) }
    }

    /// Nhóm theo ngày, mới nhất trước
    var byDay: [(day: String, items: [CleanRecord])] {
        let f = DateFormatter()
        f.locale = Locale(identifier: Lang.localeID)
        f.dateStyle = .full
        var order: [String] = []
        var map: [String: [CleanRecord]] = [:]
        for r in records {
            let k = f.string(from: r.date)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(r)
        }
        return order.map { ($0, map[$0] ?? []) }
    }
}

struct HistoryView: View {
    @EnvironmentObject var history: HistoryModel
    @StateObject private var confirm = Box(false)

    static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Lịch sử dọn dẹp", subtitle: "Mỗi lần dọn đã giải phóng bao nhiêu dung lượng", icon: "clock.arrow.circlepath")
            GlassScroll {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Tổng đã giải phóng")).foregroundStyle(.secondary)
                        Text(L(fmt(history.totalFreed))).font(.system(size: 34, weight: .bold)).foregroundColor(Theme.selectedText).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(L("Số lần dọn")).foregroundStyle(.secondary)
                        Text(L("\(history.records.count)")).font(.system(size: 34, weight: .bold)).monospacedDigit()
                    }
                }
                .padding(20)
                .glassCard(cornerRadius: 20)

                if history.records.isEmpty {
                    Text(L("Chưa có lần dọn nào. Lịch sử sẽ hiện ở đây sau khi bạn dọn dẹp."))
                        .foregroundStyle(.secondary).padding(.top, 20)
                }
                ForEach(history.byDay, id: \.day) { group in
                    GlassSection(group.day) {
                        ForEach(group.items) { r in
                            HStack(spacing: 12) {
                                Text(L(HistoryView.timeFmt.string(from: r.date))).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 50, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L(r.module))
                                    Text(L(r.detail)).font(.uiCaption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(L(fmt(r.freed))).monospacedDigit().foregroundColor(Theme.selectedText)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            BottomBar {
                Spacer()
                Button(L("Xoá lịch sử")) { confirm.value = true }.glassButton().disabled(history.records.isEmpty)
            }
        }
        .alert(L("Xoá toàn bộ lịch sử dọn dẹp?"), isPresented: $confirm.value) {
            Button(L("Huỷ"), role: .cancel) {}
            Button(L("Xoá"), role: .destructive) { history.clear() }
        } message: {
            Text(L("Chỉ xoá nhật ký, không ảnh hưởng tới file nào."))
        }
    }
}
