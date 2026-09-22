import AppKit
import SwiftUI

private struct DashboardPalette {
    let dark: Bool
    var canvas: Color { dark ? Color(red: 0.095, green: 0.105, blue: 0.115) : Color(red: 0.975, green: 0.982, blue: 0.995) }
    var sidebar: Color { dark ? Color(red: 0.115, green: 0.135, blue: 0.16) : Color(red: 0.923, green: 0.95, blue: 0.995) }
    var surface: Color { dark ? Color(red: 0.13, green: 0.145, blue: 0.155) : .white }
    var border: Color { dark ? .white.opacity(0.105) : Color(red: 0.85, green: 0.875, blue: 0.92) }
    var text: Color { dark ? .white : Color(red: 0.095, green: 0.12, blue: 0.20) }
    var muted: Color { dark ? Color(red: 0.72, green: 0.75, blue: 0.80) : Color(red: 0.38, green: 0.43, blue: 0.53) }
    var blue: Color { Color(red: 0.07, green: 0.43, blue: 0.92) }
    var green: Color { Color(red: 0.16, green: 0.72, blue: 0.37) }
    var neutralButton: Color { dark ? Color(red: 0.19, green: 0.21, blue: 0.23) : Color(red: 0.925, green: 0.94, blue: 0.97) }
}

private extension View {
    func dashboardCard(_ palette: DashboardPalette, radius: CGFloat = 15) -> some View {
        self
            .background(palette.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(palette.border, lineWidth: 1))
    }
}

