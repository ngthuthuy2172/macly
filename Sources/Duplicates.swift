import SwiftUI
import AppKit
import CryptoKit

struct DupFile: Identifiable {
    let id = UUID()
    let url: URL
    let modified: Date
}

struct DupGroup: Identifiable {
    let id = UUID()
    let size: Int64
    let files: [DupFile]
}

enum DupEngine {
    static func hash(_ url: URL, limit: Int?) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let chunk: Data = autoreleasepool { h.readData(ofLength: Swift.min(1 << 20, remaining)) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func scan(root: URL, minSize: Int64, progress: (String) -> Void) -> [DupGroup] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)
        guard let en = FS.fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                        errorHandler: { _, _ in true }) else { return [] }
        let libPath = FS.home.appendingPathComponent("Library").path
        var bySize: [Int64: [(URL, Date)]] = [:]
        var n = 0
        let ign = IgnoreList.matcher()
        for case let u as URL in en {
            if u.path == libPath || ign(u) { en.skipDescendants(); continue }
            guard let v = try? u.resourceValues(forKeys: keySet), v.isRegularFile == true,
                  let s = v.fileSize, Int64(s) >= minSize else { continue }
            n += 1
            if n % 2000 == 0 { progress("Đã đọc \(n) file…") }
            bySize[Int64(s), default: []].append((u, v.contentModificationDate ?? .distantPast))
        }
        let candidates = bySize.filter { $0.value.count > 1 }
        var groups: [DupGroup] = []
        var i = 0
        for (size, list) in candidates {
            i += 1
            if i % 20 == 0 { progress("Đang so sánh nội dung \(i)/\(candidates.count)…") }
            var byPartial: [String: [(URL, Date)]] = [:]
            for f in list {
                if let h = hash(f.0, limit: 65536) { byPartial[h, default: []].append(f) }
            }
            for (_, pl) in byPartial where pl.count > 1 {
                var byFull: [String: [(URL, Date)]] = [:]
                if size <= 65536 {
                    byFull["same"] = pl
                } else {
                    for f in pl {
                        if let h = hash(f.0, limit: nil) { byFull[h, default: []].append(f) }
                    }
                }
                for (_, fl) in byFull where fl.count > 1 {
                    let files = fl.sorted { $0.1 < $1.1 }.map { DupFile(url: $0.0, modified: $0.1) }
                    groups.append(DupGroup(size: size, files: files))
                }
            }
        }
        return groups.sorted { $0.size * Int64($0.files.count - 1) > $1.size * Int64($1.files.count - 1) }
    }
}

@MainActor
final class DupModel: ObservableObject {
    @Published var groups: [DupGroup] = []
    @Published var selected: Set<UUID> = []
    @Published var scanning = false
    @Published var scannedOnce = false
    @Published var status = ""
    @Published var root: URL = FS.home.appendingPathComponent("Downloads")

    var selectedSize: Int64 {
        var t: Int64 = 0
        for g in groups { for f in g.files where selected.contains(f.id) { t += g.size } }
        return t
    }
    var wasted: Int64 { groups.reduce(0) { $0 + $1.size * Int64($1.files.count - 1) } }

    func reset() {
        guard !scanning else { return }
        groups = []
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
        scanning = true
        status = "Đang quét…"
        selected = []
        Task.detached(priority: .userInitiated) {
            let res = DupEngine.scan(root: r, minSize: 1024) { m in
                Task { @MainActor in self.status = m }
            }
            await MainActor.run {
                self.groups = res
                self.scanning = false
                self.scannedOnce = true
                self.autoSelect()
            }
        }
    }

    /// Giữ lại bản cũ nhất, chọn các bản còn lại
    func autoSelect() {
        var s = Set<UUID>()
        for g in groups { for f in g.files.dropFirst() { s.insert(f.id) } }
        selected = s
    }

    func trashSelected() {
        let targets = groups.flatMap { $0.files }.filter { selected.contains($0.id) }
        Task.detached {
            var done = Set<UUID>()
            for f in targets where FS.trash(f.url) { done.insert(f.id) }
            let d = done
            await MainActor.run {
                var freed: Int64 = 0
                for g in self.groups { for f in g.files where d.contains(f.id) { freed += g.size } }
                Shared.history.add("File trùng lặp", "\(d.count) bản sao chuyển vào Thùng rác", freed)
                self.groups = self.groups.compactMap { g in
                    let rest = g.files.filter { !d.contains($0.id) }
                    return rest.count > 1 ? DupGroup(size: g.size, files: rest) : nil
                }
                self.selected.subtract(d)
            }
        }
    }
}

struct DuplicatesView: View {
    @EnvironmentObject var model: DupModel
    @StateObject private var confirm = Box(false)

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "File trùng lặp", subtitle: "Tìm các file giống hệt nhau về nội dung (so sánh SHA-256)", icon: "doc.on.doc.fill",
                       onBack: model.scannedOnce && !model.scanning ? { model.reset() } : nil)
            HStack {
                Text(L("Thư mục: \(shortPath(model.root))")).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { model.chooseFolder() } label: { Label(L("Chọn thư mục"), systemImage: "folder") }.glassButton()
                Button(L("Quét")) { model.scan() }.glassButton(prominent: true).disabled(model.scanning)
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
            if model.scanning {
                BusyView(text: model.status)
            } else if !model.scannedOnce {
                EmptyState(icon: "doc.on.doc", title: "Tìm file trùng lặp", message: "Chọn một thư mục (ví dụ Tải về, Ảnh, Tài liệu) rồi bấm quét.", actionTitle: "Quét \(model.root.lastPathComponent)") { model.scan() }
            } else if model.groups.isEmpty {
                Text(L("Không có file trùng lặp 🎉")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GlassScroll {
                    ForEach(model.groups) { g in
                        GlassSection("\(g.files.count) bản giống nhau · mỗi bản \(fmt(g.size))") {
                            ForEach(g.files) { f in
                                HStack(spacing: 10) {
                                    Toggle(L(""), isOn: Binding(
                                        get: { model.selected.contains(f.id) },
                                        set: { v in if v { model.selected.insert(f.id) } else { model.selected.remove(f.id) } }
                                    )).labelsHidden()
                                    FileIcon(url: f.url, size: 24)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(L(f.url.lastPathComponent)).lineLimit(1)
                                        Text(L(shortPath(f.url.deletingLastPathComponent()))).font(.uiCaption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(L(dateFmt.string(from: f.modified))).font(.uiCaption).foregroundStyle(.secondary)
                                    RevealButton(url: f.url)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
            BottomBar {
                if model.scannedOnce {
                    Text(L("Lãng phí: \(fmt(model.wasted))")).foregroundStyle(.secondary)
                }
                Spacer()
                Text(L("Đã chọn \(model.selected.count) · \(fmt(model.selectedSize))")).monospacedDigit()
                Button(L("Tự chọn (giữ bản cũ nhất)")) { model.autoSelect() }.glassButton().disabled(model.groups.isEmpty)
                Button(L("Chuyển vào Thùng rác")) { confirm.value = true }
                    .glassButton(prominent: true)
                    .disabled(model.selected.isEmpty)
            }
        }
        .confirmationDialog(L("Chuyển \(model.selected.count) file trùng vào Thùng rác?"), isPresented: $confirm.value) {
            Button(L("Chuyển vào Thùng rác"), role: .destructive) { model.trashSelected() }
        } message: {
            Text(L("Bạn vẫn có thể khôi phục từ Thùng rác."))
        }
    }
}
