import SwiftUI

struct DiskInfo {
    var total: Int64 = 0
    var free: Int64 = 0
    var used: Int64 { max(0, total - free) }
}

enum SystemInfo {
    static func disk() -> DiskInfo {
        let u = URL(fileURLWithPath: "/")
        guard let v = try? u.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return DiskInfo() }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        return DiskInfo(total: total, free: free)
    }
}

struct StatCard: View {
    let title: String
    let icon: String
    let value: String
    let sub: String
    let progress: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L(title), systemImage: icon).font(.uiHeadline)
            Text(L(value)).font(.uiTitle3).bold().monospacedDigit()
            ProgressView(value: min(max(progress, 0), 1)).tint(progress > 0.85 ? .red : Theme.accent)
            Text(L(sub)).font(.uiCaption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }
}

struct OverviewView: View {
    @EnvironmentObject var junk: JunkScanner
    @EnvironmentObject var memory: MemoryModel
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var history: HistoryModel
    @Binding var selection: AppSection?
    @StateObject private var confirm = Box(false)

    var busy: Bool { junk.scanning || junk.cleaning }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                // Thẻ lớn ở giữa
                VStack(spacing: 12) {
                    ZStack {
                        ModuleIcon(section: .overview, size: 190)
                            .scaleEffect(busy ? 0.94 : 1)
                            .animation(busy ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: busy)
                        if busy { ProgressView().controlSize(.large).offset(y: 110) }
                    }
                    .frame(height: 200)
                    .onTapGesture { startScan() }
                    if busy {
                        Text(L(junk.cleaning ? "Đang dọn dẹp…" : "Đang quét…")).font(.system(size: 28, weight: .bold)).foregroundColor(Theme.ink)
                        Text(L(junk.status)).font(.uiCallout).foregroundColor(Theme.inkSoft).lineLimit(1)
                    } else if junk.scannedOnce {
                        Text(L("\(fmt(junk.totalSelected)) rác có thể dọn")).font(.system(size: 30, weight: .bold)).foregroundColor(Theme.ink).monospacedDigit()
                        Text(L("Bộ nhớ đệm, nhật ký, tệp tải dở và Thùng rác")).font(.uiCallout).foregroundColor(Theme.inkSoft)
                    } else {
                        Text(L("Quét thông minh")).font(.system(size: 30, weight: .bold)).foregroundColor(Theme.ink)
                        Text(L("Kiểm tra nhanh rác, ổ đĩa và RAM chỉ với một nút bấm")).font(.uiCallout).foregroundColor(Theme.inkSoft)
                    }
                    HStack(spacing: 12) {
                        if junk.scannedOnce && !busy {
                            Button { selection = .junk } label: { Label(L("Xem chi tiết"), systemImage: "list.bullet") }
                                .glassButton().controlSize(.large)
                            Button { confirm.value = true } label: { Label(L("Dọn ngay"), systemImage: "checkmark") }
                                .glassButton(prominent: true).controlSize(.large)
                                .disabled(junk.totalSelected == 0)
                            Button { startScan() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(CircleButtonStyle()).help(L("Quét lại"))
                        } else if !busy {
                            Button { startScan() } label: { Label(L("Bắt đầu quét"), systemImage: "sparkles") }
                                .glassButton(prominent: true).controlSize(.large)
                        }
                    }
                    .padding(.top, 4)
                    if let f = junk.lastFreed, !busy {
                        Label(L("Vừa giải phóng \(fmt(f))"), systemImage: "checkmark.seal.fill").foregroundColor(.green).font(.uiHeadline)
                    } else if history.totalFreed > 0 && !busy {
                        Text(L("Mác-li đã giúp bạn giải phóng tổng cộng \(fmt(history.totalFreed))"))
                            .font(.uiCallout).foregroundColor(Theme.inkSoft)
                    }
                }
                .padding(.vertical, 26).padding(.horizontal, 30)
                .frame(maxWidth: 640)
                .glassCard(cornerRadius: 32)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
                    StatCard(title: "Ổ đĩa", icon: "internaldrive.fill",
                             value: "\(fmt(monitor.disk.free)) trống",
                             sub: "Đã dùng \(fmt(monitor.disk.used)) / \(fmt(monitor.disk.total))",
                             progress: Double(monitor.disk.used) / Double(max(monitor.disk.total, 1)))
                    StatCard(title: "Bộ nhớ RAM", icon: "memorychip",
                             value: "\(fmt(monitor.ramUsed)) đang dùng",
                             sub: "Tổng \(fmt(monitor.ramTotal)) · \(monitor.ramText)",
                             progress: monitor.ramPercent / 100)
                    StatCard(title: "Pin", icon: "battery.75percent",
                             value: monitor.battery.present ? "\(monitor.battery.percent)%" : "Không có pin",
                             sub: monitor.battery.present ? "\(monitor.battery.statusText) · \(monitor.battery.cycles) lần sạc" : "",
                             progress: Double(monitor.battery.percent) / 100)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                    QuickLink(section: .browsers) { selection = .browsers }
                    QuickLink(section: .ai) { selection = .ai }
                    QuickLink(section: .space) { selection = .space }
                    QuickLink(section: .large) { selection = .large }
                    QuickLink(section: .uninstaller) { selection = .uninstaller }
                }
            }
            .frame(maxWidth: 1080)
            .padding(.horizontal, 28).padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
        .onAppear { memory.refresh() }
        .alert(L("Dọn \(fmt(junk.totalSelected)) rác?"), isPresented: $confirm.value) {
            Button(L("Huỷ"), role: .cancel) {}
            Button(L("Dọn dẹp"), role: .destructive) { junk.clean() }
        } message: {
            Text(L("Bộ nhớ đệm và nhật ký sẽ bị xoá (ứng dụng tự tạo lại), Thùng rác sẽ được dọn sạch."))
        }
    }

    func startScan() {
        guard !busy else { return }
        junk.scan()
        memory.refresh()
        monitor.refreshDisk()
    }
}

struct QuickLink: View {
    let section: AppSection
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ModuleIcon(section: section, size: 56)
                Text(L(section.title)).foregroundColor(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .padding(.vertical, 14).padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .glassCard(cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }
}
