import SwiftUI
import Security
import UniformTypeIdentifiers

// MARK: - Model

enum Status {
    case ready, building, failed, unknown
    init(_ s: String) {
        switch s.uppercased() {
        case "READY": self = .ready
        case "BUILDING", "QUEUED", "INITIALIZING": self = .building
        case "ERROR", "CANCELED": self = .failed
        default: self = .unknown
        }
    }
    var color: Color {
        switch self {
        case .ready: return .green
        case .building: return .orange
        case .failed: return .red
        case .unknown: return .gray
        }
    }
    var label: String {
        switch self {
        case .ready: return "Ready"
        case .building: return "Building"
        case .failed: return "Failed"
        case .unknown: return "Unknown"
        }
    }
    var nsColor: NSColor {
        switch self {
        case .ready: return .systemGreen
        case .building: return .systemOrange
        case .failed: return .systemRed
        case .unknown: return .systemGray
        }
    }
    var severity: Int {
        switch self { case .failed: return 3; case .building: return 2; case .ready: return 1; case .unknown: return 0 }
    }
}

struct Deploy: Identifiable {
    let id: String      // project name
    var hash: String
    var status: Status
    var error: String?
    var message: String? = nil
    var url: URL? = nil
}

// MARK: - Keychain

enum Keychain {
    static let service = "VercelWatch"
    static func get() -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
    static func set(_ v: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
        guard !v.isEmpty else { return }
        SecItemAdd(q.merging([kSecValueData as String: Data(v.utf8)]) { $1 } as CFDictionary, nil)
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var token = Keychain.get()
    @Published var projects = UserDefaults.standard.string(forKey: "projects") ?? ""
    @Published var teamId = UserDefaults.standard.string(forKey: "teamId") ?? ""
    @Published var logo = UserDefaults.standard.string(forKey: "logo") ?? "triangle" {
        didSet { UserDefaults.standard.set(logo, forKey: "logo") }
    }
    @Published var logoPath = UserDefaults.standard.string(forKey: "logoPath") ?? "" {
        didSet { UserDefaults.standard.set(logoPath, forKey: "logoPath") }
    }
    @Published var deploys: [Deploy] = []
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func save() {
        Keychain.set(token)
        UserDefaults.standard.set(projects, forKey: "projects")
        UserDefaults.standard.set(teamId, forKey: "teamId")
        Task { await refresh() }
    }

    var names: [String] {
        projects.split(whereSeparator: { ",\n ".contains($0) }).map(String.init)
    }

    func chooseLogo() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .svg, .jpeg, .tiff, .icns]
        if p.runModal() == .OK, let u = p.url { logoPath = u.path }
    }

    var menuImage: NSImage {
        if logo == "custom", let img = NSImage(contentsOfFile: logoPath) {
            img.size = NSSize(width: 16, height: 16)
            img.isTemplate = true
            return img
        }
        return shapeImage(logo == "custom" ? "triangle" : logo, color: worst.nsColor)
    }

    var worst: Status { deploys.map(\.status).max { $0.severity < $1.severity } ?? .unknown }

    func refresh() async {
        guard !token.isEmpty else { deploys = []; return }
        let token = token, team = teamId
        deploys = await withTaskGroup(of: Deploy.self) { group in
            for n in names { group.addTask { await Self.fetch(n, token: token, team: team) } }
            var out: [Deploy] = []
            for await d in group { out.append(d) }
            let order = names
            return out.sorted { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! }
        }
    }

    nonisolated static func fetch(_ project: String, token: String, team: String) async -> Deploy {
        var c = URLComponents(string: "https://api.vercel.com/v6/deployments")!
        c.queryItems = [.init(name: "app", value: project), .init(name: "limit", value: "10"), .init(name: "target", value: "production")]
        if !team.isEmpty { c.queryItems?.append(.init(name: "teamId", value: team)) }
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                return Deploy(id: project, hash: "HTTP \(http.statusCode)", status: .unknown, error: "HTTP \(http.statusCode)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = (json["deployments"] as? [[String: Any]])?.first(where: {
                      (($0["state"] as? String) ?? ($0["readyState"] as? String) ?? "") != "CANCELED"
                  }) else {
                return Deploy(id: project, hash: "no deploys", status: .unknown, error: nil)
            }
            let meta = d["meta"] as? [String: Any]
            let sha = (meta?["githubCommitSha"] as? String) ?? (meta?["gitlabCommitSha"] as? String)
                ?? (meta?["bitbucketCommitSha"] as? String)
            let hash = sha.map { String($0.prefix(7)) } ?? String(((d["uid"] as? String) ?? "").suffix(7))
            let state = (d["state"] as? String) ?? (d["readyState"] as? String) ?? ""
            let msg = (meta?["githubCommitMessage"] as? String) ?? (meta?["gitlabCommitMessage"] as? String)
                ?? (meta?["bitbucketCommitMessage"] as? String)
            let link = (d["inspectorUrl"] as? String).flatMap(URL.init(string:))
            return Deploy(id: project, hash: hash, status: Status(state), error: nil, message: msg, url: link)
        } catch {
            return Deploy(id: project, hash: "offline", status: .unknown, error: error.localizedDescription)
        }
    }
}

