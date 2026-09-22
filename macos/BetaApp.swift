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

private struct BetaRun: Identifiable {
    let id = UUID()
    let date: Date
    let summary: String
    let failed: Bool
}

@MainActor
private final class BetaStore: ObservableObject {
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
                runs.append(BetaRun(date: date, summary: summary.isEmpty ? "Sem alterações" : summary,
                                    failed: !line.hasSuffix("exit=0")))
                started = nil
            }
        }
        return Array(runs.suffix(30).reversed())
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

private struct BetaPanel: View {
    @ObservedObject var store: BetaStore
    @State private var confirmActivation = false
    private let sidebar = Color(red: 0.11, green: 0.13, blue: 0.16)
    private let canvas = Color(red: 0.965, green: 0.974, blue: 0.978)

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reminders Sync").font(.system(size: 14, weight: .semibold))
                    Text("BETA · Apple ↔ Google").font(.system(size: 10)).foregroundStyle(.white.opacity(0.58))
                }
                .padding(.horizontal, 18).padding(.top, 25).padding(.bottom, 28)
                ForEach(BetaStore.Page.allCases, id: \.self) { page in
                    Button { store.page = page } label: {
                        Label(page.rawValue, systemImage: page.icon)
                            .font(.system(size: 12, weight: store.page == page ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(store.page == page ? Color.white.opacity(0.13) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain).padding(.horizontal, 10)
                }
                Spacer()
                HStack(spacing: 7) {
                    Circle().fill(store.enabled && store.ready ? .green : .orange).frame(width: 7, height: 7)
                    Text(store.statusText).font(.system(size: 10)).lineLimit(1)
                }
                .padding(.horizontal, 18).padding(.bottom, 16)
                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("Encerrar aplicativo", systemImage: "power")
                        .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).padding(18)
            }
            .foregroundStyle(.white).frame(width: 172).background(sidebar)

            VStack(alignment: .leading, spacing: 0) {
                switch store.page {
                case .overview: overview
                case .accounts: accounts
                case .history: history
                case .settings: settings
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(canvas)
        }
        .frame(width: 690, height: 500)
        .preferredColorScheme(.light)
        .onAppear { store.refresh() }
        .alert("Ativar sincronização?", isPresented: $confirmActivation) {
            Button("Ativar e aplicar") { store.activate() }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("As ações da prévia poderão criar ou atualizar tarefas no Google Tasks e no Apple Lembretes. Revise a lista antes de continuar.")
        }
    }

    private func title(_ headline: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(headline).font(.system(size: 21, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 24)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 17) {
            title("Visão geral", "O aplicativo executa a sincronização enquanto estiver aberto na barra de menus.")
            HStack(spacing: 12) {
                Image(systemName: store.enabled && store.ready ? "checkmark.circle" : "pause.circle")
                    .font(.system(size: 25)).foregroundStyle(store.enabled && store.ready ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.statusText).font(.system(size: 15, weight: .semibold))
                    Text("\(store.mappingCount) tarefas ligadas · verificação a cada 5 minutos")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(17).background(.white).clipShape(RoundedRectangle(cornerRadius: 12))
            if !store.ready {
                Text("Configure Apple Lembretes e Google Tasks na aba Contas antes de iniciar.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Abrir Contas") { store.page = .accounts }
            } else {
                if store.legacyInstallationPresent {
                    Text("O sincronizador anterior foi detectado neste Mac. A beta não pode ser ativada até migrarmos o estado e desligarmos o serviço antigo.")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                Text("Primeira ativação: faça uma prévia sem alterações e confira o plano.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button("Calcular prévia") { store.preview() }.disabled(store.working)
                    if store.previewReady && !store.enabled {
                        Button("Ativar sincronização") { confirmActivation = true }
                            .disabled(store.working || store.legacyInstallationPresent)
                            .buttonStyle(.borderedProminent)
                    }
                    if store.enabled {
                        Button("Sincronizar agora") { store.syncNow() }.disabled(store.working)
                        Button("Pausar") { store.pause() }
                    }
                }
                if !store.previewSummary.isEmpty {
                    Text(store.previewSummary).font(.system(size: 11, design: .monospaced))
                        .padding(10).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if store.previewReady {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(store.previewActions.indices, id: \.self) { index in
                                Text(store.previewActions[index]).font(.system(size: 10.5)).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if store.previewActions.isEmpty {
                                Text("Nenhuma alteração planejada.").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 110)
                }
            }
            if !store.notice.isEmpty { Text(store.notice).font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(24)
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Contas", "Cada pessoa usa seu próprio projeto Google Cloud; nenhum JSON é compartilhado.")
            accountCard("Apple Lembretes", detail: store.appleAuthorized ? "Acesso concedido" : "Permissão necessária", icon: "checklist") {
                Button(store.appleAuthorized ? "Verificar" : "Autorizar") { store.requestAppleAccess() }
            }
            accountCard("Cliente OAuth do Google", detail: store.hasClient ? "JSON importado neste Mac" : "Crie um cliente do tipo Aplicativo para computador", icon: "key.horizontal") {
                Button("Importar JSON") { store.importGoogleClient() }
            }
            accountCard("Google Tasks", detail: store.hasToken ? "Conta conectada" : "Conecte sua conta pessoal no Safari", icon: "checkmark.circle") {
                Button(store.hasToken ? "Verificar" : "Conectar") { store.connectGoogle() }
                    .disabled(!store.hasClient || store.working)
            }
            Text("No Google Cloud: ative a Tasks API, configure a tela de consentimento, crie um cliente OAuth para computador e baixe o JSON. Adicione seu e-mail como testador se o projeto estiver em modo Teste.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !store.notice.isEmpty { Text(store.notice).font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(24)
    }

    private func accountCard<Actions: View>(_ name: String, detail: String, icon: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            actions()
        }
        .padding(14).background(.white).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Histórico", "Últimas execuções desta instalação")
            if store.history.isEmpty {
                Text("Nenhuma sincronização executada ainda.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.history) { run in
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(run.failed ? .red : .green).frame(width: 7, height: 7).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(run.failed ? "Execução com erro" : "Sincronização concluída")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(run.summary).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(run.date, style: .time).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 12)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(24)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 17) {
            title("Ajustes", "Controle quando o Reminders Sync funciona.")
            Toggle("Abrir ao iniciar sessão no Mac", isOn: Binding(
                get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }
            ))
            .font(.system(size: 12))
            Divider()
            Text("Fechar o painel mantém o aplicativo na barra de menus. Encerrar o aplicativo interrompe as verificações automáticas. Seus dados e histórico ficam neste Mac.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.ready && !store.enabled {
                Button("Retomar sincronização") { store.resume() }
            }
            if !store.notice.isEmpty { Text(store.notice).font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(24)
    }
}

@MainActor
final class BetaAppDelegate: NSObject, NSApplicationDelegate {
    private let store = BetaStore()
    private var item: NSStatusItem?
    private var panel: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = Self.statusImage()
        status.button?.toolTip = "Reminders Sync Beta"
        status.button?.target = self
        status.button?.action = #selector(toggle)
        item = status
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 690, height: 500)
        popover.contentViewController = NSHostingController(rootView: BetaPanel(store: store))
        panel = popover
        DispatchQueue.main.async { self.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return true
    }

    @objc private func toggle() {
        if panel?.isShown == true { panel?.performClose(nil) }
        else { show() }
    }

    private func show() {
        guard let button = item?.button, let panel else { return }
        store.refresh()
        if !panel.isShown { panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
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
