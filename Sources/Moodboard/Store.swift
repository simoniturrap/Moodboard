import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Fuente de verdad de la app: tableros en memoria, JSON + imágenes en disco.
@MainActor
final class Store: ObservableObject {
    @Published var library: Library
    @Published var selection: Set<UUID> = []
    @Published var editingItem: UUID? {
        didSet {
            guard editingItem != oldValue else { return }
            textUndoItem = nil
            if let old = oldValue { discardIfEmptyText(old) }
        }
    }
    /// Herramienta activa de la paleta derecha.
    @Published var tool: Tool = .select {
        // Al tomar una herramienta se suelta la selección para que vuelva la paleta.
        didSet { if tool != .select { selection = []; editingItem = nil } }
    }

    enum Tool { case select, text, note, board }
    /// Muestra la modal que pide el nombre del tablero nuevo.
    @Published var isNamingNewBoard = false
    /// Tipo de documento que propone la modal de «Nuevo…».
    @Published var newDocumentKind: DocumentKind = .board
    @Published var isShowingTrash = false
    /// Desplegable de tableros recientes (botón flotante de arriba a la izquierda).
    @Published var isBoardMenuOpen = false
    /// Tablero recién abierto cuyo encuadre debe recolocar el lienzo (necesita el tamaño de la vista).
    @Published var boardToFrame: UUID?
    /// Foto abierta a pantalla completa con la herramienta de recorte.
    @Published var lightboxItem: UUID?
    /// Último lugar donde se hizo clic: decide qué borra la tecla ⌫.
    @Published var focusArea: FocusArea = .canvas

    enum FocusArea { case canvas, boards }

    /// Historial para ⌘Z / ⇧⌘Z: fotos completas de la biblioteca antes de cada cambio.
    private var undoStack: [Library] = []
    private var redoStack: [Library] = []
    private let undoLimit = 60
    /// Pieza cuyo texto ya se registró en el historial durante esta edición.
    private var textUndoItem: UUID?
    private var lastCheckpointKey: String?

    private let trashLimit = 100
    private let trashMaxAge: TimeInterval = 30 * 24 * 3600

    private let saveDebounce = 0.6
    private var saveTask: Task<Void, Never>?

    // MARK: - Rutas en disco

