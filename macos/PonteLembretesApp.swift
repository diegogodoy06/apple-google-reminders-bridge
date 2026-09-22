import AppKit
import Combine
import Foundation
import SwiftUI

private let applicationSupportName = "AppleGoogleRemindersBridge"
private let serviceNameFragment = "apple-google-reminders-bridge"

enum ServiceState: String {
    case running
    case syncing
    case paused
    case attention

    var title: String {
        switch self {
        case .running: return "Em funcionamento"
        case .syncing: return "Sincronizando agora"
        case .paused: return "Sincronização pausada"
        case .attention: return "Precisa de atenção"
        }
    }

    var detail: String {
        switch self {
        case .running: return "O serviço verifica alterações automaticamente a cada cinco minutos."
        case .syncing: return "Apple Lembretes e Google Tasks estão sendo comparados."
        case .paused: return "Nenhuma tarefa será alterada até você retomar."
        case .attention: return "O serviço não está carregado. Consulte os detalhes ou tente retomar."
        }
    }

    var color: Color {
        switch self {
        case .running, .syncing: return Color(red: 0.075, green: 0.475, blue: 0.357)
        case .paused: return Color(red: 0.604, green: 0.404, blue: 0)
        case .attention: return Color(red: 0.66, green: 0.227, blue: 0.227)
        }
    }

    var symbol: String {
        switch self {
        case .running: return "arrow.triangle.2.circlepath.circle.fill"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        }
    }
}

struct SyncAction: Identifiable {
    let id = UUID()
    let kind: String
    let title: String
}

struct SyncRun: Identifiable {
    let id = UUID()
    var startedAt: Date
    var finishedAt: Date?
    var exitCode: Int?
    var summary: [String: Int]
    var actions: [SyncAction]

    var isRunning: Bool { finishedAt == nil }
    var failed: Bool { exitCode.map { $0 != 0 } ?? false }
    var changedCount: Int {
        summary
            .filter { !["skip", "unchanged"].contains($0.key) }
            .map(\.value)
            .reduce(0, +)
    }

    var title: String {
        if isRunning { return "Sincronização em andamento" }
        if failed { return "Execução com erro" }
        if changedCount == 0 { return "Tudo sincronizado" }
        return "Alterações sincronizadas"
    }

    var detail: String {
        if !actions.isEmpty {
            return actions.prefix(3).map { action in
                let label: String
                switch action.kind {
                case "CREATE_GOOGLE": label = "Criada no Google"
                case "UPDATE_GOOGLE": label = "Atualizada no Google"
                case "UPDATE_APPLE": label = "Atualizada no Apple"
                case "CONFLICT": label = "Conflito"
                default: label = action.kind.replacingOccurrences(of: "_", with: " ").capitalized
                }
                return "\(label): \(action.title)"
            }.joined(separator: " · ")
        }
        if failed { return "A execução não foi concluída." }
        return changedCount == 0 ? "Nenhuma diferença encontrada." : "Processamento concluído."
    }
}

struct ServiceDescriptor {
    let label: String
    let plist: URL
}

struct BridgeSnapshot {
    var state: ServiceState = .attention
    var loaded = false
    var paused = false
    var mappingCount = 0
    var history: [SyncRun] = []
    var nextRun: Date?
    var successfulRuns24h = 0
    var totalRuns24h = 0
    var changes24h = 0
    var errorText = ""
    var service: ServiceDescriptor?
}

enum BridgeFiles {
    static var installDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(applicationSupportName)
    }

    static var runtimeDirectory: URL { installDirectory.appendingPathComponent("runtime") }
    static var syncLog: URL { runtimeDirectory.appendingPathComponent("sync.log") }
    static var errorLog: URL { runtimeDirectory.appendingPathComponent("sync-error.log") }
    static var stateFile: URL { runtimeDirectory.appendingPathComponent("state.json") }
    static var pauseMarker: URL { runtimeDirectory.appendingPathComponent("paused") }
}

enum ProcessRunner {
    static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}

