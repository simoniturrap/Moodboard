import SwiftUI
import AppKit

/// Hoja de "Compartir tablero": muestra el enlace público del tablero activo.
/// El enlace es en vivo: refleja siempre la última versión del tablero.
struct ShareSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Compartir tablero")
                .font(.headline)

            Text("Cualquiera con este enlace podrá ver el tablero en el navegador. "
                 + "El enlace se mantiene al día: refleja siempre la última versión.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.isPreparingShare {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Preparando el enlace…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else if let url = store.shareURL {
                HStack(spacing: 8) {
                    Text(url.absoluteString)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
                    Button(copied ? "Copiado" : "Copiar") { copy(url) }
                        .fixedSize()
                }

                HStack {
                    Button("Dejar de compartir", role: .destructive) { store.unshareActiveBoard() }
                    Spacer()
                    Button("Abrir en el navegador") { NSWorkspace.shared.open(url) }
                }
            } else {
                Text("No se pudo crear el enlace. Revisa la conexión con el servidor en "
                     + "Tableros → Sincronización.")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cerrar") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func copy(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