    nonisolated static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Moodboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated static let mediaDir: URL = {
        let dir = root.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated private static var libraryFile: URL { root.appendingPathComponent("library.json") }

    // MARK: - Ciclo de vida

    init() {
        if let data = try? Data(contentsOf: Store.libraryFile),
           let decoded = try? JSONDecoder().decode(Library.self, from: data) {
            library = decoded
        } else {
            library = .starter
        }
        // Sin tablero activo (se cerraron todas las pestañas) la app abre en la vista de inicio.
        library.trash.removeAll { $0.deletedAt.timeIntervalSinceNow < -trashMaxAge }
        let existing = Set(library.boards.map(\.id))
        library.openBoardIDs = library.openBoardIDs.filter(existing.contains)
        if let active = library.activeBoardID, !existing.contains(active) { library.activeBoardID = nil }
        if let active = library.activeBoardID, !library.openBoardIDs.contains(active) {
            library.openBoardIDs.append(active)
        }
        // Al abrir la app, el tablero activo se muestra desde su esquina superior izquierda.
        boardToFrame = library.activeBoardID
    }

    // MARK: - Deshacer

    /// Guarda el estado actual antes de un cambio que se pueda deshacer.
    /// Con `coalescing`, cambios seguidos de la misma clase (p. ej. arrastrar el selector de color)
    /// cuentan como un solo paso.
    func checkpoint(coalescing key: String? = nil) {
        defer { lastCheckpointKey = key }
        if let key, key == lastCheckpointKey { return }
        undoStack.append(library)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(library)
        apply(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(library)
        apply(next)
    }

    /// Restaura una foto del historial sin tocar el encuadre de cada tablero.
    private func apply(_ snapshot: Library) {
        var restored = snapshot
        for i in restored.boards.indices {
            if let current = library.boards.first(where: { $0.id == restored.boards[i].id }) {
                restored.boards[i].camera = current.camera
            }
        }
        library = restored
        let ids = Set(activeBoard?.items.map(\.id) ?? [])
        selection = selection.intersection(ids)
        editingItem = nil
        scheduleSave()
    }

    /// Guarda con un pequeño retraso para no escribir en cada pixel arrastrado.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.saveDebounce ?? 0.6))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let data = try? JSONEncoder().encode(library) else { return }
        let tmp = Store.root.appendingPathComponent("library.json.tmp")
        try? data.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(Store.libraryFile, withItemAt: tmp)
    }

    // MARK: - Tableros

    var activeBoard: Board? {
        guard let id = library.activeBoardID else { return nil }
        return library.boards.first { $0.id == id }
    }

    private var activeIndex: Int? {
        guard let id = library.activeBoardID else { return nil }
        return library.boards.firstIndex { $0.id == id }
    }

    func mutateBoard(_ change: (inout Board) -> Void) {
        guard let i = activeIndex else { return }
        change(&library.boards[i])
        library.boards[i].modifiedAt = Date()
        scheduleSave()
    }

    /// Tableros abiertos como pestañas.
    var openBoards: [Board] {
        library.openBoardIDs.compactMap { id in library.boards.first { $0.id == id } }
    }

    /// Proyectos de primer nivel, del abierto más recientemente al más antiguo.
    /// Los sub-tableros de una carpeta no aparecen aquí: se abren desde su carpeta.
    var recentBoards: [Board] {
        library.boards
            .filter { $0.parentID == nil }
            .sorted { ($0.openedAt ?? $0.createdAt) > ($1.openedAt ?? $1.createdAt) }
    }

    /// Abre la modal de creación con el tipo ya elegido.
    func requestNew(_ kind: DocumentKind) {
        newDocumentKind = kind
        isNamingNewBoard = true
    }

    func newBoard(named name: String = "Tablero sin título", kind: DocumentKind = .board) {
        checkpoint()
        library.boards.append(makeBoard(named: name, kind: kind))
        select(board: library.boards.last!.id)
    }

    /// Construye un tablero vacío del tipo dado, con su contenido inicial.
    private func makeBoard(named name: String, kind: DocumentKind, parentID: UUID? = nil) -> Board {
        var board = Board(name: name)
        board.parentID = parentID
        switch kind {
        case .board:
            board.kind = .board
        case .script:
            board.kind = .script
            board.script = [ScriptLine(type: .scene)]
        case .notes:
            board.kind = .notes
            let first = Note()
            board.notes = [first]
            board.activeNoteID = first.id
        }
        return board
    }

    // MARK: - Guion

    var scriptLines: [ScriptLine] { activeBoard?.script ?? [] }

    private func mutateScript(_ change: (inout [ScriptLine]) -> Void) {
        mutateBoard { board in
            var lines = board.script ?? []
            change(&lines)
            if lines.isEmpty { lines = [ScriptLine(type: .scene)] }
            board.script = lines
        }
    }

    /// Escribir en una misma línea cuenta como un solo paso de deshacer.
    /// Una acción que empieza por INT./EXT. se convierte sola en encabezado de escena.
    func updateLine(_ id: UUID, text: String) {
        checkpoint(coalescing: "script-\(id)")
        mutateScript { lines in
            guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
            // «int.» o «ext.» (también «int./ext.») al empezar: es un encabezado de escena.
            if lines[i].type == .action,
               text.range(of: #"^\s*(int|ext)\."#, options: [.regularExpression, .caseInsensitive]) != nil {
                lines[i].type = .scene
            }
            lines[i].text = lines[i].type.isUppercase ? text.uppercased() : text
        }
    }

    func setLineType(_ id: UUID, _ type: ScriptElement) {
        checkpoint()
        mutateScript { lines in
            guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
            let wasUppercase = lines[i].type.isUppercase
            lines[i].type = type
            if type.isUppercase {
                lines[i].text = lines[i].text.uppercased()
            } else if wasUppercase {
                // De un tipo en mayúsculas (escena, personaje, transición) a uno normal:
                // acotación en minúsculas; acción y diálogo como frase (primera letra en mayúscula).
                let lower = lines[i].text.lowercased()
                lines[i].text = type == .parenthetical ? lower : Self.sentenceCase(lower)
            }
        }
    }

    /// Zoom de la hoja del guion (se guarda en la cámara del documento).
    var scriptZoom: Double { activeBoard?.camera.scale ?? 1 }

    func setScriptZoom(_ value: Double) {
        mutateBoard { $0.camera.scale = min(3, max(0.5, value)) }
    }

    /// «ana camina. se detiene» → «Ana camina. Se detiene»: mayúscula al empezar y tras . ! ?
    static func sentenceCase(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for ch in text {
            if capitalizeNext, ch.isLetter {
                result += ch.uppercased()
                capitalizeNext = false
            } else {
                result.append(ch)
                if ".!?¡¿\n".contains(ch) { capitalizeNext = true }
            }
        }
        return result
    }

    /// Parte la línea en el cursor: lo anterior se queda, lo siguiente pasa a una línea nueva.
    @discardableResult
    func splitLine(_ id: UUID, at offset: Int) -> UUID? {
        guard let line = scriptLines.first(where: { $0.id == id }) else { return nil }
        let chars = Array(line.text)
        let cut = min(max(offset, 0), chars.count)
        let before = String(chars[..<cut]), after = String(chars[cut...])
        let nextType = line.type.next
        let new = ScriptLine(type: nextType, text: nextType.isUppercase ? after.uppercased() : after)
        checkpoint()
        mutateScript { lines in
            guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
            lines[i].text = before
            lines.insert(new, at: i + 1)
        }
        return new.id
    }

    /// Une la línea con la anterior (⌫ al principio). Devuelve la anterior y dónde queda el cursor.
    func mergeWithPrevious(_ id: UUID) -> (id: UUID, caret: Int)? {
        let lines = scriptLines
        guard let i = lines.firstIndex(where: { $0.id == id }), i > 0 else { return nil }
        let previous = lines[i - 1]
        checkpoint()
        mutateScript { lines in
            lines[i - 1].text += lines[i].text
            lines.remove(at: i)
        }
        return (previous.id, previous.text.count)
    }


    // MARK: - Notas

    var notes: [Note] { activeBoard?.notes ?? [] }

    var activeNote: Note? {
        guard let id = activeBoard?.activeNoteID else { return notes.first }
        return notes.first { $0.id == id } ?? notes.first
    }

    private func mutateNotes(_ change: (inout [Note]) -> Void) {
        mutateBoard { board in
            var list = board.notes ?? []
            change(&list)
            board.notes = list
        }
    }

    func selectNote(_ id: UUID) {
        mutateBoard { $0.activeNoteID = id }
    }

    func addNote() {
        checkpoint()
        let note = Note()
        mutateNotes { $0.insert(note, at: 0) }
        mutateBoard { $0.activeNoteID = note.id }
    }

    func renameNote(_ id: UUID, to title: String) {
        checkpoint(coalescing: "note-title-\(id)")
        mutateNotes { notes in
            guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
            notes[i].title = title
            notes[i].modifiedAt = Date()
        }
    }

    func deleteNote(_ id: UUID) {
        checkpoint()
        mutateNotes { $0.removeAll { $0.id == id } }
        // El gestor nunca queda sin notas; si era la activa, pasa a la primera.
        mutateBoard { board in
            if (board.notes ?? []).isEmpty {
                let note = Note()
                board.notes = [note]
                board.activeNoteID = note.id
            } else if board.activeNoteID == id {
                board.activeNoteID = board.notes?.first?.id
            }
        }
    }

    /// Guarda el cuerpo de una nota. La escritura cuenta como un solo paso de deshacer por nota.
    func updateNoteBody(_ id: UUID, rtf: Data) {
        if textUndoItem != id {
            checkpoint()
            textUndoItem = id
        }
        mutateNotes { notes in
            guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
            notes[i].rtf = rtf
            notes[i].modifiedAt = Date()
        }
    }

    // MARK: - Carpetas de tableros

    /// Coloca una carpeta en el tablero: crea un sub-tablero vacío y la pieza que lo abre.
    func addBoardFolder(at point: CGPoint) {
        guard let parent = activeBoard else { return }
        checkpoint()
        let child = makeBoard(named: "Tablero sin título", kind: .board, parentID: parent.id)
        library.boards.append(child)
        var item = BoardItem(kind: .board,
                             x: Grid.snap(point.x - 70), y: Grid.snap(point.y - 70),
                             w: 140, h: 140, text: child.name)
        item.childBoardID = child.id
        mutateBoard { board in
            item.z = board.topZ
            board.items.append(item)
        }
        selection = [item.id]
        editingItem = item.id
    }

    /// Doble clic en una carpeta: abre su sub-tablero como pestaña.
    func openBoardFolder(_ item: BoardItem) {
        guard let child = item.childBoardID, library.boards.contains(where: { $0.id == child }) else { return }
        select(board: child)
    }

    /// Cadena de carpetas padre de un tablero, de la raíz a su contenedor directo (para las migas de pan).
    func ancestors(of id: UUID) -> [Board] {
        var chain: [Board] = []
        var current = library.boards.first { $0.id == id }?.parentID
        while let pid = current, let board = library.boards.first(where: { $0.id == pid }) {
            chain.insert(board, at: 0)
            current = board.parentID
        }
        return chain
    }

    /// Este tablero y todos sus descendientes (carpetas anidadas), por si hay que borrarlos juntos.
    private func descendantBoardIDs(of ids: Set<UUID>) -> Set<UUID> {
        var result = ids
        var queue = Array(ids)
        while let current = queue.popLast() {
            for child in library.boards where child.parentID == current && !result.contains(child.id) {
                result.insert(child.id)
                queue.append(child.id)
            }
        }
        return result
    }

    /// Borra tableros y todo lo que cuelga de ellos, cerrando sus pestañas.
    private func removeBoardSubtrees(_ roots: Set<UUID>) {
        let all = descendantBoardIDs(of: roots)
        library.openBoardIDs.removeAll { all.contains($0) }
        if let active = library.activeBoardID, all.contains(active) { library.activeBoardID = nil }
        library.boards.removeAll { all.contains($0.id) }
    }

    func duplicateBoard(_ id: UUID) {
        checkpoint()
        let parent = library.boards.first { $0.id == id }?.parentID
        guard let newID = cloneBoardTree(id, parentID: parent, rename: true) else { return }
        select(board: newID)
    }

    /// Clona un tablero y, recursivamente, los sub-tableros de sus carpetas (ids nuevos).
    @discardableResult
    private func cloneBoardTree(_ id: UUID, parentID: UUID?, rename: Bool) -> UUID? {
        guard let source = library.boards.first(where: { $0.id == id }) else { return nil }
        var copy = source
        copy.id = UUID()
        copy.parentID = parentID
        copy.createdAt = Date()
        copy.openedAt = nil
        if rename { copy.name = source.name + " copia" }
        copy.items = source.items.map { item in
            var c = item
            c.id = UUID()
            return c
        }
        library.boards.append(copy)
        for idx in copy.items.indices where copy.items[idx].kind == .board {
            guard let childID = copy.items[idx].childBoardID,
                  let newChild = cloneBoardTree(childID, parentID: copy.id, rename: false) else { continue }
            if let bi = library.boards.firstIndex(where: { $0.id == copy.id }) {
                library.boards[bi].items[idx].childBoardID = newChild
            }
        }
        return copy.id
    }

    func deleteBoard(_ id: UUID) {
        guard let board = library.boards.first(where: { $0.id == id }) else { return }
        checkpoint()
        moveToTrash([TrashEntry(content: .board(board))])
        closeTab(id)
        removeBoardSubtrees([id])   // el tablero y sus sub-tableros se van juntos
        selection = []
        scheduleSave()
    }

    func renameBoard(_ id: UUID, to name: String) {
        guard let i = library.boards.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        library.boards[i].name = name
        library.boards[i].modifiedAt = Date()
        scheduleSave()
    }

    /// Activa un tablero y lo abre como pestaña si no lo estaba.
    func select(board id: UUID) {
        guard let i = library.boards.firstIndex(where: { $0.id == id }) else { return }
        library.activeBoardID = id
        library.boards[i].openedAt = Date()
        if !library.openBoardIDs.contains(id) {
            // Abrir un tablero que no tenía pestaña reinicia el encuadre; cambiar de pestaña no.
            library.openBoardIDs.append(id)
            boardToFrame = id
        }
        selection = []
        editingItem = nil
        scheduleSave()
    }

    /// Muestra el inicio dejando todas las pestañas abiertas.
    func goHome() {
        library.activeBoardID = nil
        selection = []
        editingItem = nil
        lightboxItem = nil
        isBoardMenuOpen = false
        scheduleSave()
    }

    /// Cierra una pestaña; si era la activa, pasa a la vecina. Sin pestañas, se muestra el inicio.
    func closeTab(_ id: UUID) {
        guard let i = library.openBoardIDs.firstIndex(of: id) else { return }
        library.openBoardIDs.remove(at: i)
        if library.activeBoardID == id {
            if library.openBoardIDs.isEmpty {
                library.activeBoardID = nil
                selection = []
                editingItem = nil
            } else {
                select(board: library.openBoardIDs[min(i, library.openBoardIDs.count - 1)])
            }
        }
        scheduleSave()
    }

    // MARK: - Piezas

    func add(_ item: BoardItem) {
        checkpoint()
        mutateBoard { board in
            var new = item
            new.z = board.topZ
            board.items.append(new)
        }
        selection = [item.id]
    }

    func update(_ id: UUID, _ change: (inout BoardItem) -> Void) {
        mutateBoard { board in
            guard let i = board.items.firstIndex(where: { $0.id == id }) else { return }
            change(&board.items[i])
        }
    }

    func deleteSelection(toTrash: Bool = true) {
        let ids = selection
        guard !ids.isEmpty, let board = activeBoard else { return }
        checkpoint()
        let removed = board.items.filter { ids.contains($0.id) }
        if toTrash {
            moveToTrash(removed.map {
                TrashEntry(content: .item($0, boardID: board.id, boardName: board.name))
            })
        }
        mutateBoard { $0.items.removeAll { ids.contains($0.id) } }
        // Las carpetas se llevan sus sub-tableros.
        let childRoots = Set(removed.compactMap { $0.kind == .board ? $0.childBoardID : nil })
        if !childRoots.isEmpty { removeBoardSubtrees(childRoots) }
        selection = []
        editingItem = nil
    }

    func duplicateSelection() {
        guard !selection.isEmpty else { return }
        checkpoint()
        var newIDs: Set<UUID> = []
        mutateBoard { board in
            let copies = board.items.filter { selection.contains($0.id) }.map { item -> BoardItem in
                var c = item
                c.id = UUID()
                c.x += 28
                c.y += 28
                c.z = board.topZ
                newIDs.insert(c.id)
                return c
            }
            board.items.append(contentsOf: copies)
        }
        selection = newIDs
    }

    /// Copia las piezas en el mismo lugar (sin registrar deshacer: lo hace quien llama).
    /// Devuelve original → copia.
    func cloneItems(_ ids: Set<UUID>) -> [UUID: UUID] {
        var map: [UUID: UUID] = [:]
        mutateBoard { board in
            var z = board.topZ
            let copies = board.items.filter { ids.contains($0.id) }.map { item -> BoardItem in
                var c = item
                c.id = UUID()
                c.z = z
                z += 1
                map[item.id] = c.id
                return c
            }
            board.items.append(contentsOf: copies)
        }
        return map
    }

    func bringSelectionToFront() {
        checkpoint()
        bringToFront(selection)
    }

    /// Cambia el texto de una pieza; toda una edición cuenta como un solo paso de deshacer.
    func updateText(_ id: UUID, _ text: String) {
        if textUndoItem != id {
            checkpoint()
            textUndoItem = id
        }
        update(id) { $0.text = text }
        // Renombrar una carpeta renombra su sub-tablero.
        if let item = activeBoard?.items.first(where: { $0.id == id }), item.kind == .board,
           let child = item.childBoardID,
           let bi = library.boards.firstIndex(where: { $0.id == child }) {
            library.boards[bi].name = text
        }
        refitTextHeights([id])
    }

    func bringToFront(_ ids: Set<UUID>) {
        mutateBoard { board in
            var z = board.topZ
            for i in board.items.indices where ids.contains(board.items[i].id) {
                board.items[i].z = z
                z += 1
            }
        }
    }

    func sendSelectionToBack() {
        checkpoint()
        mutateBoard { board in
            var z = (board.items.map(\.z).min() ?? 0) - 1
            for i in board.items.indices where selection.contains(board.items[i].id) {
                board.items[i].z = z
                z -= 1
            }
        }
    }

    /// En bloques de texto cambia el color de la letra; en notas y viñetas, el del fondo.
    func applyColorToSelection(_ hex: String, coalescing: Bool = false) {
        let ids = selection
        checkpoint(coalescing: coalescing ? "color-\(ids.hashValue)" : nil)
        mutateBoard { board in
            for i in board.items.indices where ids.contains(board.items[i].id) {
                switch board.items[i].kind {
                case .text: board.items[i].textColorHex = hex
                case .note, .frame: board.items[i].colorHex = hex
                case .image, .board: break
                }
            }
        }
    }

    // MARK: - Recorte

    /// Aplica un recorte normalizado; la foto conserva su ancho y el alto sigue la nueva proporción.
    func applyCrop(_ id: UUID, _ rect: CGRect) {
        guard let item = activeBoard?.items.first(where: { $0.id == id }),
              let file = item.media, let img = ImageCache.shared.image(named: file) else { return }
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let isFull = abs(rect.minX) < 0.001 && abs(rect.minY) < 0.001
            && abs(rect.width - 1) < 0.001 && abs(rect.height - 1) < 0.001
        let aspect = (rect.width * img.size.width) / max(rect.height * img.size.height, 1)
        checkpoint()
        update(id) {
            $0.crop = isFull ? nil : rect.intersection(full)
            if $0.kind == .image { $0.h = max(Grid.step * 2, Grid.snap($0.w / aspect)) }
        }
    }

    // MARK: - Descargar

    /// Guarda la foto en disco (por defecto en Descargas). Si está recortada, se guarda el recorte
    /// a resolución completa; si no, una copia exacta del archivo original.
    func downloadImage(_ id: UUID) {
        guard let board = activeBoard, let item = board.items.first(where: { $0.id == id }),
              let file = item.media else { return }
        let source = Store.mediaDir.appendingPathComponent(file)
        let original = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        // Un recorte se vuelve a codificar: JPEG, PNG o TIFF (HEIC y otros pasan a JPEG/PNG).
        let ext = item.crop == nil ? original
            : ["jpg", "jpeg", "heic"].contains(original) ? "jpg"
            : ["tif", "tiff"].contains(original) ? "tiff" : "png"

        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = "\(board.name) – imagen.\(ext)"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .image]
        panel.prompt = "Descargar"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        try? FileManager.default.removeItem(at: dest)   // el panel ya confirmó reemplazar
        if let crop = item.crop, let data = croppedImageData(source: source, crop: crop, ext: ext) {
            try? data.write(to: dest)
        } else {
            try? FileManager.default.copyItem(at: source, to: dest)
        }
        NSWorkspace.shared.activateFileViewerSelecting([dest])
    }

