import SwiftUI
import AppKit

struct AppUpdate: Identifiable {
    let id = UUID()
    let name: String
    let current: String
    let latest: String
    let source: String        // "Homebrew", "Homebrew (công cụ)", "Tự cập nhật"
    let brewName: String?
    let isCask: Bool
    let appURL: URL?
    let downloadURL: URL?
}

final class AppcastParser: NSObject, XMLParserDelegate {
    struct Entry { var short: String?; var build: String?; var url: String?; var beta = false }
    var entries: [Entry] = []
    private var inItem = false
    private var cur = Entry()
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        text = ""
        if name == "item" { inItem = true; cur = Entry() }
        if inItem && name == "enclosure" {
            cur.url = a["url"]
            if let s = a["sparkle:shortVersionString"] { cur.short = s }
            if let v = a["sparkle:version"] { cur.build = v }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard inItem else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "sparkle:shortVersionString": if !t.isEmpty { cur.short = t }
        case "sparkle:version": if !t.isEmpty { cur.build = t }
        case "sparkle:channel": cur.beta = true
        case "item": entries.append(cur); inItem = false
        default: break
        }
    }

    func best() -> Entry? {
        entries.filter { !$0.beta && ($0.short != nil || $0.build != nil) }
            .max { UpdateEngine.compare($0.short ?? $0.build ?? "0", $1.short ?? $1.build ?? "0") < 0 }
    }
}

enum UpdateEngine {
    /// So sánh phiên bản "1.10.2" > "1.9" … trả về -1 / 0 / 1
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let pb = b.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    // MARK: Homebrew

    static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FS.fm.isExecutableFile(atPath: $0) }
    }

    static func brew(_ args: [String]) -> (Int32, String, String) {
        guard let b = brewPath() else { return (-1, "", "Không tìm thấy Homebrew") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: b)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NONINTERACTIVE"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    static func brewOutdated() -> [AppUpdate] {
        guard brewPath() != nil else { return [] }
        _ = brew(["update", "--quiet"])
        let (_, s, _) = brew(["outdated", "--json=v2", "--greedy"])
        guard let start = s.firstIndex(of: "{"),
              let data = String(s[start...]).data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        func ver(_ any: Any?) -> String {
            if let a = any as? [String] { return a.last ?? "" }
            return (any as? String) ?? ""
        }
        var out: [AppUpdate] = []
        for c in (j["casks"] as? [[String: Any]]) ?? [] {
            guard let n = c["name"] as? String else { continue }
            out.append(AppUpdate(name: n, current: ver(c["installed_versions"]), latest: ver(c["current_version"]),
                                 source: "Homebrew", brewName: n, isCask: true, appURL: nil, downloadURL: nil))
        }
        for f in (j["formulae"] as? [[String: Any]]) ?? [] {
            guard let n = f["name"] as? String else { continue }
            if (f["pinned"] as? Bool) == true { continue }
            out.append(AppUpdate(name: n, current: ver(f["installed_versions"]), latest: ver(f["current_version"]),
                                 source: "Homebrew (công cụ)", brewName: n, isCask: false, appURL: nil, downloadURL: nil))
        }
        return out
    }

    // MARK: Ứng dụng tự cập nhật (Sparkle)

    struct LocalApp { let url: URL; let name: String; let short: String; let build: String; let feed: String }

    static func sparkleApps() -> [LocalApp] {
        var urls: [URL] = []
        for dir in [URL(fileURLWithPath: "/Applications"), FS.home.appendingPathComponent("Applications")] {
            for u in FS.children(dir) {
                if u.pathExtension == "app" { urls.append(u) }
                else if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    urls += FS.children(u).filter { $0.pathExtension == "app" }
                }
            }
        }
        var out: [LocalApp] = []
        for u in urls {
            guard let b = Bundle(url: u), let info = b.infoDictionary,
                  let feed = info["SUFeedURL"] as? String, !feed.isEmpty else { continue }
            out.append(LocalApp(url: u, name: u.deletingPathExtension().lastPathComponent,
                                short: (info["CFBundleShortVersionString"] as? String) ?? "0",
                                build: (info["CFBundleVersion"] as? String) ?? "0", feed: feed))
        }
        return out
    }

    static func sparkleUpdates() async -> [AppUpdate] {
        var out: [AppUpdate] = []
        for app in sparkleApps() {
            guard let feed = URL(string: app.feed) else { continue }
            var req = URLRequest(url: feed)
            req.timeoutInterval = 8
            guard let res = try? await URLSession.shared.data(for: req) else { continue }
            let parser = AppcastParser()
            let xp = XMLParser(data: res.0)
            xp.delegate = parser
            xp.parse()
            guard let best = parser.best() else { continue }
            var newer = false
            var latest = ""
            if let s = best.short {
                newer = compare(s, app.short) > 0
                latest = s
            } else if let bl = best.build {
                newer = compare(bl, app.build) > 0
                latest = bl
            }
            guard newer else { continue }
            out.append(AppUpdate(name: app.name, current: app.short, latest: latest, source: "Tự cập nhật",
                                 brewName: nil, isCask: false, appURL: app.url,
                                 downloadURL: best.url.flatMap { URL(string: $0) }))
        }
        return out
    }
}

