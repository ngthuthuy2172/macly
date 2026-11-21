import SwiftUI

struct MaintTask: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let admin: Bool
    let command: String
}

let maintTasks: [MaintTask] = [
    MaintTask(id: "ram", title: "Giải phóng RAM", detail: "Xoá bộ nhớ đệm không hoạt động (purge)", icon: "memorychip", admin: true,
              command: "/usr/sbin/purge"),
    MaintTask(id: "dns", title: "Xả bộ đệm DNS", detail: "Sửa lỗi không vào được web, đổi DNS chưa có hiệu lực", icon: "network", admin: true,
              command: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"),
    MaintTask(id: "spotlight", title: "Đánh chỉ mục lại Spotlight", detail: "Khi Spotlight tìm sai hoặc thiếu kết quả (chạy ngầm khá lâu)", icon: "magnifyingglass", admin: true,
              command: "/usr/bin/mdutil -E /"),
    MaintTask(id: "tm", title: "Xoá snapshot Time Machine cục bộ", detail: "Lấy lại dung lượng do snapshot cục bộ chiếm", icon: "clock.arrow.circlepath", admin: true,
              command: "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4"),
    MaintTask(id: "ls", title: "Dựng lại Launch Services", detail: "Sửa menu \"Mở bằng\" bị trùng lặp, biểu tượng ứng dụng sai", icon: "arrow.triangle.2.circlepath", admin: false,
              command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -r -domain local -domain system -domain user"),
    MaintTask(id: "ql", title: "Làm mới Quick Look", detail: "Xoá bộ đệm xem nhanh (phím cách)", icon: "eye", admin: false,
              command: "/usr/bin/qlmanage -r cache; /usr/bin/qlmanage -r"),
    MaintTask(id: "dock", title: "Khởi động lại Dock & Finder", detail: "Khi Dock hoặc Finder bị đơ", icon: "dock.rectangle", admin: false,
              command: "/usr/bin/killall Dock; /usr/bin/killall Finder")
]

struct MaintenanceView: View {
    @StateObject private var running = Box<String?>(nil)
    @StateObject private var results = Box<[String: String]>([:])

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Bảo trì", subtitle: "Các công cụ bảo trì giúp máy chạy mượt hơn", icon: "wrench.and.screwdriver.fill")
            GlassScroll { ForEach(maintTasks) { t in
                HStack(spacing: 12) {
                    Image(systemName: t.icon).font(.uiTitle3).foregroundColor(Theme.accent).frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(L(t.title)).bold()
                            if t.admin {
                                Image(systemName: "lock.fill").font(.uiCaption).foregroundStyle(.secondary).help(L("Cần mật khẩu quản trị"))
                            }
                        }
                        Text(L(t.detail)).font(.uiCaption).foregroundStyle(.secondary)
                        if let r = results.value[t.id] {
                            Text(L(r)).font(.uiCaption).foregroundColor(r.hasPrefix("✓") ? .green : .orange)
                        }
                    }
                    Spacer()
                    if running.value == t.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L("Chạy")) { run(t) }.glassButton().disabled(running.value != nil)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .glassCard(cornerRadius: 20)
            } }
        }
    }

    func run(_ t: MaintTask) {
        running.value = t.id
        if t.admin {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                let r = Shell.admin(t.command)
                results.value[t.id] = r.ok ? "✓ Đã xong" : "Đã huỷ hoặc lỗi: \(r.message)"
                running.value = nil
            }
        } else {
            let cmd = t.command
            Task.detached {
                Shell.run("/bin/sh", ["-c", cmd])
                await MainActor.run {
                    results.value[t.id] = "✓ Đã xong"
                    running.value = nil
                }
            }
        }
    }
}
