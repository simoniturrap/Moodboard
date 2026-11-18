import SwiftUI

/// Ajustes de sincronización: URL del Worker, token y estado.
struct SyncSettingsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sync = SyncService.shared

    @State private var url = SyncConfig.workerURL
    @State private var email = SyncConfig.email
    @State private var password = ""
    @State private var loggedIn = !SyncConfig.token.isEmpty
    @State private var loginError: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sincronización")
                .font(.headline)

            Text("Tus tableros se guardan en el servidor y se sincronizan entre tus equipos. "
                 + "Lo que mandas a la papelera se mantiene ahí por si quieres recuperarlo.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Servidor").font(.subheadline).foregroundStyle(.secondary)
                TextField("https://moodboard-sync.xxx.workers.dev", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .disabled(loggedIn)

                if loggedIn {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Sesión iniciada como **\(SyncConfig.email)**")
                            .font(.callout)
                        Spacer()
                        Button("Cerrar sesión") {
                            sync.signOut()
                            loggedIn = false
                            password = ""
                        }
                    }
                } else {
                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Contraseña", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .onSubmit(signIn)
                    if let loginError {
                        Text(loginError).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(sync.status.label).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !loggedIn {
                    Button("Iniciar sesión", action: signIn)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || url.isEmpty || email.isEmpty || password.isEmpty)
                }
            }

            if loggedIn && sync.usageKnown { usageIndicator }

            HStack {
                Spacer()
                Button("Cerrar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { if SyncConfig.isConfigured { await sync.refreshUsage() } }
    }

    /// Barra de almacenamiento usado en el servidor contra el tope que nos autoimponemos.
    private var usageIndicator: some View {
        let used = sync.usageBytes
        let cap = SyncService.storageCap
        let fraction = sync.usageFraction
        let barColor: Color = fraction >= 1 ? .red : fraction >= 0.9 ? .orange : .accentColor
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Almacenamiento").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(Self.format(used)) de \(Self.format(cap))")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: fraction).tint(barColor)
            if fraction >= 1 {
                Text("Alcanzaste el tope. Las fotos nuevas se guardan en tu equipo pero no se "
                     + "subirán hasta que liberes espacio (vacía la papelera).")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .decimal   // R2 factura en GB decimales (1 GB = 1000 MB)
        return f.string(fromByteCount: bytes)
    }

    private var statusColor: Color {
        switch sync.status {
        case .upToDate:  return .green
        case .syncing:   return .orange
        case .error:     return .red
        case .idle:      return .blue
        case .disabled:  return .gray
        }
    }

    private func signIn() {
        guard !busy, !url.isEmpty, !email.isEmpty, !password.isEmpty else { return }
        busy = true
        loginError = nil
        Task {
            let error = await sync.login(workerURL: url, email: email, password: password)
            busy = false
            if let error {
                loginError = error
                return
            }
            url = SyncConfig.workerURL       // refleja la normalización (sin barra final)
            password = ""
            loggedIn = true
            await sync.testConnection()
            if SyncConfig.isConfigured { await store.resync() }
            await sync.refreshUsage()
        }
    }
}
