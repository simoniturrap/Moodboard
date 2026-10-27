import SwiftUI

/// Botón flotante arriba a la izquierda: «+» crea un tablero y la flecha despliega
/// los tableros recientes con un buscador.
struct BoardSwitcher: View {
    @EnvironmentObject var store: Store
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private let spring = Animation.spring(duration: 0.3, bounce: 0.18)
    private let recentLimit = 8

    private var results: [Board] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(store.recentBoards.prefix(recentLimit)) }
        return store.recentBoards.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            pill
            if store.isBoardMenuOpen {
                dropdown
                    .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .onChange(of: store.isNamingNewBoard) { _, naming in if naming { close() } }
    }

    // MARK: - Botón

    private var pill: some View {
        HStack(spacing: 0) {
            Button { store.requestNew(.board) } label: {
                Image(systemName: "plus")
                    .frame(width: 34, height: 32)
                    .contentShape(Rectangle())
            }
            .help("Nuevo tablero (⌘N) · guion (⇧⌘N)")

            Divider().frame(height: 16)

            Button { store.isBoardMenuOpen ? close() : open() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(store.isBoardMenuOpen ? 180 : 0))
                    .frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }
            .help("Tableros recientes")
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }

    // MARK: - Desplegable

    private var dropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar tableros", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = results.first { open(first) } }
                    .onExitCommand(perform: close)
            }
            .padding(10)

            Divider()

            Text(query.isEmpty ? "Recientes" : "Resultados")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if results.isEmpty {
                Text("Ningún tablero coincide")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(results) { board in
                            BoardRow(board: board, isActive: board.id == store.library.activeBoardID) {
                                open(board)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
    }

    private func open() {
        query = ""
        withAnimation(spring) { store.isBoardMenuOpen = true }
        DispatchQueue.main.async { searchFocused = true }
    }

    private func close() {
        withAnimation(spring) { store.isBoardMenuOpen = false }
    }

    private func open(_ board: Board) {
        store.focusArea = .boards
        store.select(board: board.id)
        close()
    }
}

private struct BoardRow: View {
    @EnvironmentObject var store: Store
    let board: Board
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false
    @State private var isRenaming = false

    var body: some View {
        Button { if !isRenaming { action() } } label: {
            HStack(spacing: 8) {
                Image(systemName: (board.kind ?? .board).icon)
                    .foregroundStyle(.secondary)
                RenamableText(text: board.name, isEditing: $isRenaming) {
                    store.renameBoard(board.id, to: $0)
                }
                Spacer()
                Text("\(board.items.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.18)
                          : isHovered ? Color.primary.opacity(0.07) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Renombrar") { isRenaming = true }
            Button("Duplicar") { store.duplicateBoard(board.id) }
            Divider()
            Button("Eliminar", role: .destructive) { store.deleteBoard(board.id) }
        }
    }
}

/// Las pestañas como elemento de la barra de la ventana; lo usan el tablero y el guion.
struct TabsToolbarItem: ToolbarContent {
    let width: Double

    var body: some ToolbarContent {
        // En macOS 26 la barra envuelve cada grupo en una cápsula de vidrio; las pestañas van sin ella.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                BoardTabs(availableWidth: width)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) {
                BoardTabs(availableWidth: width)
            }
        }
    }
}

/// Pestañas de los tableros abiertos, en la barra de la ventana junto a los iconos.
/// Ocupan un ancho fijo que calcula BoardCanvas (así la barra no puede aplastarlas); dentro,
/// las pestañas se lo reparten (entre `minTab` y `maxTab`) y, si no caben, se desplazan en horizontal.
/// Doble clic renombra; la × cierra. Al cerrar la última se vuelve al inicio.
struct BoardTabs: View {
    @EnvironmentObject var store: Store
    /// Ancho disponible para toda la tira de pestañas.
    let availableWidth: Double
    @State private var renaming: UUID?

    private let minTab: Double = 110
    private let maxTab: Double = 210
    private let spacing: Double = 4
    private let inset: Double = 2

    var body: some View {
        GeometryReader { geo in
            let count = Double(max(store.openBoards.count, 1))
            // Se descuentan la casa del principio y el «+» del final.
            let fit = (geo.size.width - inset * 2 - spacing * (count + 1) - NewTabButton.size - HomeTabButton.size) / count
            let width = min(maxTab, max(minTab, fit))
            HStack(spacing: spacing) {
                // La casa queda fija: no se desplaza con las pestañas.
                HomeTabButton()
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: spacing) {
                            ForEach(store.openBoards) { board in
                                BoardTab(board: board,
                                         width: width,
                                         isActive: board.id == store.library.activeBoardID,
                                         isRenaming: Binding(get: { renaming == board.id },
                                                             set: { renaming = $0 ? board.id : nil }))
                                    .id(board.id)
                                    .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                            }
                            NewTabButton()
                        }
                        .padding(.horizontal, inset)
                        .frame(height: geo.size.height)
                    }
                    .onChange(of: store.library.activeBoardID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                    }
                }
            }
            .padding(.leading, inset)
        }
        .frame(width: availableWidth, height: 30)
        .animation(.spring(duration: 0.25, bounce: 0.15), value: store.library.openBoardIDs)
    }
}

