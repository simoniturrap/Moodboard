import SwiftUI

/// Barra de documentos vinculados (guion ↔ tablero). Muestra un chip de acceso por cada documento
/// vinculado al actual y un botón «+» para vincular uno existente o crear uno nuevo. Vive tanto en el
/// editor de tablero como en el de guion; `suggestKind` es el tipo que ofrece el botón «+» (en un
/// guion se sugieren tableros; en un tablero, guiones).
struct LinkedBoardsBar: View {
    @EnvironmentObject var store: Store
    let suggestKind: DocumentKind

    private var current: Board? { store.activeBoard }
    private var links: [Board] { current.map { store.linkedBoards(of: $0.id) } ?? [] }

    var body: some View {
        if let current {
            HStack(spacing: 8) {
                ForEach(links) { board in
                    LinkChip(board: board,
                             open: { store.select(board: board.id) },
                             unlink: { store.unlinkBoards(current.id, board.id) })
                }
                addButton(current)
            }
        }
    }

    /// Documentos del tipo sugerido, de primer nivel, que aún no están vinculados.
    private func candidates(_ current: Board) -> [Board] {
        let linked = Set(links.map(\.id))
        return store.library.boards.filter {
            $0.id != current.id && !linked.contains($0.id)
                && ($0.kind ?? .board) == suggestKind && $0.parentID == nil
        }
    }

    private func addButton(_ current: Board) -> some View {
        let cands = candidates(current)
        return Menu {
            if cands.isEmpty {
                Text("No hay documentos para vincular")
            } else {
                ForEach(cands) { board in
                    Button(board.name) { store.linkBoards(current.id, board.id) }
                }
            }
            Divider()
            Button {
                store.newLinkedDocument(kind: suggestKind, linkedTo: current.id)
            } label: {
                Label("Nuevo \(suggestKind.title.lowercased())…", systemImage: "plus")
            }
        } label: {
            if links.isEmpty {
                // Sin nada vinculado: invita con la palabra. Una vez vinculado, se queda sólo el icono.
                Label("Vincular \(suggestKind.title.lowercased())", systemImage: "link.badge.plus")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            } else {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 13))
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.1)))
        .help("Vincular \(suggestKind.title.lowercased())")
    }
}

/// Chip de un documento vinculado: icono del tipo, nombre, y una «x» para desvincular al pasar el ratón.
private struct LinkChip: View {
    let board: Board
    let open: () -> Void
    let unlink: () -> Void
    @State private var hover = false

    private var kind: DocumentKind { board.kind ?? .board }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.icon).font(.system(size: 11)).foregroundStyle(Color.accentColor)
            Text(board.name).lineLimit(1).font(.system(size: 12, weight: .medium))
            if hover {
                Button(action: unlink) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Desvincular")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.1)))
        .contentShape(Capsule())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
        .help("Abrir «\(board.name)»")
    }
}
