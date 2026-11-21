import SwiftUI
import AppKit

enum AIKind { case junk, model }

struct AIItem: Identifiable {
    let id = UUID()
    let kind: AIKind
    let source: String          // Ollama, HuggingFace, LM Studio, pip…
    let name: String
    let detail: String
    let urls: [URL]
    let size: Int64
    let lastUsed: Date?
    let ollamaManifest: URL?    // với mô hình Ollama: tệp manifest
    var selected: Bool

    var staleDays: Int? {
        guard let d = lastUsed else { return nil }
        return Int(Date().timeIntervalSince(d) / 86400)
    }
}

enum AIEngine {
    static var home: URL { FS.home }

    // MARK: Đo dung lượng (không đếm trùng hard link) + lần dùng gần nhất
    static func measure(_ url: URL) -> (Int64, Date?) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .fileResourceIdentifierKey, .contentAccessDateKey, .contentModificationDateKey]
        let keySet = Set(keys)
        var isDir: ObjCBool = false
        guard FS.fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return (0, nil) }
        var total: Int64 = 0
        var last: Date? = nil
        var seen = Set<NSObject>()
        func add(_ v: URLResourceValues) {
            if let rid = v.fileResourceIdentifier as? NSObject {
                if seen.contains(rid) { return }
                seen.insert(rid)
            }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            for d in [v.contentAccessDate, v.contentModificationDate].compactMap({ $0 }) {
                if last == nil || d > last! { last = d }
            }
        }
        if !isDir.boolValue {
            if let v = try? url.resourceValues(forKeys: keySet) { add(v) }
            return (total, last)
        }
        guard let en = FS.fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return (0, nil) }
        for case let f as URL in en {
            guard let v = try? f.resourceValues(forKeys: keySet), v.isRegularFile == true else { continue }
            add(v)
        }
        return (total, last)
    }

    // MARK: Ollama

    struct OllamaManifest {
        let url: URL
        let name: String
        let digests: [String]
    }

    static var ollamaRoot: URL {
        if let p = ProcessInfo.processInfo.environment["OLLAMA_MODELS"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return home.appendingPathComponent(".ollama/models")
    }

    static func blobURL(_ digest: String) -> URL {
        ollamaRoot.appendingPathComponent("blobs").appendingPathComponent(digest.replacingOccurrences(of: ":", with: "-"))
    }

    static func ollamaManifests() -> [OllamaManifest] {
        let mroot = ollamaRoot.appendingPathComponent("manifests")
        guard let en = FS.fm.enumerator(at: mroot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return [] }
        var out: [OllamaManifest] = []
        for case let f as URL in en {
            guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: f),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            var digests: [String] = []
            if let c = json["config"] as? [String: Any], let d = c["digest"] as? String { digests.append(d) }
            for l in (json["layers"] as? [[String: Any]]) ?? [] {
                if let d = l["digest"] as? String { digests.append(d) }
            }
            let rel = f.path.replacingOccurrences(of: mroot.path + "/", with: "").split(separator: "/").map(String.init)
            var name = rel.joined(separator: "/")
            if rel.count >= 4 {
                let host = rel[0], ns = rel[1], model = rel[2], tag = rel[3]
                if host == "registry.ollama.ai" {
                    name = (ns == "library" ? model : "\(ns)/\(model)") + ":" + tag
                } else {
                    name = "\(host)/\(ns)/\(model):\(tag)"
                }
            }
            out.append(OllamaManifest(url: f, name: name, digests: digests))
        }
        return out
    }

    /// Số tệp manifest thực có (để biết có đọc sót cái nào không)
    static func manifestFileCount() -> Int {
        let mroot = ollamaRoot.appendingPathComponent("manifests")
        guard let en = FS.fm.enumerator(at: mroot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return 0 }
        var n = 0
        for case let f as URL in en where (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { n += 1 }
        return n
    }

    // MARK: Quét

    static func scan(progress: (String) -> Void) -> [AIItem] {
        var items: [AIItem] = []

        func junk(_ source: String, _ name: String, _ urls: [URL]) {
            let ex = urls.filter { FS.fm.fileExists(atPath: $0.path) }
            guard !ex.isEmpty else { return }
            var size: Int64 = 0
            var last: Date? = nil
            for u in ex {
                let (s, d) = measure(u)
                size += s
                if let d = d, last == nil || d > last! { last = d }
            }
            guard size > 0 else { return }
            items.append(AIItem(kind: .junk, source: source, name: name,
                                detail: ex.count == 1 ? shortPath(ex[0]) : "\(ex.count) mục",
                                urls: ex, size: size, lastUsed: last, ollamaManifest: nil, selected: true))
        }

        progress("Đang quét bộ đệm tải về…")
        junk("pip", "Bộ đệm tải gói Python (pip)", [FS.lib("Caches/pip")])
        junk("uv", "Bộ đệm uv (Python)", [home.appendingPathComponent(".cache/uv"), FS.lib("Caches/uv")])
        junk("Homebrew", "Bộ đệm tải về Homebrew", [FS.lib("Caches/Homebrew")])
        junk("npm", "Bộ đệm npm", [home.appendingPathComponent(".npm/_cacache")])
        junk("Conda", "Gói tải về của Conda",
             ["miniconda3/pkgs", "anaconda3/pkgs", "miniforge3/pkgs", "opt/miniconda3/pkgs"].map { home.appendingPathComponent($0) })
        junk("HuggingFace", "Bộ đệm Xet của HuggingFace", [home.appendingPathComponent(".cache/huggingface/xet")])

        // File tải dở của HuggingFace
        progress("Đang tìm file tải dở…")
        let hfHub = home.appendingPathComponent(".cache/huggingface/hub")
        var incomplete: [URL] = []
        if let en = FS.fm.enumerator(at: hfHub, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true }) {
            for case let f as URL in en where f.lastPathComponent.hasSuffix(".incomplete") { incomplete.append(f) }
        }
        junk("HuggingFace", "Mô hình HuggingFace tải dở", incomplete)

        // Ollama: blob mồ côi + tải dở
        progress("Đang đọc mô hình Ollama…")
        let manifests = ollamaManifests()
        var refCount: [String: Int] = [:]
        for m in manifests { for d in Set(m.digests) { refCount[blobURL(d).lastPathComponent, default: 0] += 1 } }
        let blobs = FS.children(ollamaRoot.appendingPathComponent("blobs"))
        // An toàn: nếu có manifest không đọc được thì chỉ coi file tải dở (-partial) là rác,
        // tránh xoá nhầm dữ liệu của mô hình đang dùng
        let allRead = !manifests.isEmpty && manifests.count == manifestFileCount()
        let orphans = blobs.filter { b in
            let n = b.lastPathComponent
            if n.contains("partial") { return true }
            return allRead && refCount[n] == nil
        }
        junk("Ollama", "Ollama: dữ liệu mồ côi & tải dở", orphans)

        // Mô hình Ollama
        for m in manifests {
            let unique = Set(m.digests).filter { refCount[blobURL($0).lastPathComponent] == 1 }
            var size: Int64 = 0
            var last: Date? = nil
            for d in unique {
                let (s, dt) = measure(blobURL(d))
                size += s
                if let dt = dt, last == nil || dt > last! { last = dt }
            }
            let shared = Set(m.digests).count - unique.count
            items.append(AIItem(kind: .model, source: "Ollama", name: m.name,
                                detail: shared > 0 ? "Dùng chung \(shared) phần với mô hình khác" : shortPath(m.url.deletingLastPathComponent()),
                                urls: unique.map { blobURL($0) }, size: size, lastUsed: last,
                                ollamaManifest: m.url, selected: false))
        }

        // Mô hình HuggingFace
        progress("Đang đọc mô hình HuggingFace…")
        for d in FS.children(hfHub) {
            let n = d.lastPathComponent
            guard n.hasPrefix("models--") || n.hasPrefix("datasets--") || n.hasPrefix("spaces--") else { continue }
            let isData = n.hasPrefix("datasets--")
            let name = n.replacingOccurrences(of: "models--", with: "")
                .replacingOccurrences(of: "datasets--", with: "")
                .replacingOccurrences(of: "spaces--", with: "")
                .replacingOccurrences(of: "--", with: "/")
            let (s, last) = measure(d)
            guard s > 0 else { continue }
            items.append(AIItem(kind: .model, source: isData ? "HF dataset" : "HuggingFace", name: name,
                                detail: shortPath(d), urls: [d], size: s, lastUsed: last, ollamaManifest: nil, selected: false))
        }

        // Mô hình LM Studio
        progress("Đang đọc mô hình LM Studio…")
        for root in [home.appendingPathComponent(".lmstudio/models"), home.appendingPathComponent(".cache/lm-studio/models")] {
            for pub in FS.children(root) {
                for model in FS.children(pub) {
                    var isDir: ObjCBool = false
                    guard FS.fm.fileExists(atPath: model.path, isDirectory: &isDir), isDir.boolValue else { continue }
                    let (s, last) = measure(model)
                    guard s > 0 else { continue }
                    items.append(AIItem(kind: .model, source: "LM Studio", name: "\(pub.lastPathComponent)/\(model.lastPathComponent)",
                                        detail: shortPath(model), urls: [model], size: s, lastUsed: last, ollamaManifest: nil, selected: false))
                }
            }
        }

        let ign = IgnoreList.matcher()
        return items.filter { it in
            !(it.urls.first.map(ign) ?? false) && !(it.ollamaManifest.map(ign) ?? false)
        }.sorted { $0.size > $1.size }
    }

    // MARK: Xoá

    static func deleteJunk(_ item: AIItem) {
        for u in item.urls {
            var isDir: ObjCBool = false
            guard FS.fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            // Thư mục bộ đệm: xoá nội dung, giữ thư mục; file lẻ: xoá file
            if isDir.boolValue && item.urls.count == 1 { FS.removeContents(u) } else { try? FS.fm.removeItem(at: u) }
        }
    }

    static func deleteModel(_ item: AIItem) {
        if let manifest = item.ollamaManifest {
            try? FS.fm.removeItem(at: manifest)
            // Xoá các phần chỉ mô hình này dùng (kiểm tra lại sau khi bỏ manifest)
            let remaining = ollamaManifests()
            guard remaining.count == manifestFileCount() else { return }   // có manifest đọc lỗi: không xoá dữ liệu dùng chung
            var stillUsed = Set<String>()
            for m in remaining { for d in m.digests { stillUsed.insert(blobURL(d).lastPathComponent) } }
            for u in item.urls where !stillUsed.contains(u.lastPathComponent) { try? FS.fm.removeItem(at: u) }
        } else {
            for u in item.urls { try? FS.fm.removeItem(at: u) }
        }
    }
}

