import SwiftUI
import AppKit

enum BrowserKind { case chromium, safari, firefox }

struct BrowserDef {
    let id: String
    let name: String
    let bundleId: String
    let kind: BrowserKind
    let dataPath: String   // tương đối với ~/Library
    let cachePath: String  // tương đối với ~/Library
}

struct BrowserScan: Identifiable {
    let id: String
    let name: String
    let bundleId: String
    let cache: [URL]
    let cookies: [URL]
    let history: [URL]
    let cacheSize: Int64
    let cookieSize: Int64
    let historySize: Int64
    let historyNote: String
    var enabled: Bool = true

    func total(cookies c: Bool, history h: Bool) -> Int64 {
        cacheSize + (c ? cookieSize : 0) + (h ? historySize : 0)
    }
}

enum BrowserEngine {
    static let defs: [BrowserDef] = [
        BrowserDef(id: "safari", name: "Safari", bundleId: "com.apple.Safari", kind: .safari, dataPath: "Safari", cachePath: "Caches/com.apple.Safari"),
        BrowserDef(id: "chrome", name: "Google Chrome", bundleId: "com.google.Chrome", kind: .chromium, dataPath: "Application Support/Google/Chrome", cachePath: "Caches/Google/Chrome"),
        BrowserDef(id: "coccoc", name: "Cốc Cốc", bundleId: "com.coccoc.Coccoc", kind: .chromium, dataPath: "Application Support/Coccoc", cachePath: "Caches/Coccoc"),
        BrowserDef(id: "opera", name: "Opera", bundleId: "com.operasoftware.Opera", kind: .chromium, dataPath: "Application Support/com.operasoftware.Opera", cachePath: "Caches/com.operasoftware.Opera"),
        BrowserDef(id: "operagx", name: "Opera GX", bundleId: "com.operasoftware.OperaGX", kind: .chromium, dataPath: "Application Support/com.operasoftware.OperaGX", cachePath: "Caches/com.operasoftware.OperaGX"),
        BrowserDef(id: "edge", name: "Microsoft Edge", bundleId: "com.microsoft.edgemac", kind: .chromium, dataPath: "Application Support/Microsoft Edge", cachePath: "Caches/Microsoft Edge"),
        BrowserDef(id: "brave", name: "Brave", bundleId: "com.brave.Browser", kind: .chromium, dataPath: "Application Support/BraveSoftware/Brave-Browser", cachePath: "Caches/BraveSoftware/Brave-Browser"),
        BrowserDef(id: "arc", name: "Arc", bundleId: "company.thebrowser.Browser", kind: .chromium, dataPath: "Application Support/Arc/User Data", cachePath: "Caches/Arc"),
        BrowserDef(id: "vivaldi", name: "Vivaldi", bundleId: "com.vivaldi.Vivaldi", kind: .chromium, dataPath: "Application Support/Vivaldi", cachePath: "Caches/Vivaldi"),
        BrowserDef(id: "chromium", name: "Chromium", bundleId: "org.chromium.Chromium", kind: .chromium, dataPath: "Application Support/Chromium", cachePath: "Caches/Chromium"),
        BrowserDef(id: "firefox", name: "Firefox", bundleId: "org.mozilla.firefox", kind: .firefox, dataPath: "Application Support/Firefox", cachePath: "Caches/Firefox")
    ]

    static func existing(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { u in
            guard FS.fm.fileExists(atPath: u.path), !seen.contains(u.path) else { return false }
            seen.insert(u.path)
            return true
        }
    }

    static func total(_ urls: [URL]) -> Int64 { urls.reduce(0) { $0 + FS.size(of: $1) } }

    static func chromiumProfiles(_ root: URL) -> [URL] {
        var p = [root]
        for c in FS.children(root) {
            let n = c.lastPathComponent
            if n == "Default" || n.hasPrefix("Profile ") || n == "Guest Profile" || n == "System Profile" { p.append(c) }
        }
        return p
    }

    static func scanOne(_ d: BrowserDef) -> BrowserScan? {
        let data = FS.lib(d.dataPath)
        let cacheRoot = FS.lib(d.cachePath)
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: d.bundleId) != nil
        guard FS.fm.fileExists(atPath: data.path) || (installed && FS.fm.fileExists(atPath: cacheRoot.path)) else { return nil }

        var cache: [URL] = [cacheRoot]
        var cookies: [URL] = []
        var history: [URL] = []
        var note = ""

