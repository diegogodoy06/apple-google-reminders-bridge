import AppKit
import EventKit
import Foundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

private enum BetaPaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RemindersSyncBeta")
    static let secrets = root.appendingPathComponent("secrets")
    static let runtime = root.appendingPathComponent("runtime")
    static let client = secrets.appendingPathComponent("google-client.json")
    static let token = secrets.appendingPathComponent("google-token.json")
    static let state = runtime.appendingPathComponent("state.json")
    static let log = runtime.appendingPathComponent("sync.log")
    static let errors = runtime.appendingPathComponent("errors.log")
    static let plan = runtime.appendingPathComponent("latest-plan.json")
    static let engine = Bundle.main.resourceURL!.appendingPathComponent("RemindersSyncBridge")
    static let reminders = Bundle.main.resourceURL!.appendingPathComponent("remindctl")

    static func prepare() throws {
        for directory in [root, secrets, runtime] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}

struct BetaRun: Identifiable {
    let id = UUID()
    let date: Date
    let summary: String
    let failed: Bool
    let appleToGoogle: Int
    let googleToApple: Int
}

@MainActor
final class BetaStore: ObservableObject {
    @Published var page: Page = .accounts
    @Published var hasClient = false
    @Published var hasToken = false
    @Published var appleAuthorized = false
    @Published var working = false
    @Published var enabled = UserDefaults.standard.bool(forKey: "beta.syncEnabled")
    @Published var previewReady = false
    @Published var previewSummary = ""
    @Published var previewActions: [String] = []
    @Published var notice = ""
    @Published var history: [BetaRun] = []
    @Published var mappingCount = 0
    @Published var ignoredCount: Int?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var legacyInstallationPresent = false

    enum Page: String, CaseIterable {
        case overview = "Visão geral"
        case accounts = "Contas"
        case history = "Histórico"
        case settings = "Ajustes"

