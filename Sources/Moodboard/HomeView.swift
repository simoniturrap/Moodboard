import SwiftUI

/// Vista de inicio (casa de las pestañas, o sin ningún tablero abierto): un botón «Nuevo»
/// para crear cualquier tipo de documento y la lista de proyectos recientes.
struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var query = ""
    @State private var windowWidth: Double = 0

    private var boards: [Board] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = store.recentBoards
        return q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if boards.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(boards.enumerated()), id: \.element.id) { index, board in
                            if index > 0 { Divider() }
                            ProjectRow(board: board)
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.08)))
                }
            }
            .padding(40)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Proyectos")
                    .font(.largeTitle.weight(.semibold))
                Text(store.library.boards.isEmpty
                     ? "Todavía no hay proyectos. Crea el primero."
                     : "Crea un proyecto o abre uno reciente.")
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? "square.stack.3d.up" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty
                 ? "Crea tu primer proyecto con «Nuevo»."
                 : "Ningún proyecto coincide con «\(query)».")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
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
