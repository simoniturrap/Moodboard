import SwiftUI

/// Bandeja de entrada: capturas que llegan desde fuera de la app (la extensión de Chrome en
/// Instagram, etc.) y esperan en el servidor para cargarse en un tablero. Es la gemela de la
/// papelera, al revés: aquí no está lo desechado, sino lo que vas a importar.
struct InboxSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    private var items: [InboxItem] { store.inboxItems }
    private var targetName: String? { store.activeBoard?.name }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bandeja de entrada")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await store.refreshInbox() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Actualizar")
            }
            .padding(16)

            Divider()

            if items.isEmpty {
                ContentUnavailableView(
                    "La bandeja está vacía",
                    systemImage: "tray",
                    description: Text("Captura imágenes desde la web con la extensión de Chrome y aparecerán aquí."))
                    .frame(maxHeight: .infinity)
            } else {
                List(items) { item in
                    row(item)
                }
            }

            Divider()

            HStack {
                if let targetName {
                    Text("Se cargan en «\(targetName)».")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Abre un tablero para cargar las capturas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Listo") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 440)
        .onAppear { Task { await store.refreshInbox() } }
    }

    private func row(_ item: InboxItem) -> some View {
        HStack(spacing: 12) {
            thumbnail(item)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.isVideo ? "Video" : "Imagen").lineLimit(1)
                if let host = sourceHost(item) {
                    Text(host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                store.importFromInbox(item)
            } label: {
                Label("Cargar", systemImage: "plus")
            }
            .disabled(store.activeBoard == nil)
            .help(store.activeBoard == nil ? "Abre un tablero para cargar" : "Cargar en el tablero actual")

            Button { store.discardInboxItem(item) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Descartar")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func thumbnail(_ item: InboxItem) -> some View {
        // `thumbnail(named:)` dispara la descarga desde el servidor si el archivo aún no está en disco;
        // al llegar, el Store se redibuja (onMediaArrived) y la miniatura aparece sola.
        if let img = ImageCache.shared.thumbnail(named: item.media, maxPixel: 128) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .overlay(ProgressView().controlSize(.small))
        }
    }

    /// Dominio de origen de la captura (p. ej. «instagram.com»), si se guardó.
    private func sourceHost(_ item: InboxItem) -> String? {
        guard let raw = item.sourceUrl, let host = URL(string: raw)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Botón flotante que abre la bandeja de entrada. Vive al lado de la papelera y sólo aparece cuando
/// la sincronización está configurada (sin servidor no hay bandeja).
struct InboxButton: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var sync = SyncService.shared

    private var count: Int { store.inboxItems.count }

    var body: some View {
        if SyncConfig.isConfigured {
            Button {
                store.isShowingInbox = true
                Task { await store.refreshInbox() }
            } label: {
                Image(systemName: count == 0 ? "tray" : "tray.full.fill")
                    .font(.system(size: 14))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().stroke(.primary.opacity(0.1)))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .overlay(alignment: .topTrailing) {
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Color.accentColor, in: Capsule())
                                .offset(x: 4, y: -4)
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Bandeja de entrada")
        }
    }
}