        switch d.kind {
        case .chromium:
            let profiles = chromiumProfiles(data)
            let cacheNames = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
                              "GrShaderCache", "GraphiteDawnCache", "ShaderCache", "Media Cache", "Application Cache",
                              "Service Worker/CacheStorage", "Service Worker/ScriptCache"]
            let cookieNames = ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal",
                               "Extension Cookies", "Extension Cookies-journal"]
            let historyNames = ["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal",
                                "Shortcuts", "Shortcuts-journal"]
            for p in profiles {
                cache += cacheNames.map { p.appendingPathComponent($0) }
                cookies += cookieNames.map { p.appendingPathComponent($0) }
                history += historyNames.map { p.appendingPathComponent($0) }
            }
        case .safari:
            cache.append(FS.lib("Containers/com.apple.Safari/Data/Library/Caches"))
            cache.append(FS.lib("Caches/com.apple.WebKit.Networking"))
            cookies = [FS.lib("Cookies/Cookies.binarycookies"),
                       FS.lib("Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")]
            history = ["History.db", "History.db-wal", "History.db-shm", "History.db-lock"].map { FS.lib("Safari/" + $0) }
        case .firefox:
            for p in FS.children(data.appendingPathComponent("Profiles")) {
                cookies += ["cookies.sqlite", "cookies.sqlite-wal", "cookies.sqlite-shm"].map { p.appendingPathComponent($0) }
                cache += ["startupCache", "shader-cache"].map { p.appendingPathComponent($0) }
            }
            note = "Firefox lưu lịch sử chung với dấu trang nên không xoá lịch sử"
        }

        cache = existing(cache)
        cookies = existing(cookies)
        history = existing(history)
        return BrowserScan(id: d.id, name: d.name, bundleId: d.bundleId, cache: cache, cookies: cookies, history: history,
                           cacheSize: total(cache), cookieSize: total(cookies), historySize: total(history), historyNote: note)
    }

    static func scan() -> [BrowserScan] { defs.compactMap { scanOne($0) } }
}

@MainActor
final class BrowserModel: ObservableObject {
    @Published var browsers: [BrowserScan] = []
    @Published var scanning = false
    @Published var cleaning = false
    @Published var scannedOnce = false
    @Published var status = ""
    @Published var lastFreed: Int64? = nil
    @Published var skipped: [String] = []

    func total(_ s: AppSettings) -> Int64 {
        browsers.filter { $0.enabled }.reduce(0) { $0 + $1.total(cookies: s.cleanCookies, history: s.cleanHistory) }
    }

    func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    func reset() {
        guard !scanning, !cleaning else { return }
        scannedOnce = false
        lastFreed = nil
        skipped = []
    }

    func scan() {
        guard !scanning, !cleaning else { return }
        scanning = true
        status = "Đang quét trình duyệt…"
        let enabledBefore = Dictionary(uniqueKeysWithValues: browsers.map { ($0.id, $0.enabled) })
        Task.detached(priority: .userInitiated) {
            var res = BrowserEngine.scan()
            for i in res.indices { res[i].enabled = enabledBefore[res[i].id] ?? true }
            let found = res
            await MainActor.run {
                self.browsers = found
                self.scanning = false
                self.scannedOnce = true
            }
        }
    }

