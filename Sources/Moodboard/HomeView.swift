import SwiftUI

/// Vista de inicio (casa de las pestañas, o sin ningún tablero abierto): crear uno nuevo
/// o elegir entre los recientes, cada uno con su miniatura.
struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var query = ""
    @State private var windowWidth: Double = 0

    private var boards: [Board] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = store.recentBoards
        return q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    if query.isEmpty {
                        NewDocumentCard(kind: .board)
                        NewDocumentCard(kind: .script)
                    }
                    ForEach(boards) { BoardCard(board: $0) }
                }
                if !query.isEmpty && boards.isEmpty {
                    Text("Ningún tablero coincide con «\(query)»")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(40)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { windowWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in windowWidth = w }
        })
        .overlay(alignment: .bottomLeading) { TrashButton().padding(20) }
        // Las pestañas siguen a mano en el inicio: la casa activa, y las abiertas para volver.
        .toolbar { TabsToolbarItem(width: max(160, windowWidth - 120)) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tableros")
                    .font(.largeTitle.weight(.semibold))
                Text(store.library.boards.isEmpty
                     ? "Todavía no hay tableros. Crea el primero."
                     : "Crea un tablero o un guion, o abre uno reciente.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !store.library.boards.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar tableros", text: $query)
                        .textFieldStyle(.plain)
                        .frame(width: 180)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
            }
        }
    }
}

/// Tarjetas de creación: tablero o guion (abren la modal de nombre con el tipo elegido).
private struct NewDocumentCard: View {
    @EnvironmentObject var store: Store
    let kind: DocumentKind
    @State private var isHovered = false

    var body: some View {
        Button { store.requestNew(kind) } label: {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(isHovered ? Color.accentColor : Color.secondary.opacity(0.5))
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: kind == .board ? "plus" : "doc.badge.plus")
                                .font(.system(size: 26, weight: .light))
                            Text(kind == .board ? "Crea un nuevo tablero" : "Crea un nuevo guion").font(.callout)
                        }
                        .foregroundStyle(isHovered ? Color.accentColor : Color.secondary)
                    }
                    .aspectRatio(4 / 3, contentMode: .fit)
                Text(kind == .board ? "Nuevo tablero" : "Nuevo guion").font(.headline)
                Text(kind == .board ? "⌘N" : "⇧⌘N").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

/// Tarjeta de un tablero con su miniatura; clic lo abre como pestaña.
private struct BoardCard: View {
    @EnvironmentObject var store: Store
    let board: Board
    @State private var isHovered = false

    var body: some View {
        Button { store.select(board: board.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if board.isScript { ScriptPreview(board: board) } else { BoardPreview(board: board) }
                }
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isHovered ? Color.accentColor : Color.primary.opacity(0.1),
                                      lineWidth: isHovered ? 2 : 1))
                    .shadow(color: .black.opacity(isHovered ? 0.18 : 0.08), radius: isHovered ? 12 : 6, y: 3)
                Text(board.name).font(.headline).lineLimit(1)
                HStack(spacing: 0) {
                    Image(systemName: (board.kind ?? .board).icon)
                    Text(board.isScript ? " \(board.sceneCount) escenas · " : " \(board.items.count) elementos · ")
                    Text(board.openedAt ?? board.createdAt, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .contextMenu {
            Button("Abrir") { store.select(board: board.id) }
            Button("Duplicar") { store.duplicateBoard(board.id) }
            Divider()
            Button("Eliminar", role: .destructive) { store.deleteBoard(board.id) }
        }
    }
}

/// Miniatura del tablero: todas las piezas escaladas para caber en la tarjeta.
struct BoardPreview: View {
    let board: Board
    private let padding: Double = 16

    var body: some View {
        GeometryReader { geo in
            let items = board.items.sorted { $0.z < $1.z }
            if let first = items.first {
                let bounds = items.dropFirst().reduce(first.frameRect) { $0.union($1.frameRect) }
                let s = min((geo.size.width - padding * 2) / max(bounds.width, 1),
                            (geo.size.height - padding * 2) / max(bounds.height, 1), 1)
                // Centra el contenido dentro de la tarjeta.
                let ox = (geo.size.width - bounds.width * s) / 2
                let oy = (geo.size.height - bounds.height * s) / 2
                ZStack(alignment: .topLeading) {
                    ForEach(items) { item in
                        ItemView(item: item, scale: s, isSelected: false, isEditing: false,
                                 onTextChange: { _ in }, onEndEditing: {})
                            .frame(width: item.w, height: item.h)
                            .offset(x: item.x - bounds.minX, y: item.y - bounds.minY)
                    }
                }
                .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
                .scaleEffect(s, anchor: .topLeading)
                .offset(x: ox, y: oy)
            } else {
                Image(systemName: "square.dashed")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .drawingGroup()
        .allowsHitTesting(false)
    }
}