    /// Dibuja sólo la zona recortada a la resolución de píxeles original.
    private func croppedImageData(source: URL, crop: CGRect, ext: String) -> Data? {
        guard let image = NSImage(contentsOf: source), image.size.width > 0 else { return nil }
        let pixels = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        let density = pixels > 0 ? Double(pixels) / max(image.size.width, image.size.height) : 1
        let width = Int((crop.width * image.size.width * density).rounded())
        let height = Int((crop.height * image.size.height * density).rounded())
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // NSImage mide desde abajo: la y del recorte se invierte.
        let from = CGRect(x: crop.minX * image.size.width,
                          y: (1 - crop.maxY) * image.size.height,
                          width: crop.width * image.size.width,
                          height: crop.height * image.size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: from, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        switch ext {
        case "jpg": return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        case "tiff": return rep.representation(using: .tiff, properties: [:])
        default: return rep.representation(using: .png, properties: [:])
        }
    }

    // MARK: - Pestañas por teclado

    /// ⌘W: cierra lo que esté delante (lightbox, hoja, panel) o, si no, el tablero activo.
    func closeFrontmost() {
        if lightboxItem != nil { lightboxItem = nil; return }
        if let key = NSApp.keyWindow, key.isSheet || key is NSPanel {
            key.performClose(nil)
            return
        }
        if let id = library.activeBoardID {
            closeTab(id)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    /// ⌘1…⌘8 van a esa pestaña; ⌘9 a la última, como en los navegadores.
    func selectTab(number n: Int) {
        let tabs = library.openBoardIDs
        guard !tabs.isEmpty else { return }
        let index = n == 9 ? tabs.count - 1 : n - 1
        guard tabs.indices.contains(index) else { return }
        select(board: tabs[index])
    }

    /// ⇧⌘] / ⇧⌘[: pestaña siguiente o anterior, dando la vuelta.
    func selectAdjacentTab(_ step: Int) {
        let tabs = library.openBoardIDs
        guard !tabs.isEmpty else { return }
        let current = library.activeBoardID.flatMap { tabs.firstIndex(of: $0) } ?? 0
        select(board: tabs[(current + step + tabs.count) % tabs.count])
    }

    // MARK: - Portapapeles

    /// Tipo propio: las piezas completas en JSON, para pegarlas idénticas dentro de la app.
    static let itemsPasteboardType = NSPasteboard.PasteboardType("com.simon.moodboard.items")

    /// Zona del tablero visible en pantalla (en coordenadas del tablero); la mantiene BoardCanvas.
    var visibleWorldRect: CGRect = .zero
    /// Pegados seguidos desde la misma copia: cada uno se corre un poco más.
    private var pasteCount = 0

    func selectAll() {
        selection = Set(activeBoard?.items.map(\.id) ?? [])
        editingItem = nil
    }

    /// Copia la selección: piezas para esta app, y además imagen y texto para otras apps.
    func copySelection() {
        guard let board = activeBoard else { return }
        let items = board.items.filter { selection.contains($0.id) }.sorted { $0.z < $1.z }
        guard !items.isEmpty, let data = try? JSONEncoder().encode(items) else { return }

        let entry = NSPasteboardItem()
        entry.setData(data, forType: Self.itemsPasteboardType)
        let texts = items.map(\.text).filter { !$0.isEmpty }
        if !texts.isEmpty { entry.setString(texts.joined(separator: "\n\n"), forType: .string) }
        if let file = items.first(where: { $0.media != nil })?.media,
           let tiff = ImageCache.shared.image(named: file)?.tiffRepresentation {
            entry.setData(tiff, forType: .tiff)
            if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                entry.setData(png, forType: .png)
            }
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])
        pasteCount = 0
    }

    /// Cortar no pasa por la papelera: se deshace con ⌘Z o se recupera pegando.
    func cutSelection() {
        copySelection()
        deleteSelection(toTrash: false)
        pasteCount = -1   // el primer pegado después de cortar va en el mismo sitio
    }

    /// Pega piezas copiadas en la app; si no hay, imágenes, archivos o texto de otras apps.
    func paste() {
        guard activeBoard != nil else { return }
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.itemsPasteboardType),
           let items = try? JSONDecoder().decode([BoardItem].self, from: data), !items.isEmpty {
            pasteItems(items)
        } else {
            pasteFromClipboard(at: CGPoint(x: visibleWorldRect.midX, y: visibleWorldRect.midY))
        }
    }

