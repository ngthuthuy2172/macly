import SwiftUI
import AppKit

/// Thông tin tóm tắt + hành động chính của từng chức năng trên băng chuyền
struct ModuleSummary: View {
    @EnvironmentObject var junk: JunkScanner
    @EnvironmentObject var browsers: BrowserModel
    @EnvironmentObject var ai: AIModelsModel
    @EnvironmentObject var large: LargeModel
    @EnvironmentObject var dups: DupModel
    @EnvironmentObject var apps: UninstallModel
    @EnvironmentObject var startup: StartupModel
    @EnvironmentObject var updates: UpdatesModel
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var history: HistoryModel
    @EnvironmentObject var settings: AppSettings
    let section: AppSection
    var big: Bool

    var body: some View {
        let t = texts
        return VStack(spacing: big ? 6 : 4) {
            Text(L(t.0))
                .font(.system(size: big ? 30 : 17, weight: .bold))
                .foregroundColor(Theme.ink)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(L(t.1))
                .font(big ? .uiCallout : .uiCaption)
                .foregroundColor(Theme.inkSoft)
                .multilineTextAlignment(.center).lineLimit(2)
        }
    }

    var texts: (String, String) {
        switch section {
        case .junk:
            return (junk.scanning ? "Đang quét…" : (junk.scannedOnce ? "\(fmt(junk.totalFound)) rác" : "Chưa quét"),
                    "Bộ nhớ đệm, nhật ký, tệp tải dở, Thùng rác")
        case .browsers:
            return (browsers.scanning ? "Đang quét…" : (browsers.scannedOnce ? fmt(browsers.total(settings)) : "Chưa quét"),
                    settings.cleanCookies ? "Bộ đệm, cookie" + (settings.cleanHistory ? ", lịch sử" : "") : "Bộ đệm trình duyệt · giữ cookie")
        case .ai:
            return (ai.scanning ? "Đang quét…" : (ai.scannedOnce ? fmt(ai.total(ai.items)) : "Chưa quét"),
                    "Rác do công cụ AI để lại và mô hình đã tải")
        case .space:
            return ("\(fmt(monitor.disk.used)) đã dùng", "Còn trống \(fmt(monitor.disk.free)) · xem thư mục nào chiếm chỗ")
        case .large:
            return (large.scanning ? "Đang quét…" : (large.scannedOnce ? "\(large.files.count) file lớn" : "Chưa quét"),
                    "File trên \(large.minMB) MB trong thư mục của bạn")
        case .duplicates:
            return (dups.scanning ? "Đang quét…" : (dups.scannedOnce ? "\(fmt(dups.wasted)) trùng" : "Chưa quét"),
                    "So sánh nội dung để tìm bản sao")
        case .uninstaller:
            return (apps.apps.isEmpty ? "Gỡ sạch ứng dụng" : "\(apps.apps.count) ứng dụng", "Gỡ kèm tệp cài đặt, bộ đệm còn sót")
        case .startup:
            return ("\(startup.items.count) tác vụ nền", "Chạy cùng máy – gỡ bớt cho máy nhẹ hơn")
        case .updates:
            if updates.checking { return ("Đang kiểm tra…", "Homebrew và ứng dụng tự cập nhật") }
            return (updates.updates.isEmpty ? "Đã cập nhật" : "\(updates.updates.count) bản mới",
                    updates.lastCheck.map { "Kiểm tra lúc " + UpdatesCard.dateFmt.string(from: $0) } ?? "Chưa kiểm tra")
        case .memory:
            return ("RAM \(monitor.ramText)", "\(fmt(monitor.ramUsed)) / \(fmt(monitor.ramTotal)) đang dùng")
        case .battery:
            let b = monitor.battery
            return (b.present ? "\(b.percent)%" : "Không có pin",
                    b.present ? "\(b.statusText) · tình trạng \(b.healthText) · \(b.cycles) lần sạc" : "Máy không có pin")
        case .maintenance:
            return ("7 công cụ", "Xả DNS, Spotlight, Time Machine, Launch Services…")
        case .history:
            return (fmt(history.totalFreed), "Đã giải phóng qua \(history.records.count) lần dọn")
        default:
            return (section.title, "")
        }
    }
}

struct CarouselView: View {
    @EnvironmentObject var nav: NavState
    @EnvironmentObject var settings: AppSettings
    let group: NavGroup

    var modules: [AppSection] { group.modules }
    var idx: Int { min(nav.idx(group), max(modules.count - 1, 0)) }
    func at(_ o: Int) -> AppSection { modules[(idx + o + modules.count) % modules.count] }