// MARK: - Views

struct Pill: View {
    let status: Status
    var body: some View {
        Circle().fill(status.color).frame(width: 14, height: 14)
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.deploys.isEmpty {
                Text(store.token.isEmpty ? "Add an API token and projects." : "Nothing to show.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.deploys) { d in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Pill(status: d.status)
                        Text(d.id).fontWeight(.medium)
                        Spacer()
                        Text(d.hash).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    if let m = d.message?.split(separator: "\n").first {
                        Text(m)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.leading, 24)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    NSWorkspace.shared.open(d.url ?? URL(string: "https://vercel.com/dashboard")!)
                }
            }
            Divider()
            if editing {
                SecureField("Vercel API token", text: $store.token)
                TextField("Projects (comma separated)", text: $store.projects)
                TextField("Team ID (optional)", text: $store.teamId)
                HStack {
                    Text("Logo")
                    Picker("", selection: $store.logo) {
                        Text("Triangle").tag("triangle")
                        Text("Circle").tag("circle")
                        Text("Pill").tag("pill")
                        Text("Status dot").tag("status")
                        Text("Custom image").tag("custom")
                    }.labelsHidden()
                    if store.logo == "custom" {
                        Button("Choose…") { store.chooseLogo() }
                    }
                }
                HStack {
                    Spacer()
                    Button("Save") { store.save(); editing = false }.keyboardShortcut(.defaultAction)
                }
            }
            HStack {
                Button(editing ? "Cancel" : "Settings") { editing.toggle() }
                Button("Refresh") { Task { await store.refresh() } }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .frame(width: 320)
    }
}

func shapeImage(_ style: String, color: NSColor) -> NSImage {
    let colored = style == "status"
    let img = NSImage(size: NSSize(width: style == "pill" ? 26 : 16, height: 16), flipped: false) { r in
        (colored ? color : NSColor.black).setFill()
        switch style {
        case "circle", "status":
            NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill()
        case "pill":
            let b = r.insetBy(dx: 1, dy: 2.5)
            NSBezierPath(roundedRect: b, xRadius: b.height / 2, yRadius: b.height / 2).fill()
        default:
            let t = NSBezierPath()
            t.move(to: NSPoint(x: r.midX, y: r.maxY - 2))
            t.line(to: NSPoint(x: r.maxX - 1.5, y: r.minY + 2.5))
            t.line(to: NSPoint(x: r.minX + 1.5, y: r.minY + 2.5))
            t.close()
            t.fill()
        }
        return true
    }
    img.isTemplate = !colored
    return img
}

@main
struct VercelWatchApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            Image(nsImage: store.menuImage)
        }
        .menuBarExtraStyle(.window)
    }
}