enum BridgeReader {
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func discoverService() -> ServiceDescriptor? {
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: launchAgents,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let candidates = files.filter {
            $0.pathExtension == "plist" && $0.lastPathComponent.contains(serviceNameFragment)
        }
        let services: [ServiceDescriptor] = candidates.compactMap { url in
            guard
                let data = try? Data(contentsOf: url),
                let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
                let dictionary = object as? [String: Any],
                let label = dictionary["Label"] as? String
            else { return nil }
            return ServiceDescriptor(label: label, plist: url)
        }
        return services.first(where: { isLoaded($0) }) ?? services.first
    }

    static func isLoaded(_ service: ServiceDescriptor) -> Bool {
        let target = "gui/\(getuid())/\(service.label)"
        return ProcessRunner.run("/bin/launchctl", ["print", target]).status == 0
    }

    static func snapshot() -> BridgeSnapshot {
        let service = discoverService()
        let loaded = service.map(isLoaded) ?? false
        let paused = FileManager.default.fileExists(atPath: BridgeFiles.pauseMarker.path)
        let history = parseHistory()
        let syncing = history.first?.isRunning == true
        let state: ServiceState = paused ? .paused : syncing ? .syncing : loaded ? .running : .attention
        let lastStart = history.first?.startedAt
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let recent = history.filter { $0.startedAt >= cutoff }

        return BridgeSnapshot(
            state: state,
            loaded: loaded,
            paused: paused,
            mappingCount: mappingCount(),
            history: history,
            nextRun: loaded ? lastStart?.addingTimeInterval(5 * 60) : nil,
            successfulRuns24h: recent.filter { $0.exitCode == 0 }.count,
            totalRuns24h: recent.count,
            changes24h: recent.map(\.changedCount).reduce(0, +),
            errorText: tail(BridgeFiles.errorLog, lines: 40),
            service: service
        )
    }

    static func parseHistory(limit: Int = 40) -> [SyncRun] {
        guard let content = try? String(contentsOf: BridgeFiles.syncLog, encoding: .utf8) else { return [] }
        let startRegex = try? NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) sync started$"#)
        let finishRegex = try? NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) sync finished exit=(\d+)$"#)
        let actionRegex = try? NSRegularExpression(pattern: #"^\d+\. ([A-Z_]+) \[[^]]+\]: (.*) \(due=.*; [^)]+\)$"#)
        var runs: [SyncRun] = []
        var current: SyncRun?

        for line in content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let captures = captures(startRegex, in: line), let date = isoFormatter.date(from: captures[0]) {
                if let current { runs.append(current) }
                current = SyncRun(startedAt: date, finishedAt: nil, exitCode: nil, summary: [:], actions: [])
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("Summary: ") {
                current?.summary = parseSummary(String(line.dropFirst("Summary: ".count)))
                continue
            }
            if let captures = captures(actionRegex, in: line), captures.count == 2 {
                current?.actions.append(SyncAction(kind: captures[0], title: captures[1]))
                continue
            }
            if let captures = captures(finishRegex, in: line), captures.count == 2 {
                current?.finishedAt = isoFormatter.date(from: captures[0])
                current?.exitCode = Int(captures[1])
                if let current { runs.append(current) }
                current = nil
            }
        }
        if let current { runs.append(current) }
        return Array(runs.suffix(limit).reversed())
    }

    private static func captures(_ regex: NSRegularExpression?, in value: String) -> [String]? {
        guard let regex else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }

    private static func parseSummary(_ value: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for item in value.split(separator: ",") {
            let pair = item.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if pair.count == 2, let count = Int(pair[1]) { result[String(pair[0])] = count }
        }
        return result
    }

    private static func mappingCount() -> Int {
        guard
            let data = try? Data(contentsOf: BridgeFiles.stateFile),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let mappings = dictionary["mappings"] as? [String: Any]
        else { return 0 }
        return mappings.count
    }

    private static func tail(_ url: URL, lines: Int) -> String {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return content.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}

enum BridgeController {
    static func pause(_ service: ServiceDescriptor) throws -> String {
        try FileManager.default.createDirectory(at: BridgeFiles.runtimeDirectory, withIntermediateDirectories: true)
        try ISO8601DateFormatter().string(from: Date()).write(to: BridgeFiles.pauseMarker, atomically: true, encoding: .utf8)
        let target = "gui/\(getuid())/\(service.label)"
        let result = ProcessRunner.run("/bin/launchctl", ["bootout", target])
        if result.status != 0 && BridgeReader.isLoaded(service) {
            throw NSError(domain: "Bridge", code: 1, userInfo: [NSLocalizedDescriptionKey: result.output])
        }
        return "Sincronização pausada."
    }

