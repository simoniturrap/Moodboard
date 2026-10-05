import SwiftUI

/// Lista de lo eliminado recientemente, con opción de restaurar o borrar para siempre.
struct TrashSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    private var entries: [TrashEntry] { store.library.trash }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Eliminados recientemente")
                    .font(.headline)
                Spacer()
                Button("Vaciar papelera", role: .destructive) { store.emptyTrash() }
                    .disabled(entries.isEmpty)
            }
            .padding(16)

            Divider()

            if entries.isEmpty {
                ContentUnavailableView("La papelera está vacía", systemImage: "trash")
                    .frame(maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    row(entry)
                }
            }

            Divider()

            HStack {
                Text("Se guardan los últimos 100 elementos durante 30 días.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Listo") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 440)
    }

    private func row(_ entry: TrashEntry) -> some View {
        HStack(spacing: 12) {
            thumbnail(entry)
                .frame(width: 44, height: 44)
                .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(title(entry)).lineLimit(1)
                HStack(spacing: 0) {
                    Text(origin(entry) + " · ")
                    Text(entry.deletedAt, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restaurar") {
                store.restore(entry.id)
                dismiss()
            }
            Button { store.deletePermanently(entry.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Eliminar definitivamente")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func thumbnail(_ entry: TrashEntry) -> some View {
        switch entry.content {
        case .item(let item, _, _):
            if let file = item.media, let img = ImageCache.shared.image(named: file) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: item.colorHex))
                    .overlay(Image(systemName: "note.text").foregroundStyle(.black.opacity(0.5)))
            }
        case .board(let board):
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .overlay(Image(systemName: board.kind.map(\.icon) ?? "square.grid.2x2").foregroundStyle(.secondary))
        }
    }

    private func title(_ entry: TrashEntry) -> String {
        switch entry.content {
        case .board(let board):
            return board.name
        case .item(let item, _, _):
            let firstLine = item.text.split(separator: "\n").first.map(String.init) ?? ""
            switch item.kind {
            case .image: return "Imagen"
            case .note:  return firstLine.isEmpty ? "Nota" : firstLine
            case .frame: return firstLine.isEmpty ? "Viñeta" : "Viñeta: " + firstLine
            case .text:  return firstLine.isEmpty ? "Texto" : firstLine
            }
        }
    }

    private func origin(_ entry: TrashEntry) -> String {
        switch entry.content {
        case .board(let board):
            return board.isScript ? "Guion con \(board.sceneCount) escenas" : "Tablero con \(board.items.count) elementos"
        case .item(_, _, let boardName): return "De «\(boardName)»"
        }
    }
}

/// Botón flotante abajo a la izquierda que abre la papelera.
struct TrashButton: View {
    @EnvironmentObject var store: Store

    private var count: Int { store.library.trash.count }

    var body: some View {
        Button { store.isShowingTrash = true } label: {
            Image(systemName: count == 0 ? "trash" : "trash.fill")
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
        .help("Eliminados recientemente")
    }
}
