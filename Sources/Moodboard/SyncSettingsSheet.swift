import SwiftUI

/// Ajustes de sincronización: URL del Worker, token y estado.
struct SyncSettingsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sync = SyncService.shared

    @State private var url = SyncConfig.workerURL
    @State private var token = SyncConfig.token

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
                SecureField("Token", text: $token)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(sync.status.label).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Guardar y probar", action: saveAndTest)
                    .keyboardShortcut(.defaultAction)
            }

            if sync.usageKnown { usageIndicator }

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

    private func saveAndTest() {
        SyncConfig.workerURL = url
        SyncConfig.token = token
        url = SyncConfig.workerURL          // refleja la normalización (sin barra final)
        sync.refreshEnabledState()
        Task {
            await sync.testConnection()
            if SyncConfig.isConfigured { await store.resync() }
        }
    }
}