    static func resume(_ service: ServiceDescriptor) throws -> String {
        let domain = "gui/\(getuid())"
        let target = "\(domain)/\(service.label)"
        _ = ProcessRunner.run("/bin/launchctl", ["enable", target])
        let bootstrap = ProcessRunner.run("/bin/launchctl", ["bootstrap", domain, service.plist.path])
        if bootstrap.status != 0 && !BridgeReader.isLoaded(service) {
            throw NSError(domain: "Bridge", code: 2, userInfo: [NSLocalizedDescriptionKey: bootstrap.output])
        }
        try? FileManager.default.removeItem(at: BridgeFiles.pauseMarker)
        let kick = ProcessRunner.run("/bin/launchctl", ["kickstart", "-k", target])
        if kick.status != 0 {
            throw NSError(domain: "Bridge", code: 3, userInfo: [NSLocalizedDescriptionKey: kick.output])
        }
        return "Sincronização retomada."
    }

    static func syncNow(_ service: ServiceDescriptor) throws -> String {
        guard !FileManager.default.fileExists(atPath: BridgeFiles.pauseMarker.path) else {
            throw NSError(domain: "Bridge", code: 4, userInfo: [NSLocalizedDescriptionKey: "Retome a sincronização antes de executar agora."])
        }
        let target = "gui/\(getuid())/\(service.label)"
        let result = ProcessRunner.run("/bin/launchctl", ["kickstart", "-k", target])
        if result.status != 0 {
            throw NSError(domain: "Bridge", code: 5, userInfo: [NSLocalizedDescriptionKey: result.output])
        }
        return "Sincronização iniciada."
    }
}

@MainActor
final class BridgeMonitor: ObservableObject {
    @Published var snapshot = BridgeSnapshot()
    @Published var isWorking = false
    @Published var message: String?
    @Published var messageIsError = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        snapshot = BridgeReader.snapshot()
    }

    func pauseOrResume() {
        let shouldResume = snapshot.paused
        perform { service in
            shouldResume ? try BridgeController.resume(service) : try BridgeController.pause(service)
        }
    }

    func syncNow() {
        perform { service in try BridgeController.syncNow(service) }
    }

    private func perform(_ operation: @escaping (ServiceDescriptor) throws -> String) {
        guard let service = snapshot.service else {
            show("O serviço de sincronização não foi encontrado.", error: true)
            return
        }
        isWorking = true
        let paused = snapshot.paused
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, Error>
            do { result = .success(try operation(service)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                self.isWorking = false
                switch result {
                case .success(let text): self.show(text, error: false)
                case .failure(let error):
                    if paused {
                        try? ISO8601DateFormatter().string(from: Date()).write(
                            to: BridgeFiles.pauseMarker,
                            atomically: true,
                            encoding: .utf8
                        )
                    } else {
                        try? FileManager.default.removeItem(at: BridgeFiles.pauseMarker)
                    }
                    self.show(error.localizedDescription, error: true)
                }
                self.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
            }
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        messageIsError = error
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if self.message == text.trimmingCharacters(in: .whitespacesAndNewlines) { self.message = nil }
        }
    }
}

struct StatusDot: View {
    let state: ServiceState
    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(state.color.opacity(0.16), lineWidth: 7))
            .accessibilityHidden(true)
    }
}

struct MetricView: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }
}