@MainActor
final class AIModelsModel: ObservableObject {
    @Published var items: [AIItem] = []
    @Published var scanning = false
    @Published var working = false
    @Published var scannedOnce = false
    @Published var status = ""
    @Published var message = ""

    var junkItems: [AIItem] { items.filter { $0.kind == .junk } }
    var modelItems: [AIItem] { items.filter { $0.kind == .model } }
    var junkSelected: [AIItem] { junkItems.filter { $0.selected } }
    var modelSelected: [AIItem] { modelItems.filter { $0.selected } }
    func total(_ l: [AIItem]) -> Int64 { l.reduce(0) { $0 + $1.size } }

    func binding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { self.items.first { $0.id == id }?.selected ?? false },
                set: { v in if let i = self.items.firstIndex(where: { $0.id == id }) { self.items[i].selected = v } })
    }

    func reset() {
        guard !scanning, !working else { return }
        items = []
        scannedOnce = false
        message = ""
    }

    func scan() {
        guard !scanning, !working else { return }
        scanning = true
        status = "Đang quét…"
        Task.detached(priority: .userInitiated) {
            let res = AIEngine.scan { m in Task { @MainActor in self.status = m } }
            await MainActor.run {
                self.items = res
                self.scanning = false
                self.scannedOnce = true
            }
        }
    }

    func delete(_ targets: [AIItem], isModel: Bool) {
        guard !targets.isEmpty, !working else { return }
        working = true
        status = isModel ? "Đang xoá mô hình…" : "Đang dọn rác…"
        let freed = total(targets)
        Task.detached(priority: .userInitiated) {
            for t in targets {
                if isModel { AIEngine.deleteModel(t) } else { AIEngine.deleteJunk(t) }
            }
            await MainActor.run {
                self.working = false
                Shared.history.add(isModel ? "Mô hình AI" : "Rác AI",
                                   targets.prefix(4).map { $0.name }.joined(separator: ", ") + (targets.count > 4 ? "…" : ""), freed)
                self.message = (isModel ? "Đã xoá \(targets.count) mô hình" : "Đã dọn rác AI") + ", giải phóng khoảng \(fmt(freed))."
                self.scan()
            }
        }
    }
}