    func clean(cookies: Bool, history: Bool) {
        guard !cleaning, !scanning else { return }
        let targets = browsers.filter { $0.enabled }
        guard !targets.isEmpty else { return }
        cleaning = true
        skipped = []
        status = "Đang đóng trình duyệt…"
        for b in targets {
            for r in NSRunningApplication.runningApplications(withBundleIdentifier: b.bundleId) { r.terminate() }
        }
        Task.detached(priority: .userInitiated) {
            for _ in 0..<16 {
                let anyRunning = await MainActor.run { targets.contains { self.isRunning($0.bundleId) } }
                if !anyRunning { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await MainActor.run { self.status = "Đang dọn dẹp…" }
            var freed: Int64 = 0
            var skip: [String] = []
            for b in targets {
                let still = await MainActor.run { self.isRunning(b.bundleId) }
                if still { skip.append(b.name); continue }
                for u in b.cache { FS.removeContents(u) }
                freed += b.cacheSize
                if cookies {
                    for u in b.cookies { try? FS.fm.removeItem(at: u) }
                    freed += b.cookieSize
                }
                if history {
                    for u in b.history { try? FS.fm.removeItem(at: u) }
                    freed += b.historySize
                }
            }
            let total = freed
            let sk = skip
            await MainActor.run {
                self.lastFreed = total
                Shared.history.add("Dọn trình duyệt",
                                   targets.filter { !sk.contains($0.name) }.map { $0.name }.joined(separator: ", ")
                                   + (cookies ? " · có cookie" : "") + (history ? " · có lịch sử" : ""), total)
                self.skipped = sk
                self.cleaning = false
                self.scan()
            }
        }
    }
}

struct BrowsersView: View {
    @EnvironmentObject var model: BrowserModel
    @EnvironmentObject var settings: AppSettings
    @Binding var selection: AppSection?
    @StateObject private var confirm = Box(false)

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Dọn trình duyệt", subtitle: "Xoá bộ nhớ đệm, cookie và lịch sử của các trình duyệt", icon: "globe",
                       onBack: model.scannedOnce && !model.scanning && !model.cleaning ? { model.reset() } : nil)
            if model.scanning || model.cleaning {
                BusyView(text: model.status)
            } else if !model.scannedOnce {
                EmptyState(icon: "globe", title: "Quét trình duyệt", message: "Tìm Safari, Chrome, Cốc Cốc, Opera, Edge, Brave, Firefox… trên máy.", actionTitle: "Quét ngay") { model.scan() }
            } else if model.browsers.isEmpty {
                Text(L("Không tìm thấy trình duyệt nào")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        optionsCard
                        ForEach($model.browsers) { $b in
                            BrowserRow(b: $b, cookies: settings.cleanCookies, history: settings.cleanHistory,
                                       running: model.isRunning(b.bundleId))
                        }
                        if !model.skipped.isEmpty {
                            Text(L("Bỏ qua vì chưa đóng được: \(model.skipped.joined(separator: ", "))"))
                                .font(.uiCallout).foregroundColor(.orange)
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 12)
                }
            }
            BottomBar {
                if let f = model.lastFreed {
                    Label(L("Đã giải phóng \(fmt(f))"), systemImage: "checkmark.seal.fill").foregroundColor(.green)
                }
                Spacer()
                Text(L("Đã chọn: \(fmt(model.total(settings)))")).monospacedDigit()
                Button(L("Quét lại")) { model.scan() }.glassButton().disabled(model.scanning || model.cleaning)
                Button(L("Dọn dẹp")) { confirm.value = true }
                    .glassButton(prominent: true)
                    .disabled(model.total(settings) == 0 || model.scanning || model.cleaning)
            }
        }
        .confirmationDialog(L("Dọn \(fmt(model.total(settings))) dữ liệu trình duyệt?"), isPresented: $confirm.value) {
            Button(L("Dọn dẹp"), role: .destructive) { model.clean(cookies: settings.cleanCookies, history: settings.cleanHistory) }
        } message: {
            Text(L(settings.cleanCookies
                 ? "Các trình duyệt đang mở sẽ được đóng. Cookie sẽ bị xoá nên bạn sẽ bị đăng xuất khỏi các trang web."
                 : "Các trình duyệt đang mở sẽ được đóng. Cookie được giữ nguyên, bạn không bị đăng xuất."))
        }
    }

    var optionsCard: some View {
        HStack(spacing: 18) {
            Toggle(isOn: $settings.cleanCookies) { Text(L("Dọn cookie")) }.toggleStyle(.checkbox)
            Toggle(isOn: $settings.cleanHistory) { Text(L("Dọn lịch sử")) }.toggleStyle(.checkbox)
            Text(L(settings.cleanCookies ? "Cookie sẽ bị xoá (đăng xuất web)" : "Giữ cookie – không bị đăng xuất"))
                .font(.uiCaption).foregroundStyle(.secondary)
            Spacer()
            Button { selection = .settings } label: { Label(L("Cài đặt"), systemImage: "gearshape") }.glassButton()
        }
        .padding(14)
        .glassCard(cornerRadius: 18)
    }
}

struct BrowserRow: View {
    @Binding var b: BrowserScan
    let cookies: Bool
    let history: Bool
    let running: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle(L(""), isOn: $b.enabled).toggleStyle(.checkbox).labelsHidden()
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.bundleId) {
                FileIcon(url: u, size: 36)
            } else {
                Image(systemName: "globe").font(.uiTitle).frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(L(b.name)).font(.uiHeadline)
                    if running {
                        Text(L("đang mở")).font(.uiCaption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                }
                HStack(spacing: 12) {
                    part("Bộ đệm", b.cacheSize, on: true)
                    part("Cookie", b.cookieSize, on: cookies)
                    part("Lịch sử", b.historySize, on: history)
                }
                if history && !b.historyNote.isEmpty {
                    Text(L(b.historyNote)).font(.uiCaption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(L(fmt(b.total(cookies: cookies, history: history)))).font(.uiTitle3).bold().monospacedDigit()
                .foregroundColor(b.enabled ? .primary : .secondary)
        }
        .padding(14)
        .glassCard(cornerRadius: 18)
    }

    func part(_ title: String, _ size: Int64, on: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: on ? "checkmark.circle.fill" : "minus.circle")
                .foregroundColor(on ? Theme.accent : .secondary)
            Text(L("\(title) \(fmt(size))")).foregroundColor(on ? .primary : .secondary)
                .strikethrough(!on)
        }
        .font(.uiCaption)
    }
}