struct BetaPanel: View {
    @ObservedObject var store: BetaStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmActivation = false
    private var p: DashboardPalette { DashboardPalette(dark: colorScheme == .dark) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(p.border).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if !store.notice.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle").foregroundStyle(p.blue)
                            Text(store.notice).font(.system(size: 13)).foregroundStyle(p.muted)
                            Spacer()
                        }
                        .padding(.horizontal, 15).padding(.vertical, 11)
                        .dashboardCard(p, radius: 10)
                    }
                    switch store.page {
                    case .overview: overview
                    case .accounts: accounts
                    case .history: history
                    case .settings: settings
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(p.canvas)
        }
        .frame(minWidth: 960, minHeight: 620)
        .background(p.canvas)
        .onAppear { store.refresh() }
        .alert("Ativar sincronização?", isPresented: $confirmActivation) {
            Button("Ativar e aplicar") { store.activate() }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("As ações da prévia poderão criar ou atualizar tarefas no Google Tasks e no Apple Lembretes. Revise a lista antes de continuar.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // O espaço superior pertence aos controles nativos da janela.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 62, height: 62)
                .padding(.bottom, 14)
            HStack(spacing: 9) {
                Text("Reminders Sync")
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
                Text("BETA")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(p.neutralButton, in: RoundedRectangle(cornerRadius: 6))
            }
            Text("Apple Reminders ↔ Google Tasks")
                .font(.system(size: 12))
                .foregroundStyle(p.muted)
                .padding(.top, 5)
                .padding(.bottom, 22)

            ForEach(BetaStore.Page.allCases, id: \.self) { page in
                Button { store.page = page } label: {
                    HStack(spacing: 18) {
                        Image(systemName: page.icon)
                            .font(.system(size: 19, weight: .light))
                            .frame(width: 26)
                        Text(page.rawValue).font(.system(size: 16, weight: store.page == page ? .medium : .regular))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 47)
                    .foregroundStyle(store.page == page ? .white : p.text.opacity(0.86))
                    .background(store.page == page ? p.blue : .clear, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 5)
            }
            Spacer(minLength: 20)
            HStack(alignment: .top, spacing: 13) {
                Circle()
                    .fill(store.enabled && store.ready ? p.green : (store.ready ? .orange : p.muted))
                    .frame(width: 18, height: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.enabled && store.ready ? "Sincronização ativa" : store.statusText)
                        .font(.system(size: 15, weight: .medium))
                    Text(store.enabled && store.ready ? "Verificando a cada 5 minutos" : "Configure ou retome nas opções")
                        .font(.system(size: 12)).foregroundStyle(p.muted)
                }
            }
        }
        .foregroundStyle(p.text)
        .padding(.horizontal, 16)
        .padding(.top, 67)
        .padding(.bottom, 24)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(p.sidebar)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.page.rawValue)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(p.text)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(p.muted)
            }
            Spacer()
            if store.page == .overview {
                Text(lastUpdate)
                    .font(.system(size: 12))
                    .foregroundStyle(p.muted)
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 19, weight: .light))
                        .frame(width: 47, height: 45)
                        .background(p.neutralButton, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.text)
                .help("Atualizar informações")
            }
        }
        .frame(minHeight: 50)
    }

    private var subtitle: String {
        switch store.page {
        case .overview: return "Seus lembretes sincronizados entre o Apple Reminders e o Google Tasks."
        case .accounts: return "Configure o acesso aos Lembretes e a sua conta Google neste Mac."
        case .history: return "Acompanhe as últimas verificações e alterações sincronizadas."
        case .settings: return "Controle a execução automática do Reminders Sync."
        }
    }

    private var lastUpdate: String {
        guard let date = store.lastChecked else { return "Nenhuma verificação ainda" }
        return "Última atualização: " + date.formatted(date: .omitted, time: .shortened)
    }

    private var overview: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                statusCard.frame(maxWidth: .infinity)
                VStack(spacing: 8) {
                    connectedCard("Apple Reminders", subtitle: "iCloud", connected: store.appleAuthorized, icon: "apple.logo")
                    connectedCard("Google Tasks", subtitle: store.hasToken ? "Conta conectada" : "Autorização necessária",
                                  connected: store.hasToken, icon: "g.circle.fill")
                }
                .frame(width: 275)
            }
            .frame(height: 184)
            activityCard
            HStack(alignment: .top, spacing: 12) {
                nextCheckCard.frame(maxWidth: .infinity)
                statusOptionsCard.frame(maxWidth: .infinity)
                actionsCard.frame(maxWidth: .infinity)
            }
            .frame(height: 182)
        }
    }

    private var statusCard: some View {
        HStack(spacing: 19) {
            ZStack {
                Circle().stroke(p.border, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: store.ready && store.enabled ? 1 : 0.72)
                    .stroke(store.ready && store.enabled ? p.green : .orange,
                            style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: store.ready && store.enabled ? "checkmark" : (store.working ? "arrow.triangle.2.circlepath" : "pause"))
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(store.ready && store.enabled ? p.green : .orange)
            }
            .frame(width: 108, height: 108)
            VStack(alignment: .leading, spacing: 0) {
                Text(store.enabled && store.ready ? "Sincronização ativa" : store.statusText)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(p.text)
                Text(store.enabled && store.ready ? "Tudo está atualizado." : statusDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(p.muted)
                    .padding(.top, 6)
                Rectangle().fill(p.border).frame(height: 1).padding(.vertical, 17)
                HStack(alignment: .top, spacing: 0) {
                    metric("\(store.mappingCount)", "Tarefas\nsincronizadas")
                    metric(store.previewReady ? "\(store.previewActions.count)" : "—", "Pendentes\nde envio")
                    metric(store.ignoredCount.map(String.init) ?? "—", "Sem alterações\n(última prévia)")
                }
            }
        }
        .padding(.horizontal, 19)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .dashboardCard(p)
    }

    private var statusDescription: String {
        if store.working { return "Uma verificação está em andamento." }
        if !store.ready { return "Conclua a configuração em Contas." }
        return "As verificações automáticas estão pausadas."
    }

    private func metric(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 20, weight: .semibold)).foregroundStyle(p.text)
            Text(caption).font(.system(size: 11)).foregroundStyle(p.muted).lineSpacing(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connectedCard(_ name: String, subtitle: String, connected: Bool, icon: String) -> some View {
        Button { store.page = .accounts } label: {
            HStack(spacing: 17) {
                Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(p.text)
                    .frame(width: 42)
                VStack(alignment: .leading, spacing: 5) {
                    Text(name).font(.system(size: 15, weight: .medium)).foregroundStyle(p.text)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(p.muted)
                    HStack(spacing: 7) {
                        Circle().fill(connected ? p.green : .orange).frame(width: 10, height: 10)
                        Text(connected ? "Conectado" : "Pendente").font(.system(size: 13)).foregroundStyle(p.muted)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 15)).foregroundStyle(p.text)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .dashboardCard(p)
        }
        .buttonStyle(.plain)
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Atividade de sincronização")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(p.text)
                Spacer()
                Text("Últimas 24 horas")
                    .font(.system(size: 13)).foregroundStyle(p.text)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(p.neutralButton, in: RoundedRectangle(cornerRadius: 9))
            }
            Rectangle().fill(p.border).frame(height: 1).padding(.top, 8)
            HStack(spacing: 20) {
                Spacer()
                legend(p.green, "Enviadas (Apple → Google)")
                legend(p.blue, "Enviadas (Google → Apple)")
            }
            .padding(.top, 8)
            activityGraph
        }
        .padding(16)
        .frame(height: 184)
        .dashboardCard(p)
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.system(size: 12)).foregroundStyle(p.muted)
        }
    }

    private var hourlyActivity: [(Int, Int)] {
        let start = Calendar.current.dateInterval(of: .hour, for: Date())!.start.addingTimeInterval(-23 * 3600)
        return (0..<24).map { hour in
            let from = start.addingTimeInterval(TimeInterval(hour * 3600))
            let to = from.addingTimeInterval(3600)
            let runs = store.history.filter { $0.date >= from && $0.date < to && !$0.failed }
            return (runs.reduce(0) { $0 + $1.appleToGoogle }, runs.reduce(0) { $0 + $1.googleToApple })
        }
    }

    private var activityGraph: some View {
        let values = hourlyActivity
        let maximum = max(10, values.map { $0.0 + $0.1 }.max() ?? 0)
        let hasActivity = values.contains { $0.0 + $0.1 > 0 }
        return VStack(spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                VStack {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle().fill(p.border).frame(height: 1)
                        Spacer(minLength: 0)
                    }
                    Rectangle().fill(p.border).frame(height: 1)
                }
                HStack(alignment: .bottom, spacing: 7) {
                    ForEach(0..<24, id: \.self) { hour in
                        VStack(spacing: 0) {
                            Rectangle().fill(p.green)
                                .frame(height: CGFloat(values[hour].0) / CGFloat(maximum) * 68)
                            Rectangle().fill(p.blue)
                                .frame(height: CGFloat(values[hour].1) / CGFloat(maximum) * 68)
                        }
                        .frame(maxWidth: .infinity, alignment: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                .padding(.horizontal, 1)
                if !hasActivity {
                    Text("Nenhuma alteração registrada nas últimas 24 horas")
                        .font(.system(size: 13))
                        .foregroundStyle(p.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 68)
            HStack {
                Text("24h atrás")
                Spacer()
                Text("18h")
                Spacer()
                Text("12h")
                Spacer()
                Text("6h")
                Spacer()
                Text("Agora")
            }
            .font(.system(size: 11))
            .foregroundStyle(p.muted)
        }
        .padding(.top, 10)
    }

    private var nextCheckCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Próxima verificação").font(.system(size: 17, weight: .semibold)).foregroundStyle(p.text)
            HStack(spacing: 15) {
                Image(systemName: "clock")
                    .font(.system(size: 31, weight: .ultraLight))
                    .foregroundStyle(p.text)
                    .frame(width: 56, height: 56)
                    .background(p.neutralButton, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(nextCheckText).font(.system(size: 17, weight: .semibold)).foregroundStyle(p.text)
                    Text(store.nextCheck?.formatted(date: .abbreviated, time: .shortened) ?? "Ative a sincronização")
                        .font(.system(size: 13)).foregroundStyle(p.muted)
                }
            }
            Spacer()
        }
        .padding(17)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard(p)
    }

    private var nextCheckText: String {
        guard let next = store.nextCheck else { return "Não agendada" }
        let minutes = max(0, Int(ceil(next.timeIntervalSinceNow / 60)))
        return minutes == 0 ? "Em instantes" : "Em \(minutes) minuto\(minutes == 1 ? "" : "s")"
    }

    private var statusOptionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Status").font(.system(size: 17, weight: .semibold)).foregroundStyle(p.text)
                .padding(.bottom, 7)
            Divider()
            optionRow("Sincronização automática") {
                Toggle("", isOn: Binding(
                    get: { store.enabled },
                    set: { value in
                        if value { startSync() }
                        else { store.pause() }
                    }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(p.blue)
                .disabled(!store.ready)
            }
            Divider()
            optionRow("Executar ao iniciar o macOS") {
                Toggle("", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(p.blue)
            }
            Divider()
            optionRow("Intervalo") {
                Text("A cada 5 minutos")
                    .font(.system(size: 12)).foregroundStyle(p.text)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(p.neutralButton, in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard(p)
    }

    private func optionRow<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(p.text)
            Spacer(minLength: 8)
            control()
        }
        .frame(height: 36)
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ações").font(.system(size: 17, weight: .semibold)).foregroundStyle(p.text)
                .padding(.bottom, 2)
            actionButton("Sincronizar agora", icon: "arrow.triangle.2.circlepath", primary: true) {
                store.syncNow()
            }
            .disabled(!store.ready || !store.enabled || store.working)
            actionButton("Ver alterações", icon: "doc.text") { store.page = .history }
            actionButton(store.enabled ? "Pausar sincronização" : "Retomar sincronização",
                         icon: store.enabled ? "pause.circle" : "play.circle") {
                if store.enabled { store.pause() } else { startSync() }
            }
            .disabled(!store.ready)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard(p)
    }

    private func actionButton(_ title: String, icon: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 33)
                .background(primary ? p.blue : p.neutralButton, in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(primary ? .white : p.text)
        }
        .buttonStyle(.plain)
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 16) {
            accountSetupCard("Apple Reminders", detail: store.appleAuthorized ? "Acesso aos Lembretes concedido" : "Permissão necessária",
                             icon: "apple.logo", connected: store.appleAuthorized) {
                Button(store.appleAuthorized ? "Verificar permissão" : "Autorizar Lembretes") { store.requestAppleAccess() }
            }
            accountSetupCard("Cliente OAuth do Google", detail: store.hasClient ? "Arquivo JSON importado neste Mac" : "Importe um cliente OAuth do tipo Aplicativo para computador",
                             icon: "key.horizontal", connected: store.hasClient) {
                Button("Importar JSON") { store.importGoogleClient() }
            }
            accountSetupCard("Google Tasks", detail: store.hasToken ? "Conta autorizada" : "Conecte sua conta pessoal pelo Safari",
                             icon: "g.circle.fill", connected: store.hasToken) {
                Button(store.hasToken ? "Verificar conexão" : "Conectar Google") { store.connectGoogle() }
                    .disabled(!store.hasClient || store.working)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Antes de conectar o Google").font(.system(size: 16, weight: .semibold)).foregroundStyle(p.text)
                Text("No Google Cloud, ative a Tasks API, configure a tela de consentimento e crie um cliente OAuth para aplicativo de computador. Se o projeto estiver em modo Teste, adicione seu e-mail como testador.")
                    .font(.system(size: 14)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading).dashboardCard(p)
            if store.ready && !store.enabled {
                Button("Calcular prévia sem alterar tarefas") { store.preview() }
                    .disabled(store.working)
                    .buttonStyle(.borderedProminent)
            }
            if store.previewReady {
                previewCard
            }
        }
    }

    private func accountSetupCard<Actions: View>(_ title: String, detail: String, icon: String,
                                                  connected: Bool, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 19) {
            Image(systemName: icon)
                .font(.system(size: 31))
                .foregroundStyle(p.text)
                .frame(width: 58, height: 58)
                .background(p.neutralButton, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(p.text)
                Text(detail).font(.system(size: 13)).foregroundStyle(p.muted)
                Label(connected ? "Conectado" : "Pendente", systemImage: "circle.fill")
                    .font(.system(size: 12)).foregroundStyle(connected ? p.green : .orange)
            }
            Spacer()
            actions().buttonStyle(.bordered)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(p)
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prévia das alterações").font(.system(size: 17, weight: .semibold)).foregroundStyle(p.text)
            Text(store.previewSummary).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.muted)
            if store.previewActions.isEmpty {
                Text("Nenhuma alteração planejada.").font(.system(size: 13)).foregroundStyle(p.muted)
            } else {
                ForEach(store.previewActions.indices, id: \.self) { index in
                    Text(store.previewActions[index]).font(.system(size: 13)).foregroundStyle(p.text)
                }
            }
            if !store.enabled {
                Button("Ativar sincronização") { confirmActivation = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.working || store.legacyInstallationPresent)
            }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading).dashboardCard(p)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.history.isEmpty {
                Text("Nenhuma sincronização executada ainda.")
                    .font(.system(size: 14)).foregroundStyle(p.muted)
                    .padding(25)
            } else {
                ForEach(store.history.prefix(30)) { run in
                    HStack(alignment: .top, spacing: 15) {
                        Circle().fill(run.failed ? .red : p.green).frame(width: 12, height: 12).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(run.failed ? "Execução com erro" : "Sincronização concluída")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text)
                            Text(run.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.muted)
                        }
                        Spacer()
                        Text(run.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12)).foregroundStyle(p.muted)
                    }
                    .padding(21)
                    Divider().padding(.horizontal, 21)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(p)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("Abrir ao iniciar sessão no Mac", isOn: Binding(
                get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch).tint(p.blue)
            Text("Fechar a janela mantém o aplicativo na barra de menus. A sincronização continua enquanto o aplicativo estiver em execução. Encerrar o aplicativo interrompe as verificações automáticas.")
                .font(.system(size: 14)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
            if store.ready && !store.enabled {
                Button("Retomar sincronização") { startSync() }.buttonStyle(.borderedProminent)
            }
            Divider()
            Button("Encerrar aplicativo") { NSApp.terminate(nil) }
                .foregroundStyle(.red)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(p)
    }

    private func startSync() {
        if store.previewReady {
            confirmActivation = true
        } else if store.history.isEmpty {
            store.page = .accounts
            store.preview()
        } else {
            store.resume()
        }
    }
}
