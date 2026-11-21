import SwiftUI
import AppKit

// MARK: - Định dạng

func fmt(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
}

let dateFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "vi_VN")
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
}()

func shortPath(_ url: URL) -> String {
    url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

// MARK: - Hệ thống tệp

enum FS {
    static let fm = FileManager.default
    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }
    static func lib(_ p: String) -> URL { home.appendingPathComponent("Library").appendingPathComponent(p) }

    static let sizeKeys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    /// Dung lượng thực chiếm trên ổ (đệ quy nếu là thư mục)
    static func size(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        let keySet = Set(sizeKeys)
        if !isDir.boolValue {
            let v = try? url.resourceValues(forKeys: keySet)
            return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: sizeKeys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        for case let f as URL in en {
            guard let v = try? f.resourceValues(forKeys: keySet), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func children(_ url: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    /// Xoá nội dung bên trong thư mục (giữ lại thư mục), hoặc xoá file
    static func removeContents(_ url: URL) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            for c in children(url) { try? fm.removeItem(at: c) }
        } else {
            try? fm.removeItem(at: url)
        }
    }

    /// Chuyển vào Thùng rác (có thể khôi phục)
    @discardableResult
    static func trash(_ url: URL) -> Bool {
        do { try fm.trashItem(at: url, resultingItemURL: nil); return true } catch { return false }
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Lệnh hệ thống

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func appleScript(_ source: String) -> (ok: Bool, message: String) {
        var err: NSDictionary?
        let res = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err = err {
            return (false, (err[NSAppleScript.errorMessage] as? String) ?? "Lỗi không xác định")
        }
        return (true, res?.stringValue ?? "")
    }

    /// Chạy lệnh với quyền quản trị (macOS hỏi mật khẩu). Gọi trên luồng chính.
    @discardableResult
    static func admin(_ cmd: String) -> (ok: Bool, message: String) {
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return appleScript("do shell script \"\(escaped)\" with administrator privileges")
    }
}

// MARK: - Quyền

enum Permissions {
    /// Thử đọc vài vị trí chỉ mở được khi có quyền Truy cập toàn bộ ổ đĩa
    static var hasFullDiskAccess: Bool {
        let home = NSHomeDirectory()
        let files = [home + "/Library/Application Support/com.apple.TCC/TCC.db",
                     "/Library/Application Support/com.apple.TCC/TCC.db",
                     home + "/Library/Safari/Bookmarks.plist"]
        for f in files {
            if let h = FileHandle(forReadingAtPath: f) { try? h.close(); return true }
        }
        let dirs = [home + "/Library/Safari", home + "/Library/Mail",
                    home + "/Library/Containers/com.apple.Safari/Data/Library",
                    home + "/.Trash"]
        for d in dirs where FS.fm.fileExists(atPath: d) {
            if (try? FS.fm.contentsOfDirectory(atPath: d)) != nil { return true }
        }
        return false
    }
    static func openFullDiskAccess() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(u)
        }
    }
    static func openLoginItems() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(u)
        }
    }
}

// MARK: - Giao diện dùng chung

let brandGradient = LinearGradient(colors: [Theme.accent2, Theme.control],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)

