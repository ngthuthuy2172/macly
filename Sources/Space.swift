import SwiftUI
import AppKit

struct SpaceItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
    let isDir: Bool
}

enum SpaceEngine {
    static func children(of url: URL, ignore: (URL) -> Bool, progress: (String) -> Void) -> [SpaceItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let kids = (try? FS.fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        var out: [SpaceItem] = []
        for k in kids {
            if ignore(k) { continue }
            // Tránh đếm trùng các ổ gắn ngoài / vùng hệ thống ảo
            if ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm"].contains(k.path) { continue }
            guard let v = try? k.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            progress(k.lastPathComponent)
            let s = FS.size(of: k)
            guard s > 0 else { continue }
            let isDir = v.isDirectory == true && v.isPackage != true
            out.append(SpaceItem(url: k, name: FS.fm.displayName(atPath: k.path), size: s, isDir: isDir))
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Thuật toán treemap "squarified": chia hình chữ nhật thành các ô gần vuông theo tỉ lệ dung lượng
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var r = rect
        var i = 0
        func worst(_ row: [Double], _ side: Double) -> Double {
            let s = row.reduce(0, +)
            guard s > 0, let mx = row.max(), let mn = row.min(), mn > 0, side > 0 else { return .infinity }
            return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
        }
        while i < areas.count {
            let side = Double(min(r.width, r.height))
            var row = [i]
            var best = worst([areas[i]], side)
            var j = i + 1
            while j < areas.count {
                let w = worst(row.map { areas[$0] } + [areas[j]], side)
                if w <= best { row.append(j); best = w; j += 1 } else { break }
            }
            let rowSum = row.map { areas[$0] }.reduce(0, +)
            if r.width >= r.height {
                let colW = CGFloat(rowSum / Double(max(r.height, 1)))
                var y = r.minY
                for k in row {
                    let h = CGFloat(areas[k]) / max(colW, 0.0001)
                    result[k] = CGRect(x: r.minX, y: y, width: colW, height: h)
                    y += h
                }
                r = CGRect(x: r.minX + colW, y: r.minY, width: max(0, r.width - colW), height: r.height)
            } else {
                let rowH = CGFloat(rowSum / Double(max(r.width, 1)))
                var x = r.minX
                for k in row {
                    let w = CGFloat(areas[k]) / max(rowH, 0.0001)
                    result[k] = CGRect(x: x, y: r.minY, width: w, height: rowH)
                    x += w
                }
                r = CGRect(x: r.minX, y: r.minY + rowH, width: r.width, height: max(0, r.height - rowH))
            }
            i = j
        }
        return result
    }
}

@MainActor
final class SpaceModel: ObservableObject {
    @Published var stack: [URL] = []
    @Published var items: [SpaceItem] = []
    @Published var scanning = false
    @Published var status = ""
    @Published var selected: Set<UUID> = []
    private var cache: [String: [SpaceItem]] = [:]

    var current: URL? { stack.last }
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func displayName(_ u: URL) -> String {
        u.path == "/" ? "Macintosh HD" : FS.fm.displayName(atPath: u.path)
    }

    func start(_ url: URL) {
        stack = [url]
        cache = [:]
        load(url)
    }

    func open(_ item: SpaceItem) {
        guard item.isDir, !scanning else { return }
        stack.append(item.url)
        load(item.url)
    }

    func up() {
        guard stack.count > 1, !scanning else { return }
        stack.removeLast()
        if let u = stack.last { load(u) }
    }

    func jump(_ index: Int) {
        guard index < stack.count, !scanning else { return }
        stack = Array(stack.prefix(index + 1))
        if let u = stack.last { load(u) }
    }

    func reset() {
        guard !scanning else { return }
        stack = []
        items = []
        cache = [:]
        selected = []
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.directoryURL = FS.home
        p.prompt = L("Chọn")
        if p.runModal() == .OK, let u = p.url { start(u) }
    }

    private func load(_ url: URL) {
        selected = []
        if let c = cache[url.path] { items = c; return }
        scanning = true
        status = "Đang đo dung lượng…"
        items = []
        let ign = IgnoreList.matcher()
        Task.detached(priority: .userInitiated) {
            let res = SpaceEngine.children(of: url, ignore: ign) { n in
                Task { @MainActor in self.status = "Đang đo: " + n }
            }
            await MainActor.run {
                self.cache[url.path] = res
                if self.current == url { self.items = res }
                self.scanning = false
            }
        }
    }

    func trashSelected() {
        let targets = items.filter { selected.contains($0.id) }
        Task.detached {
            var done = Set<UUID>()
            var freed: Int64 = 0
            for t in targets where FS.trash(t.url) {
                done.insert(t.id)
                freed += t.size
            }
            let d = done
            let f = freed
            await MainActor.run {
                self.items.removeAll { d.contains($0.id) }
                self.cache = [:]
                if let c = self.current { self.cache[c.path] = self.items }
                self.selected = []
                Shared.history.add("Bản đồ dung lượng", "\(d.count) mục chuyển vào Thùng rác", f)
            }
        }
    }
}

struct SpaceView: View {
    @EnvironmentObject var model: SpaceModel
    @StateObject private var confirm = Box(false)

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Bản đồ dung lượng", subtitle: "Xem thư mục nào chiếm nhiều chỗ nhất – bấm vào ô để đi sâu vào trong", icon: "square.grid.3x3.square",
                       onBack: model.stack.isEmpty || model.scanning ? nil : { model.reset() })
            if model.stack.isEmpty {
                startView
            } else {
                ToolRow {
                    ForEach(Array(model.stack.enumerated()), id: \.offset) { i, u in
                        if i > 0 { Image(systemName: "chevron.right").font(.uiCaption).foregroundStyle(.secondary) }
                        Button(L(model.displayName(u))) { model.jump(i) }
                            .buttonStyle(.plain)
                            .foregroundColor(i == model.stack.count - 1 ? Theme.selectedText : .secondary)
                            .font(i == model.stack.count - 1 ? Font.uiBody.weight(.semibold) : Font.uiBody)
                    }
                    Spacer()
                    Text(L("Tổng \(fmt(model.total))")).monospacedDigit().foregroundStyle(.secondary)
                }
                if model.scanning {
                    BusyView(text: model.status)
                } else if model.items.isEmpty {
                    Text(L("Thư mục trống hoặc không đọc được")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        TreemapView(items: model.items, selected: model.selected) { it in
                            if it.isDir { model.open(it) } else { toggle(it) }
                        }
                        .padding(8)
                        .glassCard(cornerRadius: 20)
                        listPanel.frame(width: 320)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 4)
                }
            }
            if !model.stack.isEmpty {
                BottomBar {
                    Button { model.up() } label: { Label(L("Lên một cấp"), systemImage: "arrow.up") }
                        .glassButton().disabled(model.stack.count < 2 || model.scanning)
                    Spacer()
                    Text(L("Đã chọn \(model.selected.count) · \(fmt(model.selectedSize))")).monospacedDigit()
                    Button(L("Chuyển vào Thùng rác")) { confirm.value = true }
                        .glassButton(prominent: true).disabled(model.selected.isEmpty)
                }
            }
        }
        .alert(L("Chuyển \(model.selected.count) mục vào Thùng rác?"), isPresented: $confirm.value) {
            Button(L("Huỷ"), role: .cancel) {}
            Button(L("Chuyển vào Thùng rác"), role: .destructive) { model.trashSelected() }
        } message: {
            Text(L("Tổng \(fmt(model.selectedSize)). Bạn vẫn có thể khôi phục từ Thùng rác."))
        }
    }

    func toggle(_ it: SpaceItem) {
        if model.selected.contains(it.id) { model.selected.remove(it.id) } else { model.selected.insert(it.id) }
    }

    var startView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "square.grid.3x3.square").font(.system(size: 56)).foregroundColor(Theme.accent)
            Text(L("Chọn nơi muốn xem")).font(.uiTitle3).bold()
            Text(L("App đo dung lượng từng thư mục rồi vẽ thành các ô – ô càng to càng chiếm nhiều chỗ."))
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(spacing: 12) {
                Button { model.start(FS.home) } label: { Label(L("Thư mục cá nhân"), systemImage: "house") }
                    .glassButton(prominent: true).controlSize(.large)
                Button { model.start(URL(fileURLWithPath: "/")) } label: { Label(L("Toàn bộ ổ đĩa"), systemImage: "internaldrive") }
                    .glassButton().controlSize(.large)
                Button { model.chooseFolder() } label: { Label(L("Chọn thư mục…"), systemImage: "folder") }
                    .glassButton().controlSize(.large)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var listPanel: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.items) { it in
                    HStack(spacing: 8) {
                        Toggle(L(""), isOn: Binding(get: { model.selected.contains(it.id) },
                                                 set: { v in if v { model.selected.insert(it.id) } else { model.selected.remove(it.id) } }))
                            .toggleStyle(.checkbox).labelsHidden()
                        FileIcon(url: it.url, size: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L(it.name)).lineLimit(1).truncationMode(.middle)
                            GeometryReader { g in
                                Capsule().fill(Theme.control.opacity(0.8))
                                    .frame(width: g.size.width * CGFloat(Double(it.size) / Double(max(model.items.first?.size ?? 1, 1))))
                            }
                            .frame(height: 3)
                        }
                        Text(L(fmt(it.size))).font(.uiCaption).monospacedDigit().foregroundStyle(.secondary)
                        if it.isDir {
                            Button { model.open(it) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                        } else {
                            RevealButton(url: it.url)
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 10)
                }
            }
            .padding(.vertical, 8)
        }
        .glassCard(cornerRadius: 20)
    }
}