struct AIModelsView: View {
    @EnvironmentObject var model: AIModelsModel
    @StateObject private var confirmJunk = Box(false)
    @StateObject private var confirmModel = Box(false)

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Mô hình AI", subtitle: "Rác do công cụ AI để lại và các mô hình đã tải về máy", icon: "cpu",
                       onBack: model.scannedOnce && !model.scanning && !model.working ? { model.reset() } : nil)
            if model.scanning || model.working {
                BusyView(text: model.status)
            } else if !model.scannedOnce {
                EmptyState(icon: "cpu", title: "Quét mô hình AI",
                           message: "Tìm bộ đệm pip/Homebrew/Conda, file tải dở và các mô hình Ollama, HuggingFace, LM Studio trên máy.",
                           actionTitle: "Quét ngay") { model.scan() }
            } else {
                GlassScroll {
                    if !model.message.isEmpty {
                        Label(L(model.message), systemImage: "checkmark.seal.fill").foregroundColor(.green)
                    }
                    GlassSection("Rác có thể xoá an toàn · không ảnh hưởng mô hình và app đang dùng") {
                        if model.junkItems.isEmpty {
                            Text(L("Không có rác")).foregroundStyle(.secondary).padding(.vertical, 4)
                        }
                        ForEach(model.junkItems) { it in
                            AIRow(item: it, isOn: model.binding(it.id))
                        }
                        if !model.junkItems.isEmpty {
                            HStack {
                                Spacer()
                                Text(L("Đã chọn \(fmt(model.total(model.junkSelected)))")).foregroundStyle(.secondary).monospacedDigit()
                                Button(L("Dọn rác")) { confirmJunk.value = true }
                                    .glassButton(prominent: true)
                                    .disabled(model.junkSelected.isEmpty)
                            }
                            .padding(.top, 8)
                        }
                    }
                    GlassSection("Mô hình AI đã tải · xoá thì app dùng nó phải tải lại") {
                        if model.modelItems.isEmpty {
                            Text(L("Không tìm thấy mô hình nào")).foregroundStyle(.secondary).padding(.vertical, 4)
                        }
                        ForEach(model.modelItems) { it in
                            AIRow(item: it, isOn: model.binding(it.id))
                        }
                        if !model.modelItems.isEmpty {
                            HStack {
                                Text(L("Mô hình lâu không dùng được đánh dấu cam")).font(.uiCaption).foregroundStyle(.secondary)
                                Spacer()
                                Text(L("Đã chọn \(fmt(model.total(model.modelSelected)))")).foregroundStyle(.secondary).monospacedDigit()
                                Button(L("Xoá mô hình đã chọn")) { confirmModel.value = true }
                                    .glassButton(prominent: true).tint(.red)
                                    .disabled(model.modelSelected.isEmpty)
                            }
                            .padding(.top, 8)
                        }
                    }
                }
            }
            BottomBar {
                Text(L("Rác: \(fmt(model.total(model.junkItems))) · Mô hình: \(fmt(model.total(model.modelItems)))"))
                    .foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(L("Quét lại")) { model.scan() }.glassButton().disabled(model.scanning || model.working)
            }
        }
        .alert(L("Dọn rác AI?"), isPresented: $confirmJunk.value) {
            Button(L("Huỷ"), role: .cancel) {}
            Button(L("Dọn \(fmt(model.total(model.junkSelected)))"), role: .destructive) {
                model.delete(model.junkSelected, isModel: false)
            }
        } message: {
            Text(L("Sẽ xoá vĩnh viễn \(model.junkSelected.count) mục: \(names(model.junkSelected)).\nCác mô hình và ứng dụng đang dùng không bị ảnh hưởng."))
        }
        .alert(L("Xoá \(model.modelSelected.count) mô hình AI?"), isPresented: $confirmModel.value) {
            Button(L("Huỷ"), role: .cancel) {}
            Button(L("Xoá vĩnh viễn \(fmt(model.total(model.modelSelected)))"), role: .destructive) {
                model.delete(model.modelSelected, isModel: true)
            }
        } message: {
            Text(L("\(names(model.modelSelected))\n\nMô hình bị xoá vĩnh viễn, không nằm trong Thùng rác. Ứng dụng nào đang dùng (ví dụ App Đọc Truyện) sẽ phải tải lại ở lần chạy sau."))
        }
    }

    func names(_ l: [AIItem]) -> String {
        let n = l.prefix(6).map { "• \($0.name) (\(fmt($0.size)))" }.joined(separator: "\n")
        return l.count > 6 ? n + "\n• … và \(l.count - 6) mục khác" : n
    }
}

struct AIRow: View {
    let item: AIItem
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle(L(""), isOn: $isOn).toggleStyle(.checkbox).labelsHidden()
            Text(L(item.source))
                .font(.uiCaption.weight(.medium))
                .foregroundColor(Theme.selectedText)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.selectedFill))
                .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(item.name)).lineLimit(1).truncationMode(.middle)
                Text(L(item.detail)).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if item.kind == .model {
                Text(L(lastUsedText)).font(.uiCaption)
                    .foregroundColor((item.staleDays ?? 0) > 60 ? .orange : .secondary)
            }
            Text(L(fmt(item.size))).monospacedDigit().frame(width: 90, alignment: .trailing)
            if let u = item.urls.first ?? item.ollamaManifest { RevealButton(url: u) }
        }
        .padding(.vertical, 5)
    }

    var lastUsedText: String {
        guard let d = item.staleDays else { return "Chưa rõ lần dùng" }
        if d < 1 { return "Dùng hôm nay" }
        if d < 60 { return "Dùng \(d) ngày trước" }
        return "\(d) ngày không dùng"
    }
}