    /// Si el original está a la vista, la copia aparece desplazada 20 px por pegado;
    /// si no, se centra en lo que se está viendo.
    private func pasteItems(_ items: [BoardItem]) {
        let bounds = items.dropFirst().reduce(items[0].frameRect) { $0.union($1.frameRect) }
        pasteCount += 1
        var dx = 20 * Double(pasteCount), dy = dx
        if !visibleWorldRect.isEmpty, !visibleWorldRect.intersects(bounds) {
            dx += Grid.snap(visibleWorldRect.midX - bounds.midX)
            dy += Grid.snap(visibleWorldRect.midY - bounds.midY)
        }
        checkpoint()
        var ids: Set<UUID> = []
        mutateBoard { board in
            var z = board.topZ
            for var item in items {
                item.id = UUID()
                item.x += dx
                item.y += dy
                item.z = z
                z += 1
                ids.insert(item.id)
                board.items.append(item)
            }
        }
        editingItem = nil
        selection = ids
        focusArea = .canvas
    }

    // MARK: - Papelera

    private func moveToTrash(_ entries: [TrashEntry]) {
        library.trash.insert(contentsOf: entries, at: 0)
        if library.trash.count > trashLimit { library.trash.removeLast(library.trash.count - trashLimit) }
    }

    /// Devuelve lo eliminado a su sitio. Si su tablero ya no existe, va al tablero activo.
    func restore(_ entryID: UUID) {
        guard let entry = library.trash.first(where: { $0.id == entryID }) else { return }
        checkpoint()
        library.trash.removeAll { $0.id == entryID }
        switch entry.content {
        case .board(let board):
            library.boards.append(board)
            select(board: board.id)
        case .item(let item, let boardID, _):
            if library.boards.contains(where: { $0.id == boardID }) { select(board: boardID) }
            mutateBoard { board in
                var new = item
                new.z = board.topZ
                board.items.append(new)
            }
            selection = [item.id]
        }
        scheduleSave()
    }