struct PageHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    var onBack: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 14) {
            if let img = ModuleIcon.image(forSymbol: icon) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 58, height: 58)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.selectedFill).frame(width: 50, height: 50)
                    Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundColor(Theme.accent)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(.uiTitle2).bold()
                Text(L(subtitle)).font(.uiCallout).foregroundStyle(.secondary)
            }
            Spacer()
            if let back = onBack {
                Button(action: back) {
                    Label(L("Làm lại từ đầu"), systemImage: "arrow.counterclockwise")
                }
                .glassButton()
                .help(L("Xoá kết quả, quay về màn hình đầu của chức năng này"))
            }
        }
        .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 12)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon).font(.system(size: 56)).foregroundColor(Theme.accent)
            Text(L(title)).font(.uiTitle3).bold()
            Text(L(message)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            Button(L(actionTitle), action: action).glassButton(prominent: true).controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BusyView: View {
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(L(text)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BottomBar<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        HStack(spacing: 12) { content }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .glassCard(cornerRadius: 22)
            .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

struct RevealButton: View {
    let url: URL
    var body: some View {
        Button { FS.reveal(url) } label: { Image(systemName: "magnifyingglass") }
            .buttonStyle(.borderless)
            .help(L("Hiện trong Finder"))
    }
}

struct FileIcon: View {
    let url: URL
    var size: CGFloat = 26
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: size, height: size)
    }
}

/// Thay cho @State (SDK mới yêu cầu plugin macro mà Command Line Tools không có)
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Liquid Glass (macOS 26+), tự lùi về vật liệu mờ trên máy cũ

extension View {
    /// Thẻ kính trắng mờ, bo lớn, viền sáng, bóng tím rất nhẹ
    func glassCard(cornerRadius: CGFloat = 18, tint: Color? = nil) -> some View {
        self.background(RoundedRectangle(cornerRadius: cornerRadius + 4, style: .continuous).fill(tint ?? Theme.card))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius + 4, style: .continuous).stroke(Theme.cardBorder, lineWidth: 1))
            .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 6)
    }

    /// Nền viên thuốc trắng mờ (thanh điều hướng, nhãn)
    func pillSurface() -> some View {
        self.background(Capsule().fill(Color.white.opacity(0.78)))
            .overlay(Capsule().stroke(Color.white, lineWidth: 1))
            .shadow(color: Theme.ink.opacity(0.06), radius: 10, y: 4)
    }

    /// Nút chính: viên thuốc tím than; nút phụ: viên thuốc trắng
    func glassButton(prominent: Bool = false) -> some View {
        self.buttonStyle(PillButtonStyle(prominent: prominent))
    }
}

/// Nền sáng pastel để hiệu ứng kính hiện rõ
struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.94, green: 0.91, blue: 0.99),
                                    Color(red: 0.97, green: 0.93, blue: 0.98),
                                    Color(red: 0.98, green: 0.95, blue: 0.97),
                                    Color(red: 0.92, green: 0.93, blue: 0.99),
                                    Color(red: 0.91, green: 0.89, blue: 0.98)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { g in
                Circle().fill(Color(red: 0.78, green: 0.70, blue: 1.0).opacity(0.35)).frame(width: 520, height: 520).blur(radius: 120)
                    .position(x: g.size.width * 0.15, y: g.size.height * 0.2)
                Circle().fill(Color(red: 1.0, green: 0.78, blue: 0.88).opacity(0.30)).frame(width: 460, height: 460).blur(radius: 120)
                    .position(x: g.size.width * 0.85, y: g.size.height * 0.15)
                Circle().fill(Color(red: 0.74, green: 0.82, blue: 1.0).opacity(0.30)).frame(width: 500, height: 500).blur(radius: 130)
                    .position(x: g.size.width * 0.75, y: g.size.height * 0.9)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Giao diện: Liquid Glass sáng, tông xanh lá nhạt, font hệ thống (+2px)

/// Màu tự đổi theo chế độ Sáng (trắng tối giản) / Tối (than chì)
func dyn(_ l: (CGFloat, CGFloat, CGFloat), _ d: (CGFloat, CGFloat, CGFloat)) -> Color {
    Color(NSColor(name: nil) { ap in
        let dark = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let v = dark ? d : l
        return NSColor(srgbRed: v.0, green: v.1, blue: v.2, alpha: 1)
    })
}

enum Theme {
    /// Tím chủ đạo (biểu tượng, chữ nhấn)
    static let accent = Color(red: 0.46, green: 0.34, blue: 0.89)
    static let accent2 = Color(red: 0.62, green: 0.50, blue: 0.98)
    static let mint = Color(red: 0.93, green: 0.45, blue: 0.68)       // hồng phấn (điểm nhấn phụ)
    static let teal = Color(red: 0.49, green: 0.58, blue: 0.93)       // xanh dừa cạn
    /// Nút, ô tích, thanh tiến trình
    static let control = Color(red: 0.42, green: 0.29, blue: 0.85)
    /// Mực tím than: nút chính, mục đang chọn
    static let ink = Color(red: 0.23, green: 0.18, blue: 0.45)
    static let inkSoft = Color(red: 0.35, green: 0.31, blue: 0.50)
    static let iconMuted = Color(red: 0.54, green: 0.51, blue: 0.66)
    static let selectedFill = Color(red: 0.93, green: 0.90, blue: 0.99)
    static let selectedText = Color(red: 0.23, green: 0.18, blue: 0.45)
    static let page = Color(red: 0.96, green: 0.94, blue: 0.99)
    static let sidebar = Color(red: 0.95, green: 0.93, blue: 0.99)
    static let card = Color.white.opacity(0.74)
    static let cardBorder = Color.white.opacity(0.95)
}



extension Font {
    static let uiBody = Font.system(size: 15)
    static let uiCallout = Font.system(size: 14)
    static let uiCaption = Font.system(size: 12.5)
    static let uiCaption2 = Font.system(size: 11.5)
    static let uiHeadline = Font.system(size: 15, weight: .semibold)
    static let uiTitle3 = Font.system(size: 18, weight: .regular)
    static let uiTitle2 = Font.system(size: 21, weight: .regular)
    static let uiTitle = Font.system(size: 24, weight: .regular)
}

/// Vùng cuộn chuẩn cho mọi trang
struct GlassScroll<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) { content }
                .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 8)
        }
    }
}