struct TreemapView: View {
    let items: [SpaceItem]
    let selected: Set<UUID>
    let onTap: (SpaceItem) -> Void

    var body: some View {
        GeometryReader { g in
            let shown = Array(items.prefix(60))
            let rects = SpaceEngine.squarify(shown.map { Double($0.size) }, in: CGRect(origin: .zero, size: g.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { idx, it in
                    TreeTile(item: it, rect: rects[idx], index: idx, selected: selected.contains(it.id))
                        .onTapGesture { onTap(it) }
                }
            }
        }
        .frame(minHeight: 300)
    }
}

struct TreeTile: View {
    let item: SpaceItem
    let rect: CGRect
    let index: Int
    let selected: Bool

    static let dirColors: [Color] = [
        Color(red: 0.55, green: 0.45, blue: 0.90), Color(red: 0.62, green: 0.52, blue: 0.94),
        Color(red: 0.47, green: 0.37, blue: 0.84), Color(red: 0.68, green: 0.58, blue: 0.96),
        Color(red: 0.52, green: 0.42, blue: 0.86)
    ]
    static let fileColors: [Color] = [
        Color(red: 0.90, green: 0.55, blue: 0.72), Color(red: 0.93, green: 0.62, blue: 0.78),
        Color(red: 0.52, green: 0.62, blue: 0.92)
    ]

    var body: some View {
        let r = rect.insetBy(dx: 2, dy: 2)
        let colors = item.isDir ? TreeTile.dirColors : TreeTile.fileColors
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(colors[index % colors.count])
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selected ? Color.orange : Color.white.opacity(0.15), lineWidth: selected ? 3 : 1)
            if r.width > 74 && r.height > 36 {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: item.isDir ? "folder.fill" : "doc.fill").font(.system(size: 11))
                        Text(L(item.name)).font(.uiCaption.weight(.semibold)).lineLimit(1)
                    }
                    Text(L(fmt(item.size))).font(.uiCaption2).monospacedDigit()
                }
                .foregroundColor(.white)
                .padding(8)
            }
        }
        .frame(width: max(r.width, 0), height: max(r.height, 0))
        .contentShape(Rectangle())
        .offset(x: r.minX, y: r.minY)
        .help(L("\(item.name) – \(fmt(item.size))" + (item.isDir ? " · bấm để xem bên trong" : " · bấm để chọn")))
    }
}
