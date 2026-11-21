import SwiftUI
import AppKit
import Combine
import Darwin

struct MemStats {
    var total: Int64 = 0
    var used: Int64 = 0
    var app: Int64 = 0
    var wired: Int64 = 0
    var compressed: Int64 = 0
    var cached: Int64 = 0
    var free: Int64 = 0
    var swap: Int64 = 0
    var usedRatio: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct ProcInfo: Identifiable {
    let id: Int32
    let name: String
    let rss: Int64
    let isApp: Bool
    var path: String = ""
}

struct ProcGroup: Identifiable {
    let id: String
    let name: String
    let bundleURL: URL?
    var procs: [ProcInfo]
    var total: Int64
}

enum MemEngine {
    static func stats() -> MemStats {
        var s = MemStats()
        s.total = Int64(ProcessInfo.processInfo.physicalMemory)
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return s }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let p = Int64(pageSize)
        let internalPages = Int64(vm.internal_page_count)
        let purgeable = Int64(vm.purgeable_count)
        s.app = max(0, internalPages - purgeable) * p
        s.wired = Int64(vm.wire_count) * p
        s.compressed = Int64(vm.compressor_page_count) * p
        s.cached = (Int64(vm.external_page_count) + purgeable) * p
        s.used = s.app + s.wired + s.compressed
        s.free = max(0, s.total - s.used)
        var xsw = xsw_usage()
        var sz = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &sz, nil, 0) == 0 { s.swap = Int64(xsw.xsu_used) }
        return s
    }

    static func topProcesses(limit: Int = 25) -> [ProcInfo] {
        Array(allProcesses().sorted { $0.rss > $1.rss }.prefix(limit))
    }

    /// Mọi tiến trình: pid, RAM, đường dẫn chương trình
    static func allProcesses() -> [ProcInfo] {
        let out = Shell.run("/bin/ps", ["-axo", "pid=,rss=,comm="])
        var list: [ProcInfo] = []
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let rss = Int64(parts[1]), rss > 0 else { continue }
            let path = String(parts[2])
            list.append(ProcInfo(id: pid, name: (path as NSString).lastPathComponent, rss: rss * 1024, isApp: false, path: path))
        }
        return list
    }

    /// Gom các tiến trình phụ (Helper, Renderer…) vào ứng dụng chứa nó
    static func groupedProcesses(limit: Int = 25) -> [ProcGroup] {
        var groups: [String: ProcGroup] = [:]
        for p in allProcesses() {
            var key = "proc:" + p.path
            var bundle: URL? = nil
            if let r = p.path.range(of: ".app/") {
                let bp = String(p.path[..<r.lowerBound]) + ".app"
                key = bp
                bundle = URL(fileURLWithPath: bp)
            }
            if groups[key] == nil {
                let name = bundle.map { FS.fm.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? p.name
                groups[key] = ProcGroup(id: key, name: name, bundleURL: bundle, procs: [], total: 0)
            }
            groups[key]!.procs.append(p)
            groups[key]!.total += p.rss
        }
        return Array(groups.values)
            .map { g in var g2 = g; g2.procs.sort { $0.rss > $1.rss }; return g2 }
            .sorted { $0.total > $1.total }
            .prefix(limit)
            .map { $0 }
    }
}

@MainActor
final class MemoryModel: ObservableObject {
    @Published var stats = MemStats()
    @Published var procs: [ProcInfo] = []
    @Published var groups: [ProcGroup] = []
    @Published var expanded: Set<String> = []
    @Published var busy = false
    @Published var message = ""

    func refresh() {
        Task.detached(priority: .utility) {
            let s = MemEngine.stats()
            let p: [ProcInfo] = []
            let g = MemEngine.groupedProcesses()
            await MainActor.run {
                self.stats = s
                self.groups = g
                self.procs = p.map { pr in
                    let app = NSRunningApplication(processIdentifier: pr.id)
                    return ProcInfo(id: pr.id, name: app?.localizedName ?? pr.name, rss: pr.rss,
                                    isApp: app?.activationPolicy == .regular)
                }
            }
        }
    }

    private var timer: Timer?