/// Thẻ kính chứa một nhóm dòng
struct GlassSection<Content: View>: View {
    let title: String?
    let content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let t = title {
                Text(L(t)).font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 6)
            }
            content
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }
}

/// Thanh công cụ dưới tiêu đề trang
struct ToolRow<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        HStack(spacing: 12) { content }
            .padding(.horizontal, 24).padding(.bottom, 12)
    }
}

// MARK: - Nút

struct PillButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size

    func makeBody(configuration: Configuration) -> some View {
        let small = size == .small || size == .mini
        return configuration.label
            .font(.system(size: small ? 12.5 : 14, weight: .semibold))
            .foregroundColor(prominent ? .white : Theme.ink)
            .padding(.horizontal, small ? 11 : 16).padding(.vertical, small ? 5 : 8)
            .background(Capsule().fill(prominent ? Theme.ink : Color.white.opacity(0.9)))
            .overlay(Capsule().stroke(prominent ? Color.clear : Theme.ink.opacity(0.10), lineWidth: 1))
            .shadow(color: Theme.ink.opacity(prominent ? 0.18 : 0.05), radius: prominent ? 8 : 4, y: 2)
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
    }
}

struct CircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(Theme.ink)
            .frame(width: 38, height: 38)
            .background(Circle().fill(Color.white.opacity(0.92)))
            .overlay(Circle().stroke(Theme.ink.opacity(0.08), lineWidth: 1))
            .shadow(color: Theme.ink.opacity(0.08), radius: 6, y: 2)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .contentShape(Circle())
    }
}

// MARK: - Icon 3D

struct ModuleIcon: View {
    let section: AppSection
    var size: CGFloat = 64

    static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let i = cache[name] { return i }
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Icons"),
              let img = NSImage(contentsOf: dir.appendingPathComponent(name + ".png")) else { return nil }
        cache[name] = img
        return img
    }

    static func image(forSymbol sym: String) -> NSImage? {
        for s in AppSection.allCases where s.icon == sym { return image(s.asset) }
        return nil
    }

    var body: some View {
        if let img = ModuleIcon.image(section.asset) {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: section.icon).font(.system(size: size * 0.5, weight: .semibold))
                .foregroundColor(Theme.accent).frame(width: size, height: size)
        }
    }
}