struct RunRow: View {
    let run: SyncRun
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "dd MMM, HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(Self.formatter.string(from: run.startedAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Circle()
                .fill(run.failed ? Color.red : run.isRunning ? Color.orange : Color(red: 0.075, green: 0.475, blue: 0.357))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.title).font(.subheadline.weight(.semibold))
                Text(run.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            Text(run.isRunning ? "agora" : run.changedCount == 0 ? "sem alterações" : "\(run.changedCount) alteração\(run.changedCount == 1 ? "" : "ões")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

struct ContentView: View {
    @EnvironmentObject private var monitor: BridgeMonitor
    @State private var confirmPause = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            metrics
            Divider()
            history
        }
        .frame(minWidth: 760, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottomTrailing) { messageOverlay }
        .confirmationDialog(
            "Pausar a sincronização automática?",
            isPresented: $confirmPause,
            titleVisibility: .visible
        ) {
            Button("Pausar", role: .destructive) { monitor.pauseOrResume() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("O aplicativo continuará aberto, mas nenhuma tarefa será alterada até você retomar.")
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.094, green: 0.129, blue: 0.169))
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    StatusDot(state: monitor.snapshot.state)
                    Text(monitor.snapshot.state.title).font(.title3.weight(.semibold))
                }
                Text(monitor.snapshot.state.detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                monitor.syncNow()
            } label: {
                Label("Sincronizar agora", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.094, green: 0.129, blue: 0.169))
            .disabled(monitor.isWorking || monitor.snapshot.paused || !monitor.snapshot.loaded)

            Button {
                if monitor.snapshot.paused { monitor.pauseOrResume() } else { confirmPause = true }
            } label: {
                Label(monitor.snapshot.paused ? "Retomar" : "Pausar", systemImage: monitor.snapshot.paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .disabled(monitor.isWorking || monitor.snapshot.state == .syncing)
        }
        .padding(24)
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            MetricView(
                label: "Última execução",
                value: monitor.snapshot.history.first.map { Self.timeFormatter.string(from: $0.startedAt) } ?? "—",
                detail: monitor.snapshot.history.first?.title ?? "Nenhuma execução"
            )
            Divider().frame(height: 70)
            MetricView(
                label: "Próxima execução",
                value: monitor.snapshot.paused ? "Pausada" : monitor.snapshot.nextRun.map { Self.timeFormatter.string(from: $0) } ?? "—",
                detail: "A cada 5 minutos"
            )
            Divider().frame(height: 70)
            MetricView(
                label: "Tarefas ligadas",
                value: "\(monitor.snapshot.mappingCount)",
                detail: "\(monitor.snapshot.successfulRuns24h)/\(monitor.snapshot.totalRuns24h) execuções concluídas em 24h"
            )
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Histórico recente").font(.headline)
                Spacer()
                Text("\(monitor.snapshot.changes24h) alterações nas últimas 24h")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 8)

            if monitor.snapshot.history.isEmpty {
                ContentUnavailableView(
                    "Sem histórico",
                    systemImage: "clock",
                    description: Text("As execuções aparecerão aqui depois da primeira sincronização.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(monitor.snapshot.history.prefix(30)) { run in
                            RunRow(run: run)
                            Divider().padding(.leading, 113)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }

            if !monitor.snapshot.errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup("Mensagens de erro") {
                    ScrollView(.horizontal) {
                        Text(monitor.snapshot.errorText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.top, 8)
                    }
                }
                .padding(20)
                .background(Color.red.opacity(0.05))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var messageOverlay: some View {
        if let message = monitor.message {
            Label(message, systemImage: monitor.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .foregroundStyle(.white)
                .background(monitor.messageIsError ? Color.red : Color(red: 0.094, green: 0.129, blue: 0.169))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(radius: 18, y: 8)
                .padding(20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var monitor: BridgeMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(monitor.snapshot.state.title).font(.headline)
        Text("\(monitor.snapshot.mappingCount) tarefas ligadas").foregroundStyle(.secondary)
        Divider()
        Button("Abrir painel") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("Sincronizar agora") { monitor.syncNow() }
            .disabled(monitor.snapshot.paused || monitor.isWorking || !monitor.snapshot.loaded)
        Button(monitor.snapshot.paused ? "Retomar sincronização" : "Pausar sincronização") {
            monitor.pauseOrResume()
        }
        Divider()
        Button("Encerrar aplicativo") { NSApplication.shared.terminate(nil) }
    }
}

@main
struct PonteLembretesApp: App {
    @StateObject private var monitor = BridgeMonitor()

    var body: some Scene {
        WindowGroup("Ponte de Lembretes", id: "main") {
            ContentView().environmentObject(monitor)
        }
        .defaultSize(width: 900, height: 650)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Sincronização") {
                Button("Sincronizar agora") { monitor.syncNow() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button(monitor.snapshot.paused ? "Retomar" : "Pausar") { monitor.pauseOrResume() }
            }
        }

        MenuBarExtra {
            MenuBarView().environmentObject(monitor)
        } label: {
            Image(systemName: monitor.snapshot.state.symbol)
        }
    }
}
