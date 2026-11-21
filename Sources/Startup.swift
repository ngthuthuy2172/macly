import SwiftUI
import AppKit

struct LaunchItem: Identifiable {
    var id: String { url.path }
    let url: URL
    let label: String
    let program: String
    let scope: Int   // 0: người dùng, 1: tác vụ chung, 2: dịch vụ hệ thống
}

enum LaunchEngine {
    static func list() -> [LaunchItem] {
        let dirs: [(URL, Int)] = [
            (FS.lib("LaunchAgents"), 0),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), 1),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), 2)
        ]
        var out: [LaunchItem] = []
        for (d, s) in dirs {
            for u in FS.children(d) where u.pathExtension == "plist" {
                let dict = (NSDictionary(contentsOf: u) as? [String: Any]) ?? [:]
                let label = (dict["Label"] as? String) ?? u.deletingPathExtension().lastPathComponent
                var prog = (dict["Program"] as? String) ?? ""
                if prog.isEmpty, let args = dict["ProgramArguments"] as? [String], let f = args.first { prog = f }
                out.append(LaunchItem(url: u, label: label, program: prog, scope: s))
            }
        }
        return out.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}

@MainActor
final class StartupModel: ObservableObject {
    @Published var items: [LaunchItem] = []
    @Published var message = ""

    func load() {
        Task.detached {
            let l = LaunchEngine.list()
            await MainActor.run { self.items = l }
        }
    }

    func remove(_ item: LaunchItem) {
        let path = item.url.path
        if item.scope == 0 {
            Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", path])
            if FS.trash(item.url) { message = "Đã gỡ \(item.label)" } else { message = "Không gỡ được \(item.label)" }
        } else {
            let domain = item.scope == 1 ? "gui/\(getuid())" : "system"
            let q = path.replacingOccurrences(of: "'", with: "'\\''")
            let trashDir = NSHomeDirectory() + "/.Trash/"
            let r = Shell.admin("/bin/launchctl bootout \(domain) '\(q)' ; /bin/mv '\(q)' '\(trashDir)'")
            message = r.ok ? "Đã gỡ \(item.label) (nằm trong Thùng rác)" : "Không gỡ được: \(r.message)"
        }
        load()
    }
}

struct StartupView: View {
    @EnvironmentObject var model: StartupModel
    @StateObject private var pending = Box<LaunchItem?>(nil)

    struct Sec: Identifiable { let id: Int; let title: String }
    let sections: [Sec] = [Sec(id: 0, title: "Tác vụ của bạn (~/Library/LaunchAgents)"),
                           Sec(id: 1, title: "Tác vụ chung (/Library/LaunchAgents)"),
                           Sec(id: 2, title: "Dịch vụ hệ thống (/Library/LaunchDaemons)")]

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Khởi động cùng máy", subtitle: "Các tác vụ nền tự chạy khi bật máy – gỡ bớt để máy khởi động nhanh hơn", icon: "power")
            HStack {
                Button { Permissions.openLoginItems() } label: { Label(L("Mở Mục đăng nhập trong Cài đặt"), systemImage: "gearshape") }.glassButton()
                Spacer()
                if !model.message.isEmpty { Text(L(model.message)).font(.uiCallout).foregroundStyle(.secondary) }
                Button(L("Làm mới")) { model.load() }.glassButton()
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
            GlassScroll {
                ForEach(sections) { sec in
                    GlassSection(sec.title) {
                        let list = model.items.filter { $0.scope == sec.id }
                        if list.isEmpty {
                            Text(L("Không có")).foregroundStyle(.secondary)
                        }
                        ForEach(list) { item in
                            LaunchRow(item: item) { pending.value = item }
                        }
                    }
                }
            }
        }
        .onAppear { model.load() }
        .confirmationDialog(L("Gỡ \(pending.value?.label ?? "")?"), isPresented: Binding(get: { pending.value != nil }, set: { if !$0 { pending.value = nil } })) {
            Button(L("Gỡ"), role: .destructive) {
                if let p = pending.value { model.remove(p) }
                pending.value = nil
            }
        } message: {
            Text(L("Tác vụ sẽ dừng và tệp cấu hình được chuyển vào Thùng rác. Ứng dụng liên quan có thể tạo lại khi mở."))
        }
    }
}

struct LaunchRow: View {
    let item: LaunchItem
    let onRemove: () -> Void
    var body: some View {
        let icon: String = item.scope == 2 ? "gearshape.2" : "bolt.horizontal.circle"
        let sub: String = item.program.isEmpty ? shortPath(item.url) : item.program
        return HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(L(item.label)).lineLimit(1)
                Text(L(sub)).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            RevealButton(url: item.url)
            Button(L("Gỡ"), action: onRemove).glassButton().controlSize(.small)
        }
        .padding(.vertical, 5)
    }
}