    func deletePermanently(_ entryID: UUID) {
        checkpoint()
        library.trash.removeAll { $0.id == entryID }
        scheduleSave()
    }

    func emptyTrash() {
        checkpoint()
        library.trash.removeAll()
        scheduleSave()
    }

    // MARK: - Importar imágenes

    /// Copia una imagen al almacén y devuelve la pieza lista para colocar.
    func makeImageItem(from url: URL, at point: CGPoint, kind: ItemKind = .image) -> BoardItem? {
        guard let stored = copyIntoMedia(url) else { return nil }
        return imageItem(fileName: stored, at: point, kind: kind)
    }

    func makeImageItem(from data: Data, ext: String, at point: CGPoint, kind: ItemKind = .image) -> BoardItem? {
        let name = UUID().uuidString + "." + ext
        let dest = Store.mediaDir.appendingPathComponent(name)
        guard (try? data.write(to: dest)) != nil else { return nil }
        return imageItem(fileName: name, at: point, kind: kind)
    }

    private func imageItem(fileName: String, at point: CGPoint, kind: ItemKind) -> BoardItem {
        let url = Store.mediaDir.appendingPathComponent(fileName)
        let pixels = NSImage(contentsOf: url)?.size ?? CGSize(width: 320, height: 220)
        // Las fotos entran con un ancho fijo; el alto sigue la proporción original.
        var w = Grid.imageWidth
        var h = Grid.snap(w * pixels.height / max(pixels.width, 1))
        if kind == .frame {
            // Las viñetas se normalizan a 16:9 con espacio extra para el pie.
            w = 320; h = 320 * 9 / 16 + 34
        }
        return BoardItem(kind: kind,
                         x: Grid.snap(point.x - w / 2),
                         y: Grid.snap(point.y - h / 2),
                         w: w, h: h,
                         media: fileName)
    }

