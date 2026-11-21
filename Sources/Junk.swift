import SwiftUI

enum CleanMode { case removeContents, trash, emptyTrash }

struct CleanItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    var size: Int64
    var selected: Bool = true
}

struct JunkCategory: Identifiable {
    let id: String
    let title: String
    let icon: String
    let note: String
    let mode: CleanMode
    var items: [CleanItem]
    var enabled: Bool
    var expanded: Bool = false
    var foundSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { enabled ? items.filter { $0.selected }.reduce(0) { $0 + $1.size } : 0 }
}

enum JunkEngine {
    static let cacheExclude: Set<String> = [
        "CloudKit", "com.apple.bird", "com.apple.akd", "FamilyCircle", "com.apple.HomeKit",
        "com.apple.ap.adprivacyd", "com.apple.containermanagerd", "com.loc.ccmm"
    ]

    static func items(in dir: URL, exclude: Set<String> = [], minSize: Int64 = 4096) -> [CleanItem] {
        FS.children(dir).compactMap { u -> CleanItem? in
            if exclude.contains(u.lastPathComponent) { return nil }
            let s = FS.size(of: u)
            return s >= minSize ? CleanItem(url: u, name: u.lastPathComponent, size: s) : nil
        }.sorted { $0.size > $1.size }
    }

    static func paths(_ list: [URL]) -> [CleanItem] {
        list.compactMap { u -> CleanItem? in
            guard FS.fm.fileExists(atPath: u.path) else { return nil }
            let s = FS.size(of: u)
            return s > 0 ? CleanItem(url: u, name: shortPath(u), size: s) : nil
        }.sorted { $0.size > $1.size }
    }

    static func downloads(exts: Set<String>) -> [CleanItem] {
        FS.children(FS.home.appendingPathComponent("Downloads")).compactMap { u -> CleanItem? in
            guard exts.contains(u.pathExtension.lowercased()) else { return nil }
            return CleanItem(url: u, name: u.lastPathComponent, size: FS.size(of: u))
        }.sorted { $0.size > $1.size }
    }

    static func scan(progress: (String) -> Void) -> [JunkCategory] {
        var out: [JunkCategory] = []

        progress("Đang quét bộ nhớ đệm ứng dụng…")
        out.append(JunkCategory(id: "cache", title: "Bộ nhớ đệm ứng dụng", icon: "internaldrive",
                                note: "~/Library/Caches – ứng dụng sẽ tự tạo lại khi cần",
                                mode: .removeContents, items: items(in: FS.lib("Caches"), exclude: cacheExclude), enabled: true))

        progress("Đang quét nhật ký…")
        out.append(JunkCategory(id: "logs", title: "Nhật ký & báo cáo sự cố", icon: "doc.text",
                                note: "~/Library/Logs",
                                mode: .removeContents, items: items(in: FS.lib("Logs")), enabled: true))

        progress("Đang quét rác lập trình…")
        let dev = paths([
            FS.lib("Developer/Xcode/DerivedData"),
            FS.lib("Developer/Xcode/iOS DeviceSupport"),
            FS.lib("Developer/Xcode/watchOS DeviceSupport"),
            FS.lib("Developer/Xcode/macOS DeviceSupport"),
            FS.lib("Developer/CoreSimulator/Caches"),
            FS.home.appendingPathComponent(".npm/_cacache"),
            FS.home.appendingPathComponent(".gradle/caches")
        ])
        out.append(JunkCategory(id: "dev", title: "Rác lập trình", icon: "hammer",
                                note: "Xcode DerivedData, DeviceSupport, bộ đệm npm/gradle",
                                mode: .removeContents, items: dev, enabled: true))

        progress("Đang quét tệp đính kèm Mail…")
        out.append(JunkCategory(id: "mail", title: "Tệp đính kèm Mail đã tải", icon: "envelope",
                                note: "Bản sao tệp đính kèm đã mở trong Mail (thư gốc vẫn còn)",
                                mode: .removeContents,
                                items: paths([FS.lib("Containers/com.apple.mail/Data/Library/Mail Downloads")]), enabled: true))

        progress("Đang quét thư mục Tải về…")
        out.append(JunkCategory(id: "partial", title: "Tệp tải dở", icon: "arrow.down.circle",
                                note: "File tải xuống chưa hoàn tất trong Tải về",
                                mode: .trash, items: downloads(exts: ["crdownload", "part", "download", "partial", "opdownload"]), enabled: true))
        out.append(JunkCategory(id: "installers", title: "Bộ cài đặt cũ", icon: "shippingbox",
                                note: "File .dmg/.pkg trong Tải về – chuyển vào Thùng rác",
                                mode: .trash, items: downloads(exts: ["dmg", "pkg", "mpkg", "xip"]), enabled: false))

        progress("Đang quét Thùng rác…")
        let trashURL = FS.home.appendingPathComponent(".Trash")
        let tsize = FS.size(of: trashURL)
        let note = (tsize == 0 && !Permissions.hasFullDiskAccess)
            ? "Cấp quyền Truy cập toàn bộ ổ đĩa để đo dung lượng"
            : "Xoá vĩnh viễn mọi thứ trong Thùng rác"
        out.append(JunkCategory(id: "trash", title: "Thùng rác", icon: "trash", note: note, mode: .emptyTrash,
                                items: [CleanItem(url: trashURL, name: "Thùng rác", size: tsize)], enabled: true))
        let ign = IgnoreList.matcher()
        return out.map { c in
            var c2 = c
            c2.items = c.items.filter { !ign($0.url) }
            return c2
        }
    }
}