    var body: some View {
        VStack(spacing: 18) {
            if !modules.isEmpty {
                HStack(spacing: 22) {
                    if modules.count > 1 {
                        SideCard(section: at(-1)) { slide(-1) }
                    }
                    CenterCard(section: at(0),
                               onPrev: { slide(-1) }, onNext: { slide(1) },
                               onOpen: { nav.open(at(0)) })
                    if modules.count > 1 {
                        SideCard(section: at(1)) { slide(1) }
                    }
                }
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 24)
                .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                    if v.translation.width < -40 { slide(1) } else if v.translation.width > 40 { slide(-1) }
                })

                // Hàng chức năng
                HStack(spacing: 10) {
                    Text(L("Chức năng")).font(.uiCallout).foregroundColor(Theme.inkSoft).padding(.trailing, 4)
                    ForEach(Array(modules.enumerated()), id: \.element) { i, m in
                        let on = i == idx
                        Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { nav.index[group] = i } } label: {
                            VStack(spacing: 4) {
                                ModuleIcon(section: m, size: 40)
                                Text(L(m.short)).font(.uiCaption.weight(on ? .semibold : .regular)).lineLimit(1)
                            }
                            .foregroundColor(on ? Theme.ink : Theme.inkSoft)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(on ? Theme.selectedFill : Color.white.opacity(0.85)))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(on ? Theme.accent.opacity(0.45) : Color.white, lineWidth: on ? 1.5 : 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .glassCard(cornerRadius: 22)
                .padding(.horizontal, 24)
            }

            // Công tắc nhanh
            HStack(spacing: 12) {
                QuickToggle(title: "Hiện trên thanh menu", isOn: $settings.showMenuBar)
                QuickToggle(title: "Dọn cookie trình duyệt", isOn: $settings.cleanCookies)
                QuickToggle(title: "Hiện pin & RAM ở trên", isOn: Binding(
                    get: { settings.showBattery || settings.showRAM },
                    set: { v in settings.showBattery = v; settings.showRAM = v }))
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .padding(.top, 14)
        .onAppear { if group == .apps { Shared.startup.load() } }
    }

    func slide(_ d: Int) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { nav.move(d) }
    }
}

struct CenterCard: View {
    @EnvironmentObject var junk: JunkScanner
    @EnvironmentObject var browsers: BrowserModel
    @EnvironmentObject var ai: AIModelsModel
    @EnvironmentObject var large: LargeModel
    @EnvironmentObject var dups: DupModel
    let section: AppSection
    let onPrev: () -> Void
    let onNext: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ModuleIcon(section: section, size: 170)
                .id(section)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            Text(L(section.title)).font(.system(size: 26, weight: .bold)).foregroundColor(Theme.ink)
            ModuleSummary(section: section, big: true)
            HStack(spacing: 12) {
                Button(action: onPrev) { Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold)) }
                    .buttonStyle(CircleButtonStyle())
                Button(action: primary) {
                    Label(L(primaryTitle), systemImage: primaryIcon).padding(.horizontal, 6)
                }
                .glassButton(prominent: true)
                .controlSize(.large)
                Button(action: onNext) { Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)) }
                    .buttonStyle(CircleButtonStyle())
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(maxWidth: 560, maxHeight: .infinity)
        .glassCard(cornerRadius: 32)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }

    var needsScan: Bool {
        switch section {
        case .junk: return !junk.scannedOnce
        case .browsers: return !browsers.scannedOnce
        case .ai: return !ai.scannedOnce
        case .large: return !large.scannedOnce
        case .duplicates: return !dups.scannedOnce
        default: return false
        }
    }
    var primaryTitle: String {
        if needsScan { return "Quét ngay" }
        switch section {
        case .junk, .browsers, .ai, .large, .duplicates: return "Xem & dọn"
        case .space: return "Mở bản đồ"
        default: return "Mở"
        }
    }
    var primaryIcon: String { needsScan ? "sparkles" : "arrow.right" }

    func primary() {
        if needsScan {
            switch section {
            case .junk: junk.scan()
            case .browsers: browsers.scan()
            case .ai: ai.scan()
            case .large: large.scan()
            case .duplicates: dups.scan()
            default: break
            }
        }
        onOpen()
    }
}

struct SideCard: View {
    let section: AppSection
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                ModuleIcon(section: section, size: 110)
                Text(L(section.title)).font(.uiHeadline).foregroundColor(Theme.ink)
                ModuleSummary(section: section, big: false)
            }
            .padding(20)
            .frame(maxWidth: 300, maxHeight: 360)
            .glassCard(cornerRadius: 28, tint: Color.white.opacity(hover.value ? 0.7 : 0.45))
            .opacity(hover.value ? 1 : 0.8)
            .scaleEffect(hover.value ? 0.97 : 0.92)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover.value = h } }
        .help(L("Chuyển sang \(section.title)"))
    }
}

struct QuickToggle: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            Text(L(title)).foregroundColor(Theme.ink).lineLimit(1).minimumScaleFactor(0.85)
            Spacer()
            Toggle(L(""), isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(Theme.control)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .glassCard(cornerRadius: 20)
    }
}
