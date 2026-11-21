import SwiftUI
import IOKit

struct BatteryInfo {
    var present = false
    var percent = 0
    var cycles = 0
    var designCycles = 1000
    var health: Double? = nil
    var designMah: Int? = nil
    var maxMah: Int? = nil
    var tempC: Double? = nil
    var charging = false
    var plugged = false
    var voltage: Double? = nil
    var watts: Double? = nil
    var timeRemaining: Int? = nil   // phút

    var statusText: String {
        if charging { return "Đang sạc" }
        if plugged { return "Đã cắm sạc" }
        return "Đang dùng pin"
    }
    var healthText: String {
        guard let h = health else { return "—" }
        return String(format: "%.0f%%", h * 100)
    }
    var healthNote: String {
        guard let h = health else { return "Không đọc được" }
        if h >= 0.9 { return "Tốt" }
        if h >= 0.8 { return "Bình thường" }
        return "Nên kiểm tra / thay pin"
    }
}

enum BatteryEngine {
    static func read() -> BatteryInfo {
        var info = BatteryInfo()
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return info }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return info }
        func num(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        func flag(_ k: String) -> Bool { (d[k] as? NSNumber)?.boolValue ?? false }

        info.present = true
        let cur = num("CurrentCapacity") ?? 0
        let maxCap = num("MaxCapacity") ?? 100
        info.percent = maxCap == 100 ? cur : Int((Double(cur) / Double(max(maxCap, 1)) * 100).rounded())
        info.cycles = num("CycleCount") ?? 0
        info.designCycles = num("DesignCycleCount9C") ?? 1000
        info.designMah = num("DesignCapacity")
        info.maxMah = num("AppleRawMaxCapacity") ?? num("NominalChargeCapacity") ?? (maxCap > 100 ? maxCap : nil)
        if let m = info.maxMah, let ds = info.designMah, ds > 0 { info.health = min(1.0, Double(m) / Double(ds)) }
        if let t = num("Temperature") { info.tempC = Double(t) / 100.0 }
        info.charging = flag("IsCharging")
        info.plugged = flag("ExternalConnected")
        if let v = num("Voltage") {
            info.voltage = Double(v) / 1000.0
            if let a = num("Amperage") { info.watts = abs(Double(v) * Double(a)) / 1_000_000.0 }
        }
        if let tr = num("TimeRemaining"), tr > 0, tr < 6000 { info.timeRemaining = tr }
        return info
    }
}

struct BatteryView: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        let b = monitor.battery
        return VStack(spacing: 0) {
            PageHeader(title: "Pin", subtitle: "Tình trạng pin, số lần sạc và nhiệt độ – cập nhật mỗi 2 giây", icon: "battery.75percent")
            if !b.present {
                Text(L("Máy này không có pin (hoặc macOS không cho đọc thông tin pin)."))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GlassScroll {
                    HStack(spacing: 28) {
                        ZStack {
                            Circle().stroke(Theme.cardBorder, lineWidth: 14)
                            Circle().trim(from: 0, to: CGFloat(b.percent) / 100)
                                .stroke(b.percent <= 20 ? Color.orange : Theme.control, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            VStack(spacing: 2) {
                                Text(L("\(b.percent)%")).font(.system(size: 34, weight: .bold)).monospacedDigit()
                                Text(L(b.statusText)).font(.uiCaption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 150, height: 150)
                        VStack(alignment: .leading, spacing: 8) {
                            Label(L(b.statusText), systemImage: b.charging ? "bolt.fill" : (b.plugged ? "powerplug.fill" : "battery.75percent"))
                                .font(.uiHeadline)
                            if let m = b.timeRemaining {
                                Text(L(b.charging ? "Còn khoảng \(m / 60) giờ \(m % 60) phút để đầy" : "Dùng được khoảng \(m / 60) giờ \(m % 60) phút"))
                                    .foregroundStyle(.secondary)
                            }
                            Text(L("Tình trạng pin: \(b.healthText) – \(b.healthNote)")).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(22)
                    .glassCard(cornerRadius: 20)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                        StatCard(title: "Tình trạng pin", icon: "heart.fill", value: b.healthText,
                                 sub: b.healthNote, progress: b.health ?? 0)
                        StatCard(title: "Số lần sạc", icon: "arrow.triangle.2.circlepath", value: "\(b.cycles) lần",
                                 sub: "Thiết kế cho \(b.designCycles) lần", progress: Double(b.cycles) / Double(max(b.designCycles, 1)))
                        StatCard(title: "Nhiệt độ pin", icon: "thermometer.medium",
                                 value: b.tempC.map { String(format: "%.1f°C", $0) } ?? "—",
                                 sub: (b.tempC ?? 0) > 40 ? "Hơi nóng" : "Bình thường",
                                 progress: min(1, (b.tempC ?? 0) / 50))
                        StatCard(title: "Dung lượng tối đa", icon: "battery.100percent",
                                 value: b.maxMah.map { "\($0) mAh" } ?? "—",
                                 sub: b.designMah.map { "Lúc mới: \($0) mAh" } ?? "",
                                 progress: b.health ?? 0)
                        StatCard(title: "Điện áp", icon: "bolt", value: b.voltage.map { String(format: "%.2f V", $0) } ?? "—",
                                 sub: "Điện áp hiện tại của pin", progress: 0)
                        StatCard(title: "Công suất", icon: "gauge.with.dots.needle.33percent",
                                 value: b.watts.map { String(format: "%.1f W", $0) } ?? "—",
                                 sub: b.charging ? "Đang nạp vào pin" : "Máy đang tiêu thụ", progress: min(1, (b.watts ?? 0) / 60))
                    }
                }
            }
        }
    }
}