@MainActor
final class UpdatesModel: ObservableObject {
    @Published var updates: [AppUpdate] = []
    @Published var checking = false
    @Published var working: Set<UUID> = []
    @Published var message = ""
    @Published var lastCheck: Date? = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date

    /// 0 tắt · 1 mỗi lần mở app · 2 mỗi ngày · 3 mỗi tuần · 4 mỗi tháng
    func autoCheckIfNeeded(frequency: Int) {
        switch frequency {
        case 0: return
        case 1: check()
        default:
            let interval: Double = frequency == 2 ? 86_400 : (frequency == 3 ? 7 * 86_400 : 30 * 86_400)
            if let l = lastCheck, Date().timeIntervalSince(l) < interval { return }
            check()
        }
    }

    func check() {
        guard !checking else { return }
        checking = true
        message = ""
        Task.detached(priority: .utility) {
            let brew = UpdateEngine.brewOutdated()
            let sp = await UpdateEngine.sparkleUpdates()
            let brewNames = Set(brew.map { $0.name.lowercased().replacingOccurrences(of: "-", with: " ") })
            let merged = brew + sp.filter { !brewNames.contains($0.name.lowercased()) }
            await MainActor.run {
                self.updates = merged.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.checking = false
                self.lastCheck = Date()
                UserDefaults.standard.set(self.lastCheck, forKey: "lastUpdateCheck")
                self.message = merged.isEmpty ? "Tất cả ứng dụng đã là bản mới nhất." : "Có \(merged.count) bản cập nhật."
            }
        }
    }

    func update(_ u: AppUpdate) {
        if let n = u.brewName {
            working.insert(u.id)
            Task.detached(priority: .userInitiated) {
                let args = u.isCask ? ["upgrade", "--cask", n] : ["upgrade", n]
                let (code, _, err) = UpdateEngine.brew(args)
                await MainActor.run {
                    self.working.remove(u.id)
                    if code == 0 {
                        self.updates.removeAll { $0.id == u.id }
                        self.message = "Đã cập nhật \(u.name) lên \(u.latest)."
                    } else {
                        let tail = err.split(separator: "\n").suffix(2).joined(separator: " ")
                        self.message = "Không cập nhật được \(u.name). Có thể cần mật khẩu – thử trong Terminal: brew upgrade \(u.isCask ? "--cask " : "")\(n). \(tail)"
                    }
                }
            }
        } else if let app = u.appURL {
            // Ứng dụng có trình tự cập nhật riêng: mở app để nó tự hỏi cập nhật
            NSWorkspace.shared.open(app)
            message = "Đã mở \(u.name) – app sẽ tự hiện thông báo cập nhật (hoặc vào menu của app → Kiểm tra cập nhật)."
        } else if let d = u.downloadURL {
            NSWorkspace.shared.open(d)
        }
    }

    /// Cập nhật tất cả mục Homebrew trong một lần chạy (brew không cho chạy song song)
    func updateAllBrew() {
        let items = updates.filter { $0.brewName != nil }
        guard !items.isEmpty else { return }
        for u in items { working.insert(u.id) }
        message = "Đang cập nhật \(items.count) mục qua Homebrew…"
        let casks = items.filter { $0.isCask }.compactMap { $0.brewName }
        let formulae = items.filter { !$0.isCask }.compactMap { $0.brewName }
        Task.detached(priority: .userInitiated) {
            var failed: [String] = []
            if !casks.isEmpty {
                let (c, _, _) = UpdateEngine.brew(["upgrade", "--cask"] + casks)
                if c != 0 { failed.append("ứng dụng") }
            }
            if !formulae.isEmpty {
                let (c, _, _) = UpdateEngine.brew(["upgrade"] + formulae)
                if c != 0 { failed.append("công cụ") }
            }
            let f = failed
            await MainActor.run {
                self.working = []
                self.message = f.isEmpty ? "Đã cập nhật xong qua Homebrew." : "Một số \(f.joined(separator: ", ")) chưa cập nhật được (có thể cần mật khẩu – chạy brew upgrade trong Terminal)."
                self.check()
            }
        }
    }
}
