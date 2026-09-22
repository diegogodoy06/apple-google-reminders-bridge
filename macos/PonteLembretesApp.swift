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
        guard let content = tail(BridgeFiles.syncLog, bytes: 256_000) else { return [] }
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

    private static func tail(_ url: URL, bytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > bytes ? size - bytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), var text = String(data: data, encoding: .utf8) else {
            return nil
        }
        if start > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text
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
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
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

private enum AppStyle {
    static let ink = Color(red: 0.12, green: 0.15, blue: 0.18)
    static let sidebar = Color(red: 0.11, green: 0.13, blue: 0.16)
    static let canvas = Color(red: 0.965, green: 0.974, blue: 0.978)
    static let accent = Color(red: 0.10, green: 0.45, blue: 0.42)
}

private enum PanelPage: String, CaseIterable {
    case overview = "Visão geral"
    case history = "Histórico"
    case about = "Sobre"

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }
}

struct RemindersSyncGlyph: View {
    var monochrome = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(monochrome ? Color.primary : Color.white, lineWidth: 1.7)
            RoundedRectangle(cornerRadius: 1)
                .fill(monochrome ? Color.primary : Color.white)
                .frame(height: 3)
                .offset(y: -4.5)
            HStack(spacing: 2) {
                Circle().fill(monochrome ? Color.primary : Color.white).frame(width: 2.5, height: 2.5)
                Capsule().fill(monochrome ? Color.primary : Color.white).frame(width: 7, height: 2)
            }
            .offset(y: 3)
        }
        .frame(width: 17, height: 16)
        .accessibilityLabel("Reminders Sync")
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
        HStack(alignment: .top, spacing: 11) {
            Circle()
                .fill(run.failed ? Color.red : run.isRunning ? Color.orange : AppStyle.accent)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(run.title).font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(Self.formatter.string(from: run.startedAt))
                        .font(.system(size: 10, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(run.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 10)
    }
}

struct RemindersSyncPopover: View {
    @EnvironmentObject private var monitor: BridgeMonitor
    @State private var page: PanelPage = .overview
    @State private var historyQuery = ""

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var filteredHistory: [SyncRun] {
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return monitor.snapshot.history }
        return monitor.snapshot.history.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
                || $0.actions.contains { $0.title.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 171)
            Rectangle().fill(Color.black.opacity(0.12)).frame(width: 1)
            VStack(spacing: 0) {
                switch page {
                case .overview: overview
                case .history: history
                case .about: about
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppStyle.canvas)
        }
        .frame(width: 655, height: 468)
        .preferredColorScheme(.light)
        .onAppear { monitor.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                    RemindersSyncGlyph()
                        .scaleEffect(1.2)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Reminders Sync").font(.system(size: 12, weight: .bold, design: .rounded))
                    Text("Lembretes em sintonia")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 17)
            .padding(.top, 22)
            .padding(.bottom, 32)

            ForEach(PanelPage.allCases, id: \.self) { item in
                Button { page = item } label: {
                    HStack(spacing: 11) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 17)
                        Text(item.rawValue).font(.system(size: 12, weight: page == item ? .semibold : .medium))
                        Spacer()
                    }
                    .foregroundStyle(page == item ? .white : .white.opacity(0.72))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(page == item ? Color.white.opacity(0.13) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }

            Spacer()

            HStack(spacing: 7) {
                Circle().fill(monitor.snapshot.state.color).frame(width: 6, height: 6)
                Text(monitor.snapshot.state.title)
                    .lineLimit(1)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 15)

            Rectangle().fill(.white.opacity(0.13)).frame(height: 1)

            Button { NSApplication.shared.terminate(nil) } label: {
                Label("Encerrar Reminders Sync", systemImage: "power")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 19)
                    .frame(height: 45)
            }
            .buttonStyle(.plain)
        }
        .background(AppStyle.sidebar)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Visão geral", subtitle: "Apple Lembretes  ↔  Google Tasks")

            HStack(alignment: .top, spacing: 13) {
                Image(systemName: monitor.snapshot.state.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(monitor.snapshot.state.color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(monitor.snapshot.state.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppStyle.ink)
                    Text(monitor.snapshot.state.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(monitor.snapshot.state.color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 23)
            .padding(.top, 18)

            HStack(spacing: 0) {
                valueColumn("Última", value: monitor.snapshot.history.first.map { Self.timeFormatter.string(from: $0.startedAt) } ?? "—", detail: "execução")
                Rectangle().fill(Color.black.opacity(0.08)).frame(width: 1, height: 47)
                valueColumn("Próxima", value: monitor.snapshot.paused ? "Pausada" : monitor.snapshot.nextRun.map { Self.timeFormatter.string(from: $0) } ?? "—", detail: "em 5 minutos")
                Rectangle().fill(Color.black.opacity(0.08)).frame(width: 1, height: 47)
                valueColumn("Ligadas", value: "\(monitor.snapshot.mappingCount)", detail: "tarefas")
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 8)

            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1).padding(.horizontal, 23)

            HStack {
                Text("Atividade recente").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Ver histórico") { page = .history }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppStyle.accent)
            }
            .padding(.horizontal, 23)
            .padding(.top, 17)

            VStack(spacing: 0) {
                if monitor.snapshot.history.isEmpty {
                    emptyHistory
                } else {
                    ForEach(monitor.snapshot.history.prefix(2)) { run in
                        RunRow(run: run)
                        if run.id != monitor.snapshot.history.prefix(2).last?.id {
                            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 23)

            Spacer(minLength: 0)
            controls
        }
    }

    private func valueColumn(_ label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AppStyle.ink)
                .lineLimit(1)
            Text(detail).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let message = monitor.message {
                Label(message, systemImage: monitor.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(monitor.messageIsError ? .red : AppStyle.accent)
                    .lineLimit(2)
            }
            HStack(spacing: 9) {
                Button { monitor.syncNow() } label: {
                    Label("Sincronizar agora", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppStyle.accent)
                .disabled(monitor.isWorking || monitor.snapshot.paused || !monitor.snapshot.loaded)

                Button { monitor.pauseOrResume() } label: {
                    Label(monitor.snapshot.paused ? "Retomar" : "Pausar", systemImage: monitor.snapshot.paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(monitor.isWorking || monitor.snapshot.state == .syncing)
            }
        }
        .padding(.horizontal, 23)
        .padding(.vertical, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.75))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Histórico", subtitle: "\(monitor.snapshot.successfulRuns24h) de \(monitor.snapshot.totalRuns24h) execuções concluídas nas últimas 24h")
            TextField("Buscar no histórico", text: $historyQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 23)
                .padding(.top, 18)
                .padding(.bottom, 9)

            if filteredHistory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(historyQuery.isEmpty ? "Sem execuções ainda" : "Nenhum resultado")
                        .font(.system(size: 13, weight: .medium))
                    Text(historyQuery.isEmpty ? "A primeira sincronização aparecerá aqui." : "Tente outro termo de busca.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredHistory) { run in
                            RunRow(run: run)
                            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
                        }
                    }
                    .padding(.horizontal, 23)
                }
            }
            if !monitor.snapshot.errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup("Mensagens de erro") {
                    ScrollView {
                        Text(monitor.snapshot.errorText)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 90)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(13)
                .background(Color.red.opacity(0.05))
                .padding(.horizontal, 23)
                .padding(.bottom, 13)
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Sobre", subtitle: "Lembretes em sintonia")
            HStack(spacing: 17) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 62, height: 62)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Reminders Sync").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("Acompanhe a ligação entre seus lembretes e tarefas.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 23)
            .padding(.top, 26)
            .padding(.bottom, 22)

            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1).padding(.horizontal, 23)
            infoLine("Sincronização", value: "a cada 5 minutos")
            infoLine("Tarefas ligadas", value: "\(monitor.snapshot.mappingCount)")
            infoLine("Versão", value: "1.1")
            Spacer()
            Text("Os dados ficam no seu Mac. O serviço de sincronização funciona mesmo quando você encerra o aplicativo.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(23)
        }
    }

    private func infoLine(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 23)
        .padding(.vertical, 11)
    }

    private func heading(_ title: String, subtitle: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .tracking(-0.3)
                    .foregroundStyle(AppStyle.ink)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { monitor.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppStyle.ink)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Atualizar estado")
        }
        .padding(.horizontal, 23)
        .padding(.top, 23)
    }

    private var emptyHistory: some View {
        Text("A primeira sincronização aparecerá aqui.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.vertical, 16)
    }
}

@MainActor
final class RemindersSyncAppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = BridgeMonitor()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusImage()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Reminders Sync"
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item

        let panel = NSPopover()
        panel.behavior = .transient
        panel.contentSize = NSSize(width: 655, height: 468)
        panel.contentViewController = NSHostingController(
            rootView: RemindersSyncPopover().environmentObject(monitor)
        )
        popover = panel

        if !ProcessInfo.processInfo.arguments.contains("--background") {
            DispatchQueue.main.async { self.showPanel() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    @objc private func togglePanel() {
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem?.button, let popover else { return }
        monitor.refresh()
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private static func statusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
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
struct RemindersSyncApp: App {
    @NSApplicationDelegateAdaptor(RemindersSyncAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
