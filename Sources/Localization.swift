import Foundation

/// Đa ngôn ngữ: chuỗi gốc tiếng Việt, bản dịch nạp từ Resources/strings.json.
/// Câu có số liệu dùng mẫu "{}" (vd "Đã chọn: {}" → "Selected: {}").
enum Lang {
    static let options: [(code: String, name: String, flag: String)] = [
        ("vi", "Tiếng Việt", "🇻🇳"),
        ("en", "English", "🇺🇸")
    ]

    private(set) static var current = "vi"
    private static var table: [String: String] = [:]
    private static var templates: [(prefix: String, suffix: String, re: NSRegularExpression, target: String)] = []
    private static var cache: [String: String] = [:]

    private static let all: [String: [String: String]] = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("strings.json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return [:] }
        return obj
    }()

    static var flag: String { options.first { $0.code == current }?.flag ?? "🌐" }
    static var localeID: String { current == "vi" ? "vi_VN" : "en_US" }

    /// "auto" = theo ngôn ngữ của máy (tiếng Việt nếu máy dùng tiếng Việt, còn lại tiếng Anh)
    static func resolve(_ pref: String) -> String {
        if options.contains(where: { $0.code == pref }) { return pref }
        let sys = (Locale.preferredLanguages.first ?? "en").lowercased()
        return sys.hasPrefix("vi") ? "vi" : "en"
    }

    static func apply(_ pref: String) {
        current = resolve(pref)
        cache = [:]
        table = all[current] ?? [:]
        templates = table.keys.filter { $0.contains("{}") }
            .sorted { $0.count > $1.count }
            .compactMap { key in
                let parts = key.components(separatedBy: "{}")
                let pattern = "^" + parts.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "(.*?)") + "$"
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
                return (parts.first ?? "", parts.last ?? "", re, table[key] ?? key)
            }
        let loc = Locale(identifier: localeID)
        dateFmt.locale = loc
    }

    static func translate(_ s: String) -> String {
        if current == "vi" || s.isEmpty { return s }
        if let t = table[s] { return t }
        if let c = cache[s] { return c }
        var result = s
        let ns = s as NSString
        for t in templates where s.hasPrefix(t.prefix) && s.hasSuffix(t.suffix) && ns.length >= (t.prefix as NSString).length + (t.suffix as NSString).length {
            guard let m = t.re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            var pieces = t.target.components(separatedBy: "{}")
            var out = pieces.removeFirst()
            for (i, p) in pieces.enumerated() {
                let r = i + 1 < m.numberOfRanges ? m.range(at: i + 1) : NSRange(location: NSNotFound, length: 0)
                let cap = r.location != NSNotFound ? ns.substring(with: r) : ""
                out += (cap == s ? cap : translate(cap)) + p
            }
            result = out
            break
        }
        if cache.count > 5000 { cache = [:] }
        cache[s] = result
        return result
    }
}

/// Dịch một chuỗi hiển thị sang ngôn ngữ đang chọn
func L(_ s: String) -> String { Lang.translate(s) }