    private func copyIntoMedia(_ url: URL) -> String? {
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let name = UUID().uuidString + "." + ext
        let dest = Store.mediaDir.appendingPathComponent(name)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return name
        } catch {
            // Algunas fuentes (Fotos, navegadores) sólo dan datos, no un archivo copiable.
            guard let data = try? Data(contentsOf: url), (try? data.write(to: dest)) != nil else { return nil }
            return name
        }
    }

    /// Pega imágenes o texto del portapapeles en el punto indicado.
    func pasteFromClipboard(at point: CGPoint) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            var offset = CGPoint.zero
            for url in urls where isImage(url) {
                if let item = makeImageItem(from: url, at: point + offset) {
                    add(item)
                    offset.x += 24; offset.y += 24
                }
            }
            if !urls.filter(isImage).isEmpty { return }
        }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]),
           let item = makeImageItem(from: png, ext: "png", at: point) {
            add(item)
            return
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            add(noteItem(at: point, text: text))
        }
    }

    /// Bloque de texto sin fondo, listo para escribir desde el punto clicado.
    func textItem(at point: CGPoint) -> BoardItem {
        var item = BoardItem(kind: .text, x: Grid.snap(point.x), y: Grid.snap(point.y - 20), w: 320, h: 40)
        item.h = textHeight(for: item)
        return item
    }

    /// Alto que necesita un bloque de texto para su contenido, redondeado a la retícula.
    func textHeight(for item: BoardItem) -> Double {
        let font = item.nsFont
        let sample = item.text.isEmpty ? "M" : item.text + (item.text.hasSuffix("\n") ? "M" : "")
        let rect = (sample as NSString).boundingRect(
            with: CGSize(width: max(item.w - TextMetrics.horizontalInset * 2, 10), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return Grid.snapUp(ceil(rect.height) + TextMetrics.verticalInset * 2)
    }

    /// Un bloque de texto que se deja vacío al terminar de editar desaparece.
    private func discardIfEmptyText(_ id: UUID) {
        for b in library.boards.indices {
            if let i = library.boards[b].items.firstIndex(where: { $0.id == id }),
               library.boards[b].items[i].kind == .text,
               library.boards[b].items[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                library.boards[b].items.remove(at: i)
                selection.remove(id)
                scheduleSave()
            }
        }
    }

    /// Aplica familia y/o tamaño a las piezas de texto seleccionadas.
    func applyFont(family: String?, size: Double? = nil, keepFamily: Bool = false) {
        let ids = selection
        checkpoint()
        mutateBoard { board in
            for i in board.items.indices where ids.contains(board.items[i].id) && board.items[i].kind.hasTypography {
                if !keepFamily { board.items[i].fontFamily = family }
                if let size { board.items[i].fontSize = size }
            }
        }
        refitTextHeights(ids)
    }

    func refitTextHeights(_ ids: Set<UUID>) {
        mutateBoard { board in
            for i in board.items.indices where ids.contains(board.items[i].id) && board.items[i].kind == .text {
                board.items[i].h = textHeight(for: board.items[i])
            }
        }
    }

    func noteItem(at point: CGPoint, text: String = "") -> BoardItem {
        BoardItem(kind: .note, x: point.x - 110, y: point.y - 70, w: 220, h: 140,
                  text: text, colorHex: Palette.colors[0])
    }

    private func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    /// Diálogo nativo para elegir fotos.
    func importWithPanel(at point: CGPoint, kind: ItemKind = .image) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Agregar"
        guard panel.runModal() == .OK else { return }
        var offset = CGPoint.zero
        for url in panel.urls {
            if let item = makeImageItem(from: url, at: point + offset, kind: kind) {
                add(item)
                offset.x += 28; offset.y += 28
            }
        }
    }
}

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
