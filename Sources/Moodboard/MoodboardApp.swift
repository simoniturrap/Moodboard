import SwiftUI
import AppKit

@main
struct MoodboardApp: App {
    @StateObject private var store = Store()
    @StateObject private var updater = UpdaterController()
    @AppStorage(themePreferenceKey) private var theme = ThemePreference.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme((ThemePreference(rawValue: theme) ?? .system).colorScheme)
                .onDisappear { store.saveNow() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Buscar actualizaciones…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Nuevo tablero…") { store.requestNew(.board) }
                    .keyboardShortcut("n")
                Button("Nuevo guion…") { store.requestNew(.script) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                // Va antes que el «Cerrar» del sistema, así ⌘W cierra el tablero y no la ventana.
                Button("Cerrar tablero") { store.closeFrontmost() }
                    .keyboardShortcut("w")
            }
            CommandMenu("Tableros") {
                Button("Inicio") { store.goHome() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Compartir tablero…") { store.shareActiveBoard() }
                    .disabled(!store.canShareActiveBoard)
                Button("Sincronización…") { store.isShowingSync = true }
                Divider()
                // ⌘1…⌘8 para las primeras pestañas; ⌘9 siempre para la última.
                ForEach(Array(store.openBoards.prefix(8).enumerated()), id: \.element.id) { index, board in
                    Button(board.name) { store.selectTab(number: index + 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                if store.openBoards.count >= 9, let last = store.openBoards.last {
                    Button(last.name) { store.selectTab(number: 9) }
                        .keyboardShortcut("9")
                }
                Divider()
                Button("Pestaña siguiente") { store.selectAdjacentTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Pestaña anterior") { store.selectAdjacentTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }
            // El ítem de Preferencias se declara a mano (SettingsLink) para que aparezca siempre,
            // también en el .app empaquetado, donde el ítem automático de la escena Settings no sale.
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text("Preferencias…") }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Deshacer") { undo() }
                    .keyboardShortcut("z")
                Button("Rehacer") { redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cortar") { textAction(#selector(NSText.cut(_:))) { store.cutSelection() } }
                    .keyboardShortcut("x")
                Button("Copiar") { textAction(#selector(NSText.copy(_:))) { store.copySelection() } }
                    .keyboardShortcut("c")
                Button("Pegar") { textAction(#selector(NSText.paste(_:))) { store.paste() } }
                    .keyboardShortcut("v")
                Button("Seleccionar todo") { textAction(#selector(NSText.selectAll(_:))) { store.selectAll() } }
                    .keyboardShortcut("a")
                Divider()
                Button("Duplicar") { store.duplicateSelection() }
                    .keyboardShortcut("d")
                // ⌫ lo resuelve BoardCanvas según dónde se hizo clic (pieza o tablero).
                Button("Eliminar selección") { store.deleteSelection() }
                Button("Papelera…") { store.isShowingTrash = true }
            }
        }

        Settings {
            PreferencesView()
        }
    }

    /// Mientras se escribe en un campo, ⌘Z deshace el texto; si no, la última acción del tablero.
    private var textUndoManager: UndoManager? {
        guard let text = NSApp.keyWindow?.firstResponder as? NSText else { return nil }
        return text.undoManager
    }

    /// Si se está escribiendo en un campo, la orden va al texto; si no, a las piezas del tablero.
    private func textAction(_ selector: Selector, otherwise: () -> Void) {
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(selector, to: nil, from: nil)
        } else {
            otherwise()
        }
    }

    private func undo() {
        if let um = textUndoManager, um.canUndo { um.undo() } else { store.undo() }
    }

    private func redo() {
        if let um = textUndoManager, um.canRedo { um.redo() } else { store.redo() }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if store.activeBoard == nil {
                HomeView()
            } else if store.activeBoard?.isScript == true {
                ScriptEditor()
            } else if store.activeBoard?.isNotes == true {
                NotesView()
            } else {
                BoardCanvas()
            }
        }
        .modifier(HideSystemTitle(windowTitle: store.activeBoard?.name ?? "Moodboard"))
        .overlay {
            if let id = store.lightboxItem,
               let item = store.activeBoard?.items.first(where: { $0.id == id }) {
                Lightbox(item: item)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .sheet(isPresented: $store.isNamingNewBoard) { NewBoardSheet() }
        .sheet(isPresented: $store.isShowingTrash) { TrashSheet() }
        .sheet(isPresented: $store.isShowingSync) { SyncSettingsSheet() }
        .sheet(isPresented: $store.isShowingShare) { ShareSheet() }
    }
}