@MainActor
final class JunkScanner: ObservableObject {
    @Published var categories: [JunkCategory] = []
    @Published var scanning = false
    @Published var cleaning = false
    @Published var scannedOnce = false
    @Published var status = ""
    @Published var lastFreed: Int64? = nil

    var totalSelected: Int64 { categories.reduce(0) { $0 + $1.selectedSize } }
    var totalFound: Int64 { categories.reduce(0) { $0 + $1.foundSize } }

    func reset() {
        guard !scanning, !cleaning else { return }
        categories = []
        scannedOnce = false
        lastFreed = nil
    }

    func scan() {
        guard !scanning, !cleaning else { return }
        scanning = true
        status = "Đang quét…"
        Task.detached(priority: .userInitiated) {
            let cats = JunkEngine.scan { msg in
                Task { @MainActor in self.status = msg }
            }
            await MainActor.run {
                self.categories = cats
                self.scanning = false
                self.scannedOnce = true
            }
        }
    }

    func clean() {
        guard !cleaning, !scanning else { return }
        let cats = categories.filter { $0.enabled }
        cleaning = true
        status = "Đang dọn dẹp…"
        Task.detached(priority: .userInitiated) {
            var freed: Int64 = 0
            var needFinder = false
            for cat in cats {
                for item in cat.items where item.selected {
                    switch cat.mode {
                    case .removeContents:
                        FS.removeContents(item.url)
                        freed += max(0, item.size - FS.size(of: item.url))
                    case .trash:
                        if FS.trash(item.url) { freed += item.size }
                    case .emptyTrash:
                        FS.removeContents(item.url)
                        let left = FS.size(of: item.url)
                        freed += max(0, item.size - left)
                        if left > 0 || !Permissions.hasFullDiskAccess { needFinder = true }
                    }
                }
            }
            let total = freed
            let finder = needFinder
            await MainActor.run {
                if finder { Shell.appleScript("tell application \"Finder\" to empty trash") }
                self.lastFreed = total
                Shared.history.add("Rác hệ thống", cats.map { $0.title }.joined(separator: ", "), total)
                self.cleaning = false
                self.scan()
            }
        }
    }
}

struct JunkView: View {
    @EnvironmentObject var junk: JunkScanner
    @StateObject private var confirm = Box(false)

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Rác hệ thống", subtitle: "Bộ nhớ đệm, nhật ký, rác lập trình, tệp tải dở và Thùng rác", icon: "trash.fill",
                       onBack: junk.scannedOnce && !junk.scanning && !junk.cleaning ? { junk.reset() } : nil)
            if junk.scanning || junk.cleaning {
                BusyView(text: junk.status)
            } else if !junk.scannedOnce {
                EmptyState(icon: "sparkles", title: "Chưa quét", message: "Quét để tìm các tệp rác an toàn để xoá.", actionTitle: "Quét ngay") { junk.scan() }
            } else {
                GlassScroll {
                    ForEach($junk.categories) { $cat in
                        GlassSection {
                        DisclosureGroup(isExpanded: $cat.expanded) {
                            if cat.items.isEmpty {
                                Text(L("Không có gì để dọn")).foregroundStyle(.secondary)
                            }
                            ForEach($cat.items) { $item in
                                HStack {
                                    Toggle(L(""), isOn: $item.selected).labelsHidden()
                                    Text(L(item.name)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(L(fmt(item.size))).foregroundStyle(.secondary).monospacedDigit()
                                    RevealButton(url: item.url)
                                }
                                .padding(.vertical, 3)
                                .disabled(!cat.enabled)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Toggle(L(""), isOn: $cat.enabled).labelsHidden()
                                Image(systemName: cat.icon).frame(width: 22).foregroundColor(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L(cat.title)).bold()
                                    Text(L(cat.note)).font(.uiCaption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(L(fmt(cat.enabled ? cat.selectedSize : cat.foundSize)))
                                    .bold().monospacedDigit()
                                    .foregroundColor(cat.enabled ? .primary : .secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        }
                    }
                }
            }
            BottomBar {
                if let f = junk.lastFreed {
                    Label(L("Đã giải phóng \(fmt(f))"), systemImage: "checkmark.seal.fill").foregroundColor(.green)
                }
                Spacer()
                Text(L("Đã chọn: \(fmt(junk.totalSelected))")).monospacedDigit()
                Button(L("Quét lại")) { junk.scan() }.glassButton().disabled(junk.scanning || junk.cleaning)
                Button(L("Dọn dẹp")) { confirm.value = true }
                    .glassButton(prominent: true)
                    .disabled(junk.totalSelected == 0 || junk.scanning || junk.cleaning)
            }
        }
        .confirmationDialog(L("Dọn \(fmt(junk.totalSelected)) rác?"), isPresented: $confirm.value) {
            Button(L("Dọn dẹp"), role: .destructive) { junk.clean() }
        } message: {
            Text(L("Bộ nhớ đệm và nhật ký sẽ bị xoá vĩnh viễn (ứng dụng tự tạo lại). Tệp tải dở/bộ cài đặt được chuyển vào Thùng rác."))
        }
    }
}