    func startAuto() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            Task { @MainActor in s.refresh() }
        }
    }

    func stopAuto() {
        timer?.invalidate()
        timer = nil
    }

    func purge() {
        guard !busy else { return }
        busy = true
        message = "Đang giải phóng RAM…"
        let before = stats.used
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            let r = Shell.admin("/usr/sbin/purge")
            let after = MemEngine.stats()
            self.stats = after
            self.busy = false
            if r.ok {
                self.message = "Đã giải phóng khoảng \(fmt(max(0, before - after.used)))"
            } else {
                self.message = "Đã huỷ hoặc không chạy được: \(r.message)"
            }
            self.refresh()
        }
    }

    /// Ứng dụng đang chạy tương ứng với nhóm (để hiện nút Thoát)
    func runningApp(_ g: ProcGroup) -> NSRunningApplication? {
        guard let b = g.bundleURL?.standardizedFileURL.path else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.bundleURL?.standardizedFileURL.path == b
        }
    }

    func quitGroup(_ g: ProcGroup) {
        runningApp(g)?.terminate()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self.refresh()
        }
    }

    func toggle(_ g: ProcGroup) {
        if expanded.contains(g.id) { expanded.remove(g.id) } else { expanded.insert(g.id) }
    }

    func quit(_ pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self.refresh()
        }
    }
}

struct MemoryBar: View {
    let s: MemStats
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let t = Double(max(s.total, 1))
            HStack(spacing: 0) {
                Rectangle().fill(Theme.accent).frame(width: w * Double(s.app) / t)
                Rectangle().fill(Theme.mint).frame(width: w * Double(s.wired) / t)
                Rectangle().fill(Color.orange).frame(width: w * Double(s.compressed) / t)
                Spacer(minLength: 0)
            }
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(height: 16)
    }
}

struct LegendDot: View {
    let color: Color
    let title: String
    let value: Int64
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(L(title)).foregroundStyle(.secondary)
            Text(L(fmt(value))).monospacedDigit()
        }
        .font(.uiCallout)
    }
}

struct MemoryView: View {
    @EnvironmentObject var memory: MemoryModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Bộ nhớ RAM", subtitle: "Theo dõi RAM và giải phóng bộ nhớ", icon: "memorychip")
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("Đang dùng \(fmt(memory.stats.used))")).font(.uiTitle2).bold().monospacedDigit()
                    Text(L("/ \(fmt(memory.stats.total))")).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        memory.purge()
                    } label: {
                        Label(L("Giải phóng RAM"), systemImage: "wind")
                    }
                    .glassButton(prominent: true).controlSize(.large).disabled(memory.busy)
                }
                MemoryBar(s: memory.stats)
                HStack(spacing: 18) {
                    LegendDot(color: Theme.accent, title: "Ứng dụng", value: memory.stats.app)
                    LegendDot(color: Theme.mint, title: "Bộ nhớ cố định", value: memory.stats.wired)
                    LegendDot(color: .orange, title: "Đã nén", value: memory.stats.compressed)
                    LegendDot(color: .secondary, title: "Đệm tệp", value: memory.stats.cached)
                    LegendDot(color: .gray, title: "Swap", value: memory.stats.swap)
                }
                if !memory.message.isEmpty {
                    Text(L(memory.message)).font(.uiCallout).foregroundColor(.green)
                }
            }
            .padding(18)
            .glassCard(cornerRadius: 20)
            .padding(.horizontal, 24).padding(.bottom, 14)
            GlassScroll { GlassSection("Ứng dụng dùng nhiều RAM nhất · bấm để xem các tiến trình con") {
                ForEach(memory.groups) { g in
                    ProcGroupRow(group: g, expanded: memory.expanded.contains(g.id),
                                 canQuit: memory.runningApp(g) != nil,
                                 onToggle: { memory.toggle(g) }, onQuit: { memory.quitGroup(g) })
                }
            } }
        }
        .onAppear { memory.startAuto() }
        .onDisappear { memory.stopAuto() }
    }
}

struct ProcGroupRow: View {
    let group: ProcGroup
    let expanded: Bool
    let canQuit: Bool
    let onToggle: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14)
                    .opacity(group.procs.count > 1 ? 1 : 0)
                if let b = group.bundleURL {
                    FileIcon(url: b, size: 22)
                } else {
                    Image(systemName: "gearshape").frame(width: 22, height: 22).foregroundStyle(.secondary)
                }
                Text(L(group.name)).lineLimit(1)
                if group.procs.count > 1 {
                    Text(L("\(group.procs.count) tiến trình")).font(.uiCaption).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.selectedFill))
                }
                Spacer()
                Text(L(fmt(group.total))).monospacedDigit()
                if canQuit {
                    Button(L("Thoát"), action: onQuit).glassButton().controlSize(.small)
                } else {
                    Text(L("")).frame(width: 56)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { if group.procs.count > 1 { withAnimation(.easeInOut(duration: 0.15)) { onToggle() } } }

            if expanded {
                VStack(spacing: 0) {
                    ForEach(group.procs) { p in
                        HStack(spacing: 10) {
                            Text(L(p.name)).font(.uiCallout).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text(L(fmt(p.rss))).font(.uiCallout).monospacedDigit().foregroundStyle(.secondary)
                            Text(L("")).frame(width: 56)
                        }
                        .padding(.vertical, 3)
                        .padding(.leading, 56)
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }
}