        var icon: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .accounts: return "person.crop.circle"
            case .history: return "clock.arrow.circlepath"
            case .settings: return "gearshape"
            }
        }
    }

    private let eventStore = EKEventStore()
    private var timer: Timer?
    private var lastAttempt: Date?

    init() {
        refresh()
        page = hasClient && hasToken ? .overview : .accounts
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var ready: Bool { hasClient && hasToken && appleAuthorized }
    var lastChecked: Date? { lastAttempt ?? history.first?.date }
    var nextCheck: Date? {
        guard enabled, ready, let lastChecked else { return nil }
        return lastChecked.addingTimeInterval(300)
    }
    var statusText: String {
        if working { return "Sincronizando" }
        if !ready { return "Configuração pendente" }
        return enabled ? "Em funcionamento" : "Pausado"
    }

    func refresh() {
        hasClient = FileManager.default.fileExists(atPath: BetaPaths.client.path)
        hasToken = FileManager.default.fileExists(atPath: BetaPaths.token.path)
        let authorization = EKEventStore.authorizationStatus(for: .reminder)
        if #available(macOS 14.0, *) {
            appleAuthorized = authorization == .fullAccess
        } else {
            appleAuthorized = authorization == .authorized
        }
        history = Self.readHistory()
        if let data = try? Data(contentsOf: BetaPaths.state),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mappings = object["mappings"] as? [String: Any] {
            mappingCount = mappings.count
        }
        if let data = try? Data(contentsOf: BetaPaths.plan),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let actions = object["actions"] as? [[String: Any]] {
            ignoredCount = actions.filter {
                ["unchanged", "skip"].contains($0["kind"] as? String ?? "")
            }.count
        }
        let agents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: agents.path)) ?? []
        legacyInstallationPresent = names.contains { $0.contains("apple-google-reminders-bridge") && $0.hasSuffix(".plist") }
    }

    func requestAppleAccess() {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToReminders { [weak self] granted, error in
                DispatchQueue.main.async {
                    self?.refresh()
                    self?.notice = granted ? "Acesso aos Lembretes concedido." : (error?.localizedDescription ?? "Acesso aos Lembretes não concedido.")
                }
            }
        } else {
            eventStore.requestAccess(to: .reminder) { [weak self] granted, error in
                DispatchQueue.main.async {
                    self?.refresh()
                    self?.notice = granted ? "Acesso aos Lembretes concedido." : (error?.localizedDescription ?? "Acesso aos Lembretes não concedido.")
                }
            }
        }
    }

    func importGoogleClient() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Selecione o JSON do cliente OAuth para aplicativo de computador."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let data = try Data(contentsOf: source)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let installed = object["installed"] as? [String: Any],
                  let clientID = installed["client_id"] as? String,
                  clientID.hasSuffix(".apps.googleusercontent.com") else {
                notice = "Este arquivo não é um cliente OAuth do tipo Aplicativo para computador."
                return
            }
            if hasToken {
                notice = "Uma conta já está conectada. Não substitua o cliente OAuth durante uma sincronização ativa."
                return
            }
            try BetaPaths.prepare()
            try data.write(to: BetaPaths.client, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: BetaPaths.client.path)
            refresh()
            notice = "Cliente OAuth importado. Agora conecte sua conta Google."
        } catch {
            notice = "Não foi possível importar: \(error.localizedDescription)"
        }
    }

    func connectGoogle() {
        guard hasClient, !working else { return }
        do { try BetaPaths.prepare() }
        catch { notice = error.localizedDescription; return }
        working = true
        notice = "Aguardando autorização no Safari…"
        execute(
            ["--authorize-only", "--credentials", BetaPaths.client.path,
             "--token", BetaPaths.token.path, "--google-browser", "safari"]
        ) { [weak self] code, output in
            self?.working = false
            self?.refresh()
            self?.notice = code == 0 && self?.hasToken == true
                ? "Conta Google conectada."
                : "A conexão não terminou. Verifique o OAuth no Google Cloud e tente novamente."
        }
    }

    func preview() {
        guard ready, !working else { return }
        runSync(apply: false)
    }

    func activate() {
        guard previewReady, ready, !working else { return }
        guard !legacyInstallationPresent else {
            notice = "O sincronizador antigo está instalado neste Mac. A migração precisa ser feita antes de ativar a beta para evitar duas execuções."
            return
        }
        enabled = true
        UserDefaults.standard.set(true, forKey: "beta.syncEnabled")
        runSync(apply: true)
    }

    func pause() {
        enabled = false
        UserDefaults.standard.set(false, forKey: "beta.syncEnabled")
        notice = working ? "Pausado. A execução atual será concluída." : "Sincronização pausada."
    }

    func resume() {
        guard ready else { page = .accounts; return }
        guard !legacyInstallationPresent else {
            notice = "O sincronizador antigo ainda está instalado. A beta permanece pausada."
            return
        }
        enabled = true
        UserDefaults.standard.set(true, forKey: "beta.syncEnabled")
        tick(force: true)
    }

    func syncNow() {
        guard ready, enabled, !working else { return }
        runSync(apply: true)
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            notice = value ? "Abertura no login ativada." : "Abertura no login desativada."
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            notice = "Não foi possível alterar a abertura no login: \(error.localizedDescription)"
        }
    }

    private func tick(force: Bool = false) {
        refresh()
        guard enabled, ready, !working else { return }
        let reference = lastAttempt ?? history.first?.date ?? .distantPast
        if force || Date().timeIntervalSince(reference) >= 300 { runSync(apply: true) }
    }

    private func runSync(apply: Bool) {
        do { try BetaPaths.prepare() }
        catch { notice = error.localizedDescription; return }
        working = true
        lastAttempt = Date()
        notice = apply ? "Sincronizando…" : "Calculando prévia sem alterar tarefas…"
        var arguments = [
            "--remindctl", BetaPaths.reminders.path,
            "--credentials", BetaPaths.client.path,
            "--token", BetaPaths.token.path,
            "--state", BetaPaths.state.path,
            "--plan-json", BetaPaths.plan.path,
            "--tasklist-id", "@default",
            "--timezone", TimeZone.current.identifier,
            "--direction", "bidirectional",
            "--summary-only",
        ]
        if apply { arguments += ["--apply", "--confirm", "APPLY"] }
        execute(arguments, logRun: apply) { [weak self] code, output in
            guard let self else { return }
            self.working = false
            self.refresh()
            if code == 0 {
                if apply {
                    self.notice = "Sincronização concluída."
                } else {
                    self.previewReady = true
                    self.previewSummary = output.split(separator: "\n").first(where: { $0.hasPrefix("Summary:") }).map(String.init) ?? "Prévia concluída."
                    self.previewActions = Self.readPreviewActions()
                    self.notice = "Prévia concluída. Confira as ações antes de ativar."
                }
            } else {
                self.notice = "Não foi possível \(apply ? "sincronizar" : "calcular a prévia"). Consulte o histórico e as permissões."
            }
        }
    }

    private func execute(
        _ arguments: [String],
        logRun: Bool = false,
        completion: @escaping (Int32, String) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = BetaPaths.engine
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            let started = ISO8601DateFormatter().string(from: Date())
            var status: Int32 = -1
            var output = ""
            do {
                try process.run()
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                status = process.terminationStatus
                output = String(data: data, encoding: .utf8) ?? ""
            } catch {
                output = error.localizedDescription
            }
            if logRun {
                let finished = ISO8601DateFormatter().string(from: Date())
                let logText = "\(started) sync started\n\(output)\n\(finished) sync finished exit=\(status)\n"
                Self.append(logText, to: BetaPaths.log)
                if status != 0 { Self.append("\(finished) \(output)\n", to: BetaPaths.errors) }
            }
            DispatchQueue.main.async { completion(status, output) }
        }
    }

    private nonisolated static func append(_ text: String, to url: URL) {
        let data = Data(text.utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static func readHistory() -> [BetaRun] {
        guard let text = try? String(contentsOf: BetaPaths.log, encoding: .utf8) else { return [] }
        let formatter = ISO8601DateFormatter()
        var runs: [BetaRun] = []
        var started: Date?
        var summary = ""
        for line in text.split(separator: "\n").suffix(2_000) {
            if line.hasSuffix(" sync started") {
                started = formatter.date(from: String(line.prefix(20)))
                summary = ""
            } else if line.hasPrefix("Summary: ") {
                summary = String(line.dropFirst(9))
            } else if line.contains(" sync finished exit="), let date = started {
                let counts = Dictionary(uniqueKeysWithValues: summary.split(separator: ",").compactMap { field -> (String, Int)? in
                    let parts = field.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                    guard parts.count == 2, let value = Int(parts[1]) else { return nil }
                    return (String(parts[0]), value)
                })
                runs.append(BetaRun(date: date, summary: summary.isEmpty ? "Sem alterações" : summary,
                                    failed: !line.hasSuffix("exit=0"),
                                    appleToGoogle: counts["create_google", default: 0] + counts["update_google", default: 0],
                                    googleToApple: counts["update_apple", default: 0]))
                started = nil
            }
        }
        return Array(runs.suffix(400).reversed())
    }

    private static func readPreviewActions() -> [String] {
        guard let data = try? Data(contentsOf: BetaPaths.plan),
              let plan = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actions = plan["actions"] as? [[String: Any]] else { return [] }
        return actions.compactMap { action in
            let kind = action["kind"] as? String ?? ""
            guard !["unchanged", "skip"].contains(kind) else { return nil }
            let title = action["title"] as? String ?? "Sem título"
            return "\(kind.replacingOccurrences(of: "_", with: " ").capitalized): \(title)"
        }
    }
}

@MainActor
final class BetaAppDelegate: NSObject, NSApplicationDelegate {
    private let store = BetaStore()
    private var item: NSStatusItem?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = Self.statusImage()
        status.button?.toolTip = "Reminders Sync Beta"
        status.button?.target = self
        status.button?.action = #selector(toggle)
        item = status
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Reminders Sync Beta"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 960, height: 620)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.contentView = NSHostingView(rootView: BetaPanel(store: store))
        self.window = window
        DispatchQueue.main.async { self.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return true
    }

    @objc private func toggle() {
        show()
    }

    private func show() {
        guard let window else { return }
        store.refresh()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private static func statusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let outline = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 14, height: 13), xRadius: 2, yRadius: 2)
            outline.lineWidth = 1.3
            outline.stroke()
            let details = NSBezierPath()
            details.lineWidth = 1.25
            details.lineCapStyle = .round
            details.move(to: NSPoint(x: 2.8, y: 11.2))
            details.line(to: NSPoint(x: 15.2, y: 11.2))
            details.move(to: NSPoint(x: 6, y: 16))
            details.line(to: NSPoint(x: 6, y: 13.7))
            details.move(to: NSPoint(x: 12, y: 16))
            details.line(to: NSPoint(x: 12, y: 13.7))
            details.move(to: NSPoint(x: 7.5, y: 8))
            details.line(to: NSPoint(x: 13, y: 8))
            details.move(to: NSPoint(x: 7.5, y: 5))
            details.line(to: NSPoint(x: 12, y: 5))
            details.stroke()
            NSBezierPath(ovalIn: NSRect(x: 4.6, y: 7.3, width: 1.4, height: 1.4)).fill()
            NSBezierPath(ovalIn: NSRect(x: 4.6, y: 4.3, width: 1.4, height: 1.4)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

@main
struct RemindersSyncBetaApp: App {
    @NSApplicationDelegateAdaptor(BetaAppDelegate.self) private var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}
