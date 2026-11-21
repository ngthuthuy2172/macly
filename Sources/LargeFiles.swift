import SwiftUI
import AppKit

struct LargeFile: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    let modified: Date?
    let accessed: Date?
    var lastUsed: Date? { [modified, accessed].compactMap { $0 }.max() }
}

enum LargeEngine {
    static func scan(root: URL, minSize: Int64, progress: (String) -> Void) -> [LargeFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey, .contentAccessDateKey]
        let keySet = Set(keys)
        guard let en = FS.fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                        errorHandler: { _, _ in true }) else { return [] }
        let libPath = FS.home.appendingPathComponent("Library").path
        var out: [LargeFile] = []
        var n = 0
        let ign = IgnoreList.matcher()
        for case let u as URL in en {
            if u.path == libPath || ign(u) { en.skipDescendants(); continue }
            n += 1
            if n % 3000 == 0 { progress(shortPath(u.deletingLastPathComponent())) }
            guard let v = try? u.resourceValues(forKeys: keySet), v.isRegularFile == true else { continue }
            let s = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            if s >= minSize {
                out.append(LargeFile(url: u, size: s, modified: v.contentModificationDate, accessed: v.contentAccessDate))
            }
        }
        return out.sorted { $0.size > $1.size }
    }
}

@MainActor
final class LargeModel: ObservableObject {
    @Published var files: [LargeFile] = []
    @Published var selected: Set<UUID> = []
    @Published var scanning = false
    @Published var scannedOnce = false
    @Published var status = ""
    @Published var minMB: Int = 100
    @Published var age: Int = 0
    @Published var root: URL = FS.home

    var visible: [LargeFile] {
        guard age > 0 else { return files }
        let cutoff = Date().addingTimeInterval(-Double(age) * 86400)
        return files.filter { ($0.lastUsed ?? .distantPast) < cutoff }
    }
    var selectedSize: Int64 { files.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func reset() {
        guard !scanning else { return }
        files = []
        selected = []
        scannedOnce = false
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.directoryURL = root
        p.prompt = L("Chọn")
        if p.runModal() == .OK, let u = p.url { root = u; scan() }
    }

    func scan() {
        guard !scanning else { return }
        let r = root
        let minBytes = Int64(minMB) * 1_000_000
        scanning = true
        selected = []
        status = "Đang quét…"
        Task.detached(priority: .userInitiated) {
            let res = LargeEngine.scan(root: r, minSize: minBytes) { m in
                Task { @MainActor in self.status = "Đang quét " + m }
            }
            await MainActor.run {
                self.files = res
                self.scanning = false
                self.scannedOnce = true
            }
        }
    }

    func trashSelected() {
        let targets = files.filter { selected.contains($0.id) }
        Task.detached {
            var done = Set<UUID>()
            var freed: Int64 = 0
            for f in targets where FS.trash(f.url) { done.insert(f.id); freed += f.size }
            let d = done
            let fr = freed
            await MainActor.run {
                Shared.history.add("File lớn & cũ", "\(d.count) file chuyển vào Thùng rác", fr)
                self.files.removeAll { d.contains($0.id) }
                self.selected.subtract(d)
            }
        }
    }
}

struct LargeFilesView: View {
    @EnvironmentObject var model: LargeModel
    @StateObject private var confirm = Box(false)

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "File lớn & cũ", subtitle: "Tìm những file chiếm nhiều dung lượng (bỏ qua thư mục hệ thống ~/Library)", icon: "externaldrive.fill",
                       onBack: model.scannedOnce && !model.scanning ? { model.reset() } : nil)
            HStack(spacing: 14) {
                Picker(L("Lớn hơn"), selection: $model.minMB) {
                    Text(L("50 MB")).tag(50); Text(L("100 MB")).tag(100); Text(L("500 MB")).tag(500); Text(L("1 GB")).tag(1000)
                }
                .frame(width: 190)
                Picker(L("Dùng lần cuối"), selection: $model.age) {
                    Text(L("Bất kỳ")).tag(0); Text(L("> 3 tháng")).tag(90); Text(L("> 6 tháng")).tag(180); Text(L("> 1 năm")).tag(365)
                }
                .frame(width: 230)
                Spacer()
                Button { model.chooseFolder() } label: { Label(L(model.root.lastPathComponent), systemImage: "folder") }.glassButton()
                Button(L("Quét")) { model.scan() }.glassButton(prominent: true).disabled(model.scanning)
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
            if model.scanning {
                BusyView(text: model.status)
            } else if !model.scannedOnce {
                EmptyState(icon: "externaldrive.fill", title: "Tìm file lớn", message: "Quét thư mục \(shortPath(model.root)) để tìm file lớn hơn \(model.minMB) MB.", actionTitle: "Quét ngay") { model.scan() }
            } else if model.visible.isEmpty {
                Text(L("Không tìm thấy file nào phù hợp")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GlassScroll { GlassSection { ForEach(model.visible) { f in
                    HStack(spacing: 10) {
                        Toggle(L(""), isOn: Binding(
                            get: { model.selected.contains(f.id) },
                            set: { v in if v { model.selected.insert(f.id) } else { model.selected.remove(f.id) } }
                        )).labelsHidden()
                        FileIcon(url: f.url, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L(f.url.lastPathComponent)).lineLimit(1)
                            Text(L(shortPath(f.url.deletingLastPathComponent()))).font(.uiCaption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if let d = f.lastUsed {
                            Text(L(dateFmt.string(from: d))).font(.uiCaption).foregroundStyle(.secondary)
                        }
                        Text(L(fmt(f.size))).monospacedDigit().frame(width: 90, alignment: .trailing)
                        RevealButton(url: f.url)
                    }
                    .padding(.vertical, 5)
                } } }
            }
            BottomBar {
                Text(L("Đã chọn \(model.selected.count) file · \(fmt(model.selectedSize))")).monospacedDigit()
                Spacer()
                Button(L("Bỏ chọn")) { model.selected = [] }.glassButton().disabled(model.selected.isEmpty)
                Button(L("Chuyển vào Thùng rác")) { confirm.value = true }
                    .glassButton(prominent: true)
                    .disabled(model.selected.isEmpty)
            }
        }
        .confirmationDialog(L("Chuyển \(model.selected.count) file vào Thùng rác?"), isPresented: $confirm.value) {
            Button(L("Chuyển vào Thùng rác"), role: .destructive) { model.trashSelected() }
        } message: {
            Text(L("Bạn vẫn có thể khôi phục từ Thùng rác."))
        }
    }
}
