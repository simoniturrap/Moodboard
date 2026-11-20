import SwiftUI

/// Vista de inicio (casa de las pestañas, o sin ningún tablero abierto): categoriza los proyectos en
/// Moodboards / Guiones / Notas, lista los de la categoría elegida y, debajo, un acceso rápido a los
/// proyectos recientes de cualquier categoría. El botón «Nuevo» crea cualquier tipo de documento.
struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var query = ""
    @State private var windowWidth: Double = 0
    /// Categoría abierta como carpeta; nil = portada con las tres categorías y los recientes.
    @State private var openCategory: DocumentKind?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var searching: Bool { !trimmedQuery.isEmpty }

    /// Fecha de «última actividad» (abierto o editado), para ordenar por lo más reciente.
    private func recency(_ b: Board) -> Date { [b.openedAt, b.modifiedAt, b.createdAt].compactMap { $0 }.max() ?? b.createdAt }

    /// Proyectos de primer nivel de una categoría, del más reciente al más antiguo.
    private func boards(of kind: DocumentKind) -> [Board] {
        store.recentBoards.filter { ($0.kind ?? .board) == kind }.sorted { recency($0) > recency($1) }
    }

    /// Recientes de cualquier categoría (acceso rápido).
    private var recientes: [Board] {
        Array(store.recentBoards.sorted { recency($0) > recency($1) }.prefix(6))
    }

    /// Resultados de la búsqueda, de todas las categorías.
    private var searchResults: [Board] {
        store.recentBoards.filter { $0.name.localizedCaseInsensitiveContains(trimmedQuery) }
            .sorted { recency($0) > recency($1) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if store.library.boards.filter({ $0.parentID == nil }).isEmpty {
                    emptyLibrary
                } else if searching {
                    section("Resultados") {
                        if searchResults.isEmpty { noResults } else { projectList(searchResults) }
                    }
                } else if let cat = openCategory {
                    categoryFolder(cat)
                } else {
                    categoryGrid
                    if !recientes.isEmpty {
                        section("Recientes") { projectList(recientes) }
                    }
                }
            }
            .padding(40)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(.spring(duration: 0.3, bounce: 0.15), value: openCategory)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { windowWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in windowWidth = w }
        })
        .overlay(alignment: .bottomLeading) { HStack(spacing: 10) { InboxButton(); TrashButton() }.padding(20) }
        // Cada vez que se muestra el inicio, baja del servidor la lista de proyectos para no ver una
        // lista vieja respecto del otro equipo (se crean/borran tableros desde cualquiera de los dos).
        .task {
            await store.refreshFromServer()
            await store.refreshInbox()
        }
        // Las pestañas siguen a mano en el inicio: la casa activa, y las abiertas para volver.
        .toolbar { TabsToolbarItem(width: max(160, windowWidth - 120)) }
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Proyectos")
                    .font(.largeTitle.weight(.semibold))
                Text(store.library.boards.isEmpty
                     ? "Todavía no hay proyectos. Crea el primero."
                     : "Elige una categoría o abre uno reciente.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !store.library.boards.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar", text: $query)
                        .textFieldStyle(.plain)
                        .frame(width: 150)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
            }
            NewProjectButton()
        }
    }

    // MARK: - Categorías como carpetas

    /// Portada: las tres categorías como carpetas. Tocar una entra en ella.
    private var categoryGrid: some View {
        HStack(spacing: 12) {
            ForEach(DocumentKind.allCases, id: \.self) { kind in
                CategoryCard(
                    title: categoryTitle(kind),
                    icon: kind.icon,
                    count: boards(of: kind).count,
                ) { openCategory = kind }
            }
        }
    }

    /// Dentro de una categoría: migas de pan para volver y la lista de sus proyectos.
    @ViewBuilder
    private func categoryFolder(_ kind: DocumentKind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { openCategory = nil } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Proyectos")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Image(systemName: kind.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                Text(categoryTitle(kind)).font(.title3.weight(.semibold))
            }

            let list = boards(of: kind)
            if list.isEmpty { emptyCategory } else { projectList(list) }
        }
    }

    private func categoryTitle(_ kind: DocumentKind) -> String {
        switch kind {
        case .board:  "Moodboards"
        case .script: "Guiones"
        case .notes:  "Notas"
        }
    }

    // MARK: - Secciones

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            content()
        }
    }

    @ViewBuilder
    private func projectList(_ boards: [Board]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(boards.enumerated()), id: \.element.id) { index, board in
                if index > 0 { Divider() }
                ProjectRow(board: board)
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.08)))
    }

    private var emptyLibrary: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Crea tu primer proyecto con «Nuevo».")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var emptyCategory: some View {
        Text("No hay proyectos en esta categoría todavía.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
            .padding(.horizontal, 14)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.08)))
    }

    private var noResults: some View {
        Text("Ningún proyecto coincide con «\(trimmedQuery)».")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
            .padding(.horizontal, 14)
    }
}

/// Tarjeta de categoría en la portada, a modo de carpeta: icono, nombre en plural, conteo y una
/// flecha que indica que se puede entrar. Tocarla abre la categoría.
private struct CategoryCard: View {
    let title: String
    let icon: String
    let count: Int
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Text(count == 1 ? "1 proyecto" : "\(count) proyectos")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(hovered ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(hovered ? 0.18 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Botón único de creación: despliega los tipos de proyecto a elegir.
private struct NewProjectButton: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Menu {
            ForEach(DocumentKind.allCases, id: \.self) { kind in
                Button { store.requestNew(kind) } label: {
                    Label(kind.title, systemImage: kind.icon)
                }
            }
        } label: {
            Label("Nuevo", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .fixedSize()
    }
}

/// Fila de un proyecto: icono del tipo, nombre, resumen y última modificación. Sin miniatura.
private struct ProjectRow: View {
    @EnvironmentObject var store: Store
    let board: Board
    @State private var isHovered = false
    @State private var isRenaming = false

    private var kind: DocumentKind { board.kind ?? .board }

    var body: some View {
        Button { if !isRenaming { store.select(board: board.id) } } label: {
            HStack(spacing: 14) {
                Image(systemName: kind.icon)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    RenamableText(text: board.name, isEditing: $isRenaming) {
                        store.renameBoard(board.id, to: $0)
                    }
                    .font(.headline)
                    Text("\(kind.title) · \(board.summary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(board.lastModified, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.05) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Abrir") { store.select(board: board.id) }
            Button("Renombrar") { isRenaming = true }
            Button("Duplicar") { store.duplicateBoard(board.id) }
            Divider()
            Button("Eliminar", role: .destructive) { store.deleteBoard(board.id) }
        }
    }
}