/// Casa al principio de las pestañas: vuelve a la vista de inicio sin cerrar ninguna pestaña.
private struct HomeTabButton: View {
    @EnvironmentObject var store: Store
    @State private var isHovered = false
    static let size: Double = 28

    private var isActive: Bool { store.library.activeBoardID == nil }

    var body: some View {
        Button { store.goHome() } label: {
            Image(systemName: isActive ? "house.fill" : "house")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: Self.size, height: Self.size)
                .foregroundStyle(isActive || isHovered ? Color.primary : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(isActive ? 0.1 : isHovered ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .help("Inicio (⇧⌘H)")
    }
}

/// «+» tras la última pestaña: abre la modal de creación (tablero o guion).
private struct NewTabButton: View {
    @EnvironmentObject var store: Store
    @State private var isHovered = false
    static let size: Double = 28

    var body: some View {
        Button { store.requestNew(.board) } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: Self.size, height: Self.size)
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(isHovered ? 0.1 : 0)))
                .scaleEffect(isHovered ? 1.08 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.spring(duration: 0.2, bounce: 0.3), value: isHovered)
        .help("Nuevo tablero o guion (⌘N)")
    }
}

private struct BoardTab: View {
    @EnvironmentObject var store: Store
    let board: Board
    let width: Double
    let isActive: Bool
    @Binding var isRenaming: Bool
    @State private var isHovered = false
    @State private var isCloseHovered = false

    var body: some View {
        HStack(spacing: 2) {
            // Zona del nombre: un clic abre, doble clic renombra. No incluye la ×.
            RenamableText(text: board.name, isEditing: $isRenaming) {
                store.renameBoard(board.id, to: $0)
            }
            .font(.system(size: 12, weight: isActive ? .semibold : .regular))
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 10)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                store.focusArea = .boards
                if !isActive { store.select(board: board.id) }
            })

            Button { store.closeTab(board.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(isCloseHovered ? 0.12 : 0)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered || isActive ? 1 : 0)
            .allowsHitTesting(isHovered || isActive)
            .onHover { isCloseHovered = $0 }
            .help("Cerrar tablero (⌘W)")
            .padding(.trailing, 5)
        }
        .frame(width: width, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? Color.primary.opacity(0.1) : isHovered ? Color.primary.opacity(0.05) : .clear)
        )
        .foregroundStyle(isActive ? .primary : .secondary)
        .onHover { isHovered = $0 }
        .help(board.name)
        .contextMenu {
            Button("Renombrar") { isRenaming = true }
            Button("Duplicar") { store.duplicateBoard(board.id) }
            Button("Cerrar") { store.closeTab(board.id) }
            Divider()
            Button("Eliminar", role: .destructive) { store.deleteBoard(board.id) }
        }
    }
}
