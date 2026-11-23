import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

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
    /// Muestra la modal que pide el nombre del tablero nuevo.
    @Published var isNamingNewBoard = false
    /// Tipo de documento que propone la modal de «Nuevo…».
    @Published var newDocumentKind: DocumentKind = .board
    @Published var isShowingTrash = false
    /// Bandeja de entrada: capturas que esperan en el servidor para cargarse en un tablero.
    @Published var isShowingInbox = false
    @Published var inboxItems: [InboxItem] = []
    /// Cascada de las piezas que se van cargando desde la bandeja, para que no caigan unas sobre otras.
    private var inboxPlaceCount = 0
    /// Capturas que se están cargando ahora mismo (descarga en curso): se ocultan de la bandeja para
    /// que un refresco no las muestre de nuevo y se carguen dos veces.
    private var importingInboxIDs: Set<String> = []
    /// Modal de ajustes de sincronización con el servidor.
    @Published var isShowingSync = false
    /// Hoja de "Compartir tablero" con el enlace público.
    @Published var isShowingShare = false
    /// Enlace público del tablero activo (nil mientras se prepara o si no está compartido).
    @Published var shareURL: URL?
    /// true mientras se sube el tablero al servidor y se pide el enlace.
    @Published var isPreparingShare = false
    /// Aviso simple (p. ej. una carpeta que apunta a un tablero que ya no existe).
    @Published var alertMessage: String?
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

    /// Sondeo periódico del servidor para ver cambios de otro equipo sin tener que reactivar la ventana
    /// (sincronización casi en vivo).
    private let pollInterval = 15.0
    private var pollTask: Task<Void, Never>?

    /// Instancia viva del Store, para que el delegado de la app pueda vaciar lo pendiente al cerrar.
    static weak var current: Store?

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

    /// Sincronización con el servidor (Cloudflare). Local-first: la app no depende de la red.
    let sync = SyncService.shared

    /// true si `library` se leyó de verdad del disco; false si es el starter de relleno (archivo
    /// ausente o ilegible). Nunca subimos ni fusionamos un starter de relleno: así un arranque sin
    /// datos locales no puede pisar lo que el servidor sí tenga.
    private let loadedFromDisk: Bool

    /// Hay un pull+fusión en curso (arranque o enfoque de la ventana): evita que se solapen dos.
    private var isSyncInFlight = false
    /// El arranque (que decide con cuidado si adoptar o fusionar según haya datos locales fiables) ya
    /// corrió. Hasta entonces, el refresco al enfocar no actúa: fusionar el tablero de relleno con el
    /// servidor podría subir basura.
    private var didBootstrap = false

    init() {
        if let data = try? Data(contentsOf: Store.libraryFile),
           let decoded = try? JSONDecoder().decode(Library.self, from: data) {
            library = decoded
            loadedFromDisk = true
        } else {
            library = .starter
            loadedFromDisk = false
        }
        // Sin tablero activo (se cerraron todas las pestañas) la app abre en la vista de inicio.
        library.trash.removeAll { $0.deletedAt.timeIntervalSinceNow < -trashMaxAge }
        // Poda las lápidas de borrado más antiguas que la papelera: pasado ese plazo, dejan de hacer falta.
        let tombCutoff = Date().addingTimeInterval(-trashMaxAge)
        library.deletedBoardIDs = library.deletedBoardIDs?.filter { $0.value > tombCutoff }
        for i in library.boards.indices {
            library.boards[i].deletedItemIDs = library.boards[i].deletedItemIDs?.filter { $0.value > tombCutoff }
        }
        // Repara en el acto documentos inflados por duplicación (versión vieja del sync): colapsa las
        // piezas con id repetido. Se persiste más abajo para no rehacerlo en cada arranque y para que
        // la versión limpia acabe subiendo al servidor.
        let healedDuplicates = loadedFromDisk && library.dedupeItems()
        let existing = Set(library.boards.map(\.id))
        library.openBoardIDs = library.openBoardIDs.filter(existing.contains)
        if let active = library.activeBoardID, !existing.contains(active) { library.activeBoardID = nil }
        if let active = library.activeBoardID, !library.openBoardIDs.contains(active) {
            library.openBoardIDs.append(active)
        }
        // Al abrir la app, el tablero activo se muestra desde su esquina superior izquierda.
        boardToFrame = library.activeBoardID

        // El servidor puede adoptar un documento más nuevo que el local.
        sync.applyRemoteLibrary = { [weak self] remote in self?.adoptRemoteLibrary(remote) }
        // Al llegar una imagen del servidor, redibujar las vistas (que observan el Store).
        sync.onMediaArrived = { [weak self] in self?.objectWillChange.send() }
        Task { await bootstrapSync() }
        registerLifecycleObservers()
        Store.current = self
        startPolling()
        // Guarda ya el documento reparado (y lo encola para subir), para no rehacer la limpieza en
        // cada arranque y para sanear también la copia del servidor.
        if healedDuplicates { saveNow() }
    }

    /// Reduce la pérdida de datos entre equipos enganchando la sincronización al ciclo de vida:
    ///  - al activarse la ventana (volver a la app, cambiar de app y volver): baja y fusiona lo del
    ///    servidor, para ver lo que hiciste en el otro equipo *antes* de ponerte a editar;
    ///  - al desactivarse / cerrar / dormir el equipo: empuja ya lo pendiente, sin esperar el retraso
    ///    habitual, para que tus cambios salgan de este equipo antes de apagarlo.
    private func registerLifecycleObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshFromServer()
                await self?.refreshInbox()   // ver lo recién capturado con la extensión sin reabrir la app
            }
        }
        for name in [NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.flush() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        // Al despertar el equipo: vuelve a bajar lo que haya cambiado en el otro equipo mientras dormía.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshFromServer()
                await self?.refreshInbox()
            }
        }
    }

    // MARK: - Sondeo en vivo

    /// Arranca el bucle de sondeo: cada `pollInterval` pregunta al servidor sólo la revisión y, si hay
    /// algo nuevo, baja y fusiona. Así un equipo que quedó abierto ve los cambios del otro sin que
    /// haya que reactivar la ventana.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 15))
                guard !Task.isCancelled else { return }
                await self?.pollForChanges()
            }
        }
    }

    /// Comprobación barata: si el servidor tiene una revisión distinta de la conocida, baja y fusiona.
    /// No interrumpe una edición de texto en curso ni se solapa con otra sincronización.
    func pollForChanges() async {
        guard SyncConfig.isConfigured, didBootstrap, !isSyncInFlight, editingItem == nil,
              let remote = await sync.pollRevision() else { return }
        if remote != SyncConfig.knownRevision {
            await refreshFromServer()
            await refreshInbox()
        }
    }

    /// Fuerza que lo pendiente llegue al disco y al servidor ya mismo (sin el retraso habitual).
    func flush() {
        saveTask?.cancel()
        saveNow()                       // escribe a disco y agenda el push
        sync.pushImmediately(library)   // y lo empuja sin esperar
    }

    /// Como `flush`, pero **espera** a que el empujón al servidor termine. Lo usa el delegado de la app
    /// al cerrar, para que los últimos cambios salgan de este equipo antes de que muera el proceso
    /// (si no, la subida async se perdía al terminar). El tope de tiempo lo pone quien llama.
    func flushAndWait() async {
        saveTask?.cancel()
        saveNow()
        await sync.pushNow(library)
    }

    /// Baja la biblioteca del servidor y la fusiona con la local. Sólo reemplaza lo que esté en
    /// pantalla si algo cambió de verdad (así no se pierde la selección al enfocar la ventana) y
    /// conserva el encuadre local de cada tablero (no da saltos la vista). No interrumpe una edición
    /// de texto en curso.
    func refreshFromServer() async {
        guard SyncConfig.isConfigured, didBootstrap, !isSyncInFlight, editingItem == nil else { return }
        isSyncInFlight = true
        defer { isSyncInFlight = false }
        guard let (remote, revision) = await sync.pull() else { return }
        var merged = library.merged(with: remote)
        // Conserva el encuadre (cámara) local de cada tablero: lo de otro equipo no mueve tu vista.
        for i in merged.boards.indices {
            if let local = library.boards.first(where: { $0.id == merged.boards[i].id }) {
                merged.boards[i].camera = local.camera
            }
        }
        let localBehind = merged.boards != library.boards || merged.trash != library.trash
        let serverBehind = merged.boards != remote.boards || merged.trash != remote.trash
        if localBehind {
            // La fusión trae algo nuevo: instálala (y súbela si el servidor también va por detrás).
            installFromSync(merged, revision: revision, pushBack: serverBehind)
            await sync.reconcile(referenced: SyncService.referencedMedia(library))
        } else {
            SyncConfig.knownRevision = revision
            // Lo local ya estaba al día; si el servidor va por detrás (cambios que nunca subieron, o
            // una subida que falló), súbele la unión ahora.
            if serverBehind { await sync.pushNow(merged) }
        }
    }

    // MARK: - Sincronización

    /// Sincroniza bajo demanda (p. ej. tras configurar el servidor en los ajustes).
    func resync() async { await bootstrapSync() }

    // MARK: - Compartir

    /// Tablero visual (no carpeta) con contenido: lo único que se puede compartir por ahora.
    var canShareActiveBoard: Bool {
        guard let board = activeBoard else { return false }
        return board.isBoard && !board.items.isEmpty
    }

    /// Publica el tablero activo y abre la hoja con el enlace público (en vivo).
    /// Si el servidor no está configurado, lleva a los ajustes de sincronización.
    func shareActiveBoard() {
        guard let board = activeBoard, board.isBoard else { return }
        guard SyncConfig.isConfigured else { isShowingSync = true; return }
        shareURL = nil
        isPreparingShare = true
        isShowingShare = true
        let id = board.id
        Task {
            // Si el tablero ya estaba compartido, muestra el enlace al instante (copiable) sin esperar
            // a subir la última versión: el enlace es en vivo y las imágenes se ponen al día detrás.
            if let token = await sync.sharedToken(boardID: id) {
                shareURL = SyncConfig.publicURL(token: token)
                isPreparingShare = false
            }
            // Garantiza que el servidor tiene la última versión del documento y sus imágenes. `pushNow`
            // ya sube las imágenes referenciadas en paralelo (vía `reconcile`), así que no hace falta
            // recorrerlas aquí una a una (eso eran N viajes de red en serie antes de dar el enlace).
            await sync.pushNow(library)
            if let token = await sync.share(boardID: id) {
                shareURL = SyncConfig.publicURL(token: token)
            }
            isPreparingShare = false
        }
    }

    /// Marca (o desmarca) una foto como portada del enlace compartido.
    func setCover(_ id: UUID) {
        guard let media = activeBoard?.items.first(where: { $0.id == id })?.media else { return }
        checkpoint()
        mutateBoard { $0.cover = ($0.cover == media) ? nil : media }
    }

    /// true si esta foto es la portada actual del tablero.
    func isCover(_ id: UUID) -> Bool {
        guard let item = activeBoard?.items.first(where: { $0.id == id }) else { return false }
        return item.media != nil && item.media == activeBoard?.cover
    }

    /// Revoca el enlace del tablero activo.
    func unshareActiveBoard() {
        guard let id = activeBoard?.id else { return }
        Task { await sync.unshare(boardID: id) }
        shareURL = nil
        isShowingShare = false
    }

    /// Al abrir: baja lo que haya en el servidor y lo **une** con lo local, para que ninguna de las
    /// dos partes pueda borrar tableros de la otra. Nunca se adopta un remoto a ciegas (eso era lo
    /// que, con un servidor vacío a una revisión mayor, borraba todo el contenido). Luego concilia
    /// las imágenes.
    private func bootstrapSync() async {
        guard SyncConfig.isConfigured, !isSyncInFlight else { return }
        isSyncInFlight = true
        defer { isSyncInFlight = false; didBootstrap = true }
        if let (remote, revision) = await sync.pull() {
            if loadedFromDisk {
                // Disco + servidor se funden; subimos la unión para que el servidor quede igual.
                installFromSync(library.merged(with: remote), revision: revision, pushBack: true)
            } else {
                // Sin datos locales fiables (archivo ausente o ilegible): manda el servidor, y no
                // aportamos el tablero de relleno del arranque ni lo subimos.
                installFromSync(remote, revision: revision, pushBack: false)
            }
        } else if loadedFromDisk {
            // Servidor vacío (404) y sí tenemos datos reales: suben como primera revisión.
            // Si lo local fuese sólo el starter de relleno, no subimos nada: no pisamos el servidor.
            await sync.pushNow(library)
        }
        await sync.refreshUsage()   // conoce la cuota antes de reconciliar (para el freno de subidas)
        await sync.reconcile(referenced: SyncService.referencedMedia(library))
        await refreshInbox()
    }

    /// Instala una biblioteca venida del servidor (ya fusionada o adoptada tal cual), la guarda en
    /// disco y, si procede, sube el resultado para que el servidor quede con la misma versión.
    /// Deja antes una copia de seguridad sólo si cambió el conjunto de tableros (evita basura).
    private func installFromSync(_ newLibrary: Library, revision: Int, pushBack: Bool) {
        let changed = Set(newLibrary.boards.map(\.id)) != Set(library.boards.map(\.id))
        if changed { backupLocalLibrary() }
        library = newLibrary
        SyncConfig.knownRevision = revision
        let existing = Set(library.boards.map(\.id))
        library.openBoardIDs = library.openBoardIDs.filter(existing.contains)
        if let active = library.activeBoardID, !existing.contains(active) { library.activeBoardID = nil }
        // Conserva lo que esté seleccionado/editándose si sigue existiendo tras la fusión (así un
        // refresco al enfocar la ventana no te quita la selección sin motivo).
        let liveItems = Set(activeBoard?.items.map(\.id) ?? [])
        selection = selection.intersection(liveItems)
        if let editing = editingItem, !liveItems.contains(editing) { editingItem = nil }
        saveLocalOnly()
        if pushBack { Task { await sync.pushNow(library) } }
    }

    /// Un documento que llega del servidor en caliente se **une** al local (nunca lo reemplaza a
    /// ciegas), conservando lo que el usuario está viendo.
    private func adoptRemoteLibrary(_ remote: Library) {
        installFromSync(library.merged(with: remote), revision: SyncConfig.knownRevision, pushBack: false)
        Task { await sync.reconcile(referenced: SyncService.referencedMedia(library)) }
    }

    /// Copia de respaldo del library.json actual antes de sobrescribirlo con el remoto.
    private func backupLocalLibrary() {
        guard let data = try? JSONEncoder().encode(library) else { return }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "library.prelaunch-sync-\(f.string(from: Date())).json"
        try? data.write(to: Store.root.appendingPathComponent(name))
    }

    /// Guarda solo en disco, sin re-empujar al servidor (para no entrar en bucle al adoptar remoto).
    private func saveLocalOnly() {
        guard let data = try? JSONEncoder().encode(library) else { return }
        let tmp = Store.root.appendingPathComponent("library.json.tmp")
        try? data.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(Store.libraryFile, withItemAt: tmp)
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
        sync.schedulePush(library)
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

    /// Mueve o hace zoom de la cámara del tablero activo. Navegar no es una edición: no sella
    /// `modifiedAt` ni empuja al servidor (eso sólo generaba tráfico y conflictos de fusión por
    /// mirar el tablero), y guarda en disco con un retraso largo. La próxima edición real sube la
    /// cámara junto a lo demás. Esto quita el guardado + push que antes se disparaban en cada frame
    /// de pan/zoom, que era lo que más pesaba al navegar tableros con muchos elementos.
    func moveCamera(_ change: (inout Camera) -> Void) {
        guard let i = activeIndex else { return }
        change(&library.boards[i].camera)
        scheduleCameraSave()
    }

    private var cameraSaveTask: Task<Void, Never>?
    private func scheduleCameraSave() {
        cameraSaveTask?.cancel()
        cameraSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.saveLocalOnly()
        }
    }

    /// Mueve en bloque un conjunto de piezas desde sus orígenes guardados: un solo publish y un solo
    /// guardado por frame, en vez de uno por pieza. Arrastrar un grupo grande no debe re-renderizar
    /// ni re-guardar la biblioteca entera una vez por cada pieza seleccionada.
    func moveItems(origins: [UUID: CGPoint], by offset: CGSize) {
        mutateBoard { board in
            let now = Date()
            for (id, origin) in origins {
                guard let i = board.items.firstIndex(where: { $0.id == id }) else { continue }
                board.items[i].origin = CGPoint(x: origin.x + offset.width, y: origin.y + offset.height)
                board.items[i].modifiedAt = now
            }
        }
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

    // MARK: - Vínculos entre documentos (guion ↔ tablero)

    /// Vincula dos documentos en ambos sentidos (simétrico).
    func linkBoards(_ a: UUID, _ b: UUID) {
        guard a != b else { return }
        checkpoint()
        addLink(from: a, to: b)
        addLink(from: b, to: a)
        scheduleSave()
    }

    /// Crea un documento del tipo dado y lo vincula al actual, sin salir de donde estás.
    func newLinkedDocument(kind: DocumentKind, linkedTo id: UUID) {
        checkpoint()
        let board = makeBoard(named: kind.untitled, kind: kind)
        library.boards.append(board)
        addLink(from: id, to: board.id)
        addLink(from: board.id, to: id)
        scheduleSave()
    }

    func unlinkBoards(_ a: UUID, _ b: UUID) {
        checkpoint()
        removeLink(from: a, to: b)
        removeLink(from: b, to: a)
        scheduleSave()
    }

    private func addLink(from: UUID, to: UUID) {
        guard let i = library.boards.firstIndex(where: { $0.id == from }) else { return }
        var ids = library.boards[i].linkedBoardIDs ?? []
        if !ids.contains(to) { ids.append(to) }
        library.boards[i].linkedBoardIDs = ids
        library.boards[i].modifiedAt = Date()
    }

    private func removeLink(from: UUID, to: UUID) {
        guard let i = library.boards.firstIndex(where: { $0.id == from }) else { return }
        library.boards[i].linkedBoardIDs?.removeAll { $0 == to }
        library.boards[i].modifiedAt = Date()
    }

    /// Documentos vinculados a `id` (unión de ambos sentidos), sólo los que existen, en el orden de la
    /// biblioteca. Tolera que la fusión haya dejado el vínculo anotado en un solo lado.
    func linkedBoards(of id: UUID) -> [Board] {
        var ids = Set(library.boards.first { $0.id == id }?.linkedBoardIDs ?? [])
        for b in library.boards where (b.linkedBoardIDs ?? []).contains(id) { ids.insert(b.id) }
        ids.remove(id)
        return library.boards.filter { ids.contains($0.id) }
    }

    // MARK: - Desglose por escena

    func sceneDetail(_ sceneID: UUID) -> SceneDetail {
        activeBoard?.sceneDetails?[sceneID.uuidString] ?? SceneDetail()
    }

    private func mutateSceneDetail(_ sceneID: UUID, coalescing: String? = nil, _ change: (inout SceneDetail) -> Void) {
        checkpoint(coalescing: coalescing)
        mutateBoard { board in
            var map = board.sceneDetails ?? [:]
            var detail = map[sceneID.uuidString] ?? SceneDetail()
            change(&detail)
            map[sceneID.uuidString] = detail
            board.sceneDetails = map
        }
    }

    func setSceneSynopsis(_ sceneID: UUID, _ text: String) {
        mutateSceneDetail(sceneID, coalescing: "synopsis-\(sceneID.uuidString)") { $0.synopsis = text }
    }

    /// Añade un ítem a mano a un departamento de una escena.
    func addBreakdownItem(_ sceneID: UUID, _ dept: Department, _ text: String) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        mutateSceneDetail(sceneID) { detail in
            var list = detail.added[dept.rawValue] ?? []
            if !list.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { list.append(name) }
            detail.added[dept.rawValue] = list
            detail.removed.removeAll { $0 == name.lowercased() }
        }
    }

    /// Quita un ítem: si era manual lo borra; si era detectado, lo marca como quitado para que no vuelva.
    func removeBreakdownItem(_ sceneID: UUID, _ dept: Department, _ text: String) {
        mutateSceneDetail(sceneID) { detail in
            let key = dept.rawValue
            if let list = detail.added[key], list.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                let filtered = list.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
                detail.added[key] = filtered.isEmpty ? nil : filtered
            } else {
                let lower = text.lowercased()
                if !detail.removed.contains(lower) { detail.removed.append(lower) }
                detail.assigned[lower] = nil
            }
        }
    }

    /// Asigna un objeto detectado (sin clasificar o mal clasificado) a un departamento.
    func assignBreakdownItem(_ sceneID: UUID, _ noun: String, to dept: Department) {
        let lower = noun.lowercased()
        mutateSceneDetail(sceneID) { detail in
            detail.assigned[lower] = dept.rawValue
            detail.removed.removeAll { $0 == lower }
        }
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
    /// Si el sub-tablero ya no existe (p. ej. se perdió en una fusión de sincronización), la carpeta
    /// queda huérfana y antes no hacía nada al pulsarla; ahora se avisa en vez de fallar en silencio.
    func openBoardFolder(_ item: BoardItem) {
        guard let child = item.childBoardID else { return }
        guard library.boards.contains(where: { $0.id == child }) else {
            let name = item.text.isEmpty ? "Este tablero" : "«\(item.text)»"
            alertMessage = "\(name) ya no existe. Puedes quitar esta carpeta vacía desde su menú contextual (clic derecho › Eliminar)."
            return
        }
        select(board: child)
    }

    /// Mueve piezas sueltas del tablero activo al sub-tablero de una carpeta (arrastrar y soltar encima).
    /// Conserva sus ids y sus medios; escribe lápidas en el origen para que la fusión con otro equipo no
    /// las resucite, y retira la posible lápida en el destino. Una columna movida se lleva su contenido;
    /// una carpeta movida reapunta el `parentID` de su propio sub-tablero al destino.
    func moveToFolder(_ ids: Set<UUID>, folderItemID: UUID) {
        guard let board = activeBoard,
              let folder = board.items.first(where: { $0.id == folderItemID }),
              folder.kind == .board, let childID = folder.childBoardID,
              let childIndex = library.boards.firstIndex(where: { $0.id == childID }) else { return }
        // Nunca la propia carpeta; e incluye los hijos de las columnas movidas, para que lleguen completas.
        var included = ids
        included.remove(folderItemID)
        for item in board.items where included.contains(item.id) && item.kind == .column {
            included.formUnion(item.children ?? [])
        }
        let moving = board.items.filter { included.contains($0.id) }
        guard !moving.isEmpty else { return }
        checkpoint()
        let movingIDs = Set(moving.map(\.id))
        // Reapunta los sub-tableros de las carpetas movidas al nuevo padre (migas de pan correctas).
        for item in moving where item.kind == .board {
            if let gc = item.childBoardID, let i = library.boards.firstIndex(where: { $0.id == gc }) {
                library.boards[i].parentID = childID
            }
        }
        // Quita del tablero activo con lápidas y limpia referencias de columnas que las contuvieran.
        mutateBoard { board in
            let now = Date()
            var tombs = board.deletedItemIDs ?? [:]
            for id in movingIDs { tombs[id.uuidString] = now }
            board.deletedItemIDs = tombs
            board.items.removeAll { movingIDs.contains($0.id) }
            for i in board.items.indices { board.items[i].children?.removeAll { movingIDs.contains($0) } }
        }
        for column in (activeBoard?.items ?? []) where column.kind == .column { refitColumnHeight(column.id) }
        // Añade al sub-tablero, re-sellando cada pieza y retirando su lápida allí si la tuviera.
        var z = library.boards[childIndex].topZ
        for item in moving {
            var new = item
            new.modifiedAt = Date()
            new.z = z; z += 1
            library.boards[childIndex].deletedItemIDs?[item.id.uuidString] = nil
            library.boards[childIndex].items.append(new)
        }
        library.boards[childIndex].modifiedAt = Date()
        selection = []
        scheduleSave()
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
        // Lápidas: registra el borrado para que la fusión no resucite estos tableros en otro equipo.
        let now = Date()
        var tombs = library.deletedBoardIDs ?? [:]
        for id in all { tombs[id.uuidString] = now }
        library.deletedBoardIDs = tombs
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
        // Ids nuevos para cada pieza, reapuntando los hijos de las columnas a las copias.
        // `uniquingKeysWith` (en vez de `uniqueKeysWithValues`) evita abortar si hubiera ids repetidos.
        let idMap = Dictionary(source.items.map { ($0.id, UUID()) }, uniquingKeysWith: { first, _ in first })
        copy.items = source.items.map { item in
            var c = item
            c.id = idMap[item.id] ?? UUID()
            if c.kind == .column, let kids = item.children {
                c.children = kids.compactMap { idMap[$0] }
            }
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
            board.items[i].modifiedAt = Date()   // sella la pieza para fusionar por pieza entre equipos
        }
    }

    func deleteSelection(toTrash: Bool = true) {
        let ids = selection
        guard !ids.isEmpty, let board = activeBoard else { return }
        checkpoint()
        // Las columnas eliminadas devuelven su contenido al lienzo (no se pierde al borrar el organizador).
        for column in board.items where ids.contains(column.id) && column.kind == .column {
            releaseColumn(column.id)
        }
        let removed = (activeBoard ?? board).items.filter { ids.contains($0.id) }
        if toTrash {
            moveToTrash(removed.map {
                TrashEntry(content: .item($0, boardID: board.id, boardName: board.name))
            })
        }
        mutateBoard { board in
            // Lápidas: registra el borrado para que la fusión con otro equipo no resucite estas piezas.
            let now = Date()
            var tombs = board.deletedItemIDs ?? [:]
            for id in ids { tombs[id.uuidString] = now }
            board.deletedItemIDs = tombs
            board.items.removeAll { ids.contains($0.id) }
            // Si lo borrado estaba dentro de una columna, quita también la referencia (no quedan ids colgando).
            for i in board.items.indices { board.items[i].children?.removeAll { ids.contains($0) } }
        }
        // Reajusta el alto de las columnas que hayan perdido contenido.
        for column in (activeBoard?.items ?? []) where column.kind == .column { refitColumnHeight(column.id) }
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
            var copies: [BoardItem] = []
            var z = board.topZ
            for item in board.items where selection.contains(item.id) {
                var c = item
                c.id = UUID()
                c.x += 28
                c.y += 28
                c.z = z; z += 1
                // Una columna duplicada se lleva copias de su contenido, no referencias al original.
                if c.kind == .column, let kids = item.children {
                    c.children = kids.compactMap { kidID in
                        guard var kid = board.items.first(where: { $0.id == kidID }) else { return nil }
                        kid.id = UUID()
                        copies.append(kid)
                        return kid.id
                    }
                }
                newIDs.insert(c.id)
                copies.append(c)
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
            var copies: [BoardItem] = []
            for item in board.items where ids.contains(item.id) {
                var c = item
                c.id = UUID()
                c.z = z; z += 1
                if c.kind == .column, let kids = item.children {
                    c.children = kids.compactMap { kidID in
                        guard var kid = board.items.first(where: { $0.id == kidID }) else { return nil }
                        kid.id = UUID()
                        copies.append(kid)
                        return kid.id
                    }
                }
                map[item.id] = c.id
                copies.append(c)
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
                case .image, .video, .board, .column: break
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
        let claimed = claimedItemIDs
        selection = Set((activeBoard?.items ?? []).map(\.id).filter { !claimed.contains($0) })
        editingItem = nil
    }

    /// Copia la selección: piezas para esta app, y además imagen y texto para otras apps.
    func copySelection() {
        guard let board = activeBoard else { return }
        // Al copiar una columna se copia también su contenido, para que llegue completa al pegar.
        var included = selection
        for item in board.items where selection.contains(item.id) && item.kind == .column {
            included.formUnion(item.children ?? [])
        }
        let items = board.items.filter { included.contains($0.id) }.sorted { $0.z < $1.z }
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
    private func pasteItems(_ rawItems: [BoardItem]) {
        // Descarta piezas con id repetido antes de reasignar ids, por si el portapapeles trae
        // duplicados (documentos heredados): así no se vuelven a crear piezas con el mismo id.
        var seenIDs: Set<UUID> = []
        let items = rawItems.filter { seenIDs.insert($0.id).inserted }
        guard !items.isEmpty else { return }
        let bounds = items.dropFirst().reduce(items[0].frameRect) { $0.union($1.frameRect) }
        pasteCount += 1
        var dx = 20 * Double(pasteCount), dy = dx
        if !visibleWorldRect.isEmpty, !visibleWorldRect.intersects(bounds) {
            dx += Grid.snap(visibleWorldRect.midX - bounds.midX)
            dy += Grid.snap(visibleWorldRect.midY - bounds.midY)
        }
        checkpoint()
        // Ids nuevos para todas las piezas; las columnas conservan su contenido reapuntando a las copias.
        // `uniquingKeysWith` (en vez de `uniqueKeysWithValues`) evita abortar si llegaran ids repetidos.
        let idMap = Dictionary(items.map { ($0.id, UUID()) }, uniquingKeysWith: { first, _ in first })
        let claimed = Set(items.flatMap { $0.children ?? [] }.compactMap { idMap[$0] })
        var topLevel: Set<UUID> = []
        mutateBoard { board in
            var z = board.topZ
            for var item in items {
                let newID = idMap[item.id] ?? UUID()
                item.id = newID
                item.x += dx
                item.y += dy
                item.z = z
                z += 1
                if item.kind == .column, let kids = item.children {
                    item.children = kids.compactMap { idMap[$0] }
                }
                if !claimed.contains(newID) { topLevel.insert(newID) }
                board.items.append(item)
            }
        }
        editingItem = nil
        selection = topLevel
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
            var revived = board
            revived.modifiedAt = Date()               // renace más nuevo que su lápida (gana la fusión)
            library.deletedBoardIDs?[revived.id.uuidString] = nil
            library.boards.append(revived)
            select(board: revived.id)
        case .item(let item, let boardID, _):
            if library.boards.contains(where: { $0.id == boardID }) { select(board: boardID) }
            mutateBoard { board in
                board.deletedItemIDs?[item.id.uuidString] = nil   // retira su lápida: ya no está borrada
                var new = item
                new.z = board.topZ
                new.modifiedAt = Date()               // renace más nueva que su lápida (gana la fusión)
                board.items.append(new)
            }
            selection = [item.id]
        }
        scheduleSave()
    }

    func deletePermanently(_ entryID: UUID) {
        guard let entry = library.trash.first(where: { $0.id == entryID }) else { return }
        checkpoint()
        let candidates = Self.mediaNames(in: entry)
        library.trash.removeAll { $0.id == entryID }
        purgeOrphanMedia(candidates)
        scheduleSave()
    }

    func emptyTrash() {
        checkpoint()
        let candidates = library.trash.reduce(into: Set<String>()) { $0.formUnion(Self.mediaNames(in: $1)) }
        library.trash.removeAll()
        purgeOrphanMedia(candidates)
        scheduleSave()
    }

    /// Nombres de archivo de imagen que usa una entrada de la papelera.
    private static func mediaNames(in entry: TrashEntry) -> Set<String> {
        switch entry.content {
        case .board(let b):             return Set(b.items.compactMap(\.media))
        case .item(let item, _, _):     return item.media.map { [$0] } ?? []
        }
    }

    /// Borra del disco y del servidor las imágenes candidatas que ya no use ninguna
    /// otra parte de la biblioteca (tableros u otras entradas de la papelera).
    private func purgeOrphanMedia(_ candidates: Set<String>) {
        guard !candidates.isEmpty else { return }
        let stillUsed = SyncService.referencedMedia(library)
        let orphans = candidates.subtracting(stillUsed)
        guard !orphans.isEmpty else { return }
        for name in orphans {
            try? FileManager.default.removeItem(at: Store.mediaDir.appendingPathComponent(name))
        }
        // Borra en el servidor y, ya liberado el espacio, recalcula el uso y reintenta lo pausado.
        Task {
            for name in orphans { await sync.deleteMedia(name) }
            await sync.refreshUsage()
        }
    }

    // MARK: - Bandeja de entrada

    /// Baja del servidor la lista de capturas que esperan en la bandeja. Reinicia la cascada de
    /// colocación para que la próxima tanda que se cargue empiece centrada.
    func refreshInbox() async {
        guard SyncConfig.isConfigured else { return }
        if let items = await sync.fetchInbox() {
            // Oculta las que se están cargando en este momento: evita que reaparezcan y se dupliquen.
            inboxItems = items.filter { !importingInboxIDs.contains($0.id) }
        }
        inboxPlaceCount = 0
    }

    /// Id de pieza **determinista** a partir del id de la captura: cargar la misma captura en dos
    /// equipos produce el mismo id, así la fusión la colapsa en una sola pieza en vez de duplicarla.
    /// El id del servidor es un UUID sin guiones (32 hex); se reinsertan para reconstruir el UUID.
    static func itemID(forInbox inboxID: String) -> UUID {
        let hex = inboxID.replacingOccurrences(of: "-", with: "")
        if hex.count == 32 {
            let s = Array(hex)
            let dashed = "\(String(s[0..<8]))-\(String(s[8..<12]))-\(String(s[12..<16]))-\(String(s[16..<20]))-\(String(s[20..<32]))"
            if let u = UUID(uuidString: dashed) { return u }
        }
        return UUID()
    }

    /// Carga una captura de la bandeja en el tablero activo: baja su imagen, la coloca como una pieza
    /// normal (con id determinista) y la consume del servidor (conservando el archivo, que la biblioteca
    /// pasa a usar). Si la pieza ya está en el tablero (la cargó el otro equipo y llegó por sync), no la
    /// vuelve a añadir: solo limpia la bandeja.
    func importFromInbox(_ item: InboxItem) {
        guard let board = activeBoard else { return }
        let itemID = Self.itemID(forInbox: item.id)
        inboxItems.removeAll { $0.id == item.id }   // respuesta inmediata en la bandeja
        if board.items.contains(where: { $0.id == itemID }) {
            Task { await sync.deleteInboxItem(item.id, discardMedia: false) }
            return
        }
        let base = visibleWorldRect.isEmpty ? .zero : CGPoint(x: visibleWorldRect.midX, y: visibleWorldRect.midY)
        let step = Double(inboxPlaceCount) * 26
        inboxPlaceCount += 1
        let point = base + CGPoint(x: step, y: step)
        importingInboxIDs.insert(item.id)
        Task {
            defer { importingInboxIDs.remove(item.id) }
            guard await sync.downloadMedia(item.media) else {
                inboxItems.insert(item, at: 0)   // falló la descarga: devuélvela a la bandeja
                return
            }
            // Si mientras bajaba la imagen la pieza ya llegó por sync, no la dupliques.
            guard activeBoard?.id == board.id,
                  activeBoard?.items.contains(where: { $0.id == itemID }) == false else {
                await sync.deleteInboxItem(item.id, discardMedia: false)
                return
            }
            var piece = item.isVideo ? await videoItem(fileName: item.media, at: point)
                                     : imageItem(fileName: item.media, at: point, kind: .image)
            piece.id = itemID
            add(piece)
            await sync.deleteInboxItem(item.id, discardMedia: false)
        }
    }

    /// Descarta una captura sin cargarla: la borra del servidor (y su imagen de R2) y del disco local.
    func discardInboxItem(_ item: InboxItem) {
        inboxItems.removeAll { $0.id == item.id }
        try? FileManager.default.removeItem(at: Store.mediaDir.appendingPathComponent(item.media))
        Task { await sync.deleteInboxItem(item.id, discardMedia: true) }
    }

    // MARK: - Importar imágenes

    /// Suelta piezas arrastradas al lienzo (Finder, navegador u otras apps), en cascada.
    func drop(_ providers: [NSItemProvider], at point: CGPoint) {
        for (i, provider) in providers.enumerated() {
            loadDropped(provider, at: point + CGPoint(x: Double(i) * 26, y: Double(i) * 26))
        }
    }

    /// Resuelve un elemento arrastrado en orden de preferencia: archivo local, datos de imagen
    /// o, por último, una URL remota que haya que descargar (como al arrastrar desde el navegador).
    private func loadDropped(_ provider: NSItemProvider, at point: CGPoint) {
        // 1) Archivo del Finder. La copia a disco se hace fuera del hilo principal para no congelar
        // la app al soltar; sólo se vuelve a main para insertar la pieza ya lista.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                let kind: ItemKind = Store.isMovie(url) ? .video : .image
                Task.detached(priority: .userInitiated) {
                    guard let name = Store.storeMedia(copyingFrom: url) else { return }
                    await self.placeImported(name, at: point, kind: kind)
                }
            }
            return
        }
        // 2) Datos de video (apps que entregan el archivo como datos, no como URL de Finder).
        if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .movie) == true }) {
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data else { return }
                let ext = UTType(type)?.preferredFilenameExtension ?? "mp4"
                Task.detached(priority: .userInitiated) {
                    guard let name = Store.storeMedia(data: data, ext: ext) else { return }
                    await self.placeImported(name, at: point, kind: .video)
                }
            }
            return
        }
        // 3) Datos de imagen (navegador, apps): tiff, png, jpeg, heic… También fuera de main.
        if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data else { return }
                let ext = UTType(type)?.preferredFilenameExtension ?? "png"
                Task.detached(priority: .userInitiated) {
                    guard let name = Store.storeMedia(data: data, ext: ext) else { return }
                    await self.placeImported(name, at: point, kind: .image)
                }
            }
            return
        }
        // 3) URL remota: se baja la imagen (arrastre de una foto desde una página web).
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.scheme == "http" || url.scheme == "https" else { return }
                Task { @MainActor in await self.addRemoteImage(from: url, at: point) }
            }
        }
    }

    /// Descarga una imagen de una URL http(s) y la coloca en el punto indicado.
    private func addRemoteImage(from url: URL, at point: CGPoint) async {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              NSImage(data: data) != nil else { return }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        if let item = makeImageItem(from: data, ext: ext, at: point) { add(item) }
    }

    /// Inserta en el tablero una imagen ya guardada en el almacén (la copia a disco ya se hizo fuera
    /// del hilo principal) y lanza su subida al servidor. El tamaño se lee de la cabecera, sin decodificar.
    private func placeImported(_ fileName: String, at point: CGPoint, kind: ItemKind) async {
        add(kind == .video ? await videoItem(fileName: fileName, at: point) : imageItem(fileName: fileName, at: point, kind: kind))
        Task { await sync.uploadMedia(fileName, tracked: true) }
    }

    /// true si la URL apunta a un archivo de video (por su UTType). Sólo mira la extensión: apto para fondo.
    nonisolated static func isMovie(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }

    /// Copia una imagen al almacén y devuelve la pieza lista para colocar.
    func makeImageItem(from url: URL, at point: CGPoint, kind: ItemKind = .image) -> BoardItem? {
        guard let stored = copyIntoMedia(url) else { return nil }
        return imageItem(fileName: stored, at: point, kind: kind)
    }

    func makeImageItem(from data: Data, ext: String, at point: CGPoint, kind: ItemKind = .image) -> BoardItem? {
        guard let name = Store.storeMedia(data: data, ext: ext) else { return nil }
        Task { await sync.uploadMedia(name, tracked: true) }
        return imageItem(fileName: name, at: point, kind: kind)
    }

    /// Dimensiones en píxeles leyendo sólo la cabecera del archivo, sin decodificar el bitmap: medir
    /// una foto con `NSImage(contentsOf:)` la descomprimía entera en RAM (cientos de MB en las grandes)
    /// en el hilo principal, lo que congelaba la app al soltarla.
    nonisolated static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        // Orientaciones EXIF 5–8 giran 90°/270°: el ancho y el alto quedan intercambiados.
        if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, o >= 5 {
            return CGSize(width: h, height: w)
        }
        return CGSize(width: w, height: h)
    }

    /// Copia un archivo al almacén de medios y devuelve su nombre. Sólo I/O: apto para ejecutarse fuera
    /// del hilo principal. La subida al servidor la lanza quien inserte la pieza.
    nonisolated static func storeMedia(copyingFrom url: URL) -> String? {
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let name = UUID().uuidString + "." + ext
        let dest = mediaDir.appendingPathComponent(name)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { return name }
        // Algunas fuentes (Fotos, navegadores) sólo dan datos, no un archivo copiable.
        guard let data = try? Data(contentsOf: url), (try? data.write(to: dest)) != nil else { return nil }
        return name
    }

    /// Escribe datos de imagen en el almacén y devuelve el nombre. Sólo I/O, apto para fondo.
    nonisolated static func storeMedia(data: Data, ext: String) -> String? {
        let name = UUID().uuidString + "." + ext
        let dest = mediaDir.appendingPathComponent(name)
        return (try? data.write(to: dest)) != nil ? name : nil
    }

    private func imageItem(fileName: String, at point: CGPoint, kind: ItemKind) -> BoardItem {
        let url = Store.mediaDir.appendingPathComponent(fileName)
        let pixels = Store.pixelSize(of: url) ?? CGSize(width: 320, height: 220)
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

    /// Pieza de video: entra con el ancho fijo de las fotos y el alto según la proporción real del video
    /// (leída de su primera pista); 16:9 de reserva si no se puede medir.
    private func videoItem(fileName: String, at point: CGPoint) async -> BoardItem {
        let url = Store.mediaDir.appendingPathComponent(fileName)
        let natural = await Store.videoSize(of: url) ?? CGSize(width: 320, height: 180)
        let w = Grid.imageWidth
        let h = Grid.snap(w * natural.height / max(natural.width, 1))
        return BoardItem(kind: .video,
                         x: Grid.snap(point.x - w / 2),
                         y: Grid.snap(point.y - h / 2),
                         w: w, h: h,
                         media: fileName)
    }

    /// Dimensiones visibles del video (ancho×alto) leyendo la primera pista; respeta la transformación de
    /// orientación. nil si no se puede medir. Sólo lectura de metadatos: apto para fondo.
    nonisolated static func videoSize(of url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let size = natural.applying(transform)
        let s = CGSize(width: abs(size.width), height: abs(size.height))
        return (s.width > 0 && s.height > 0) ? s : nil
    }

    private func copyIntoMedia(_ url: URL) -> String? {
        guard let name = Store.storeMedia(copyingFrom: url) else { return nil }
        Task { await sync.uploadMedia(name, tracked: true) }
        return name
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
            add(textItem(at: point, text: text))
        }
    }

    /// Nota de texto sin fondo, lista para escribir desde el punto indicado.
    func textItem(at point: CGPoint, text: String = "") -> BoardItem {
        var item = BoardItem(kind: .text, x: Grid.snap(point.x), y: Grid.snap(point.y - 20), w: 320, h: 40, text: text)
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

    // MARK: - Herramientas arrastrables

    /// Crea la pieza de una herramienta soltada en el lienzo y la deja lista para usar.
    /// Si se suelta sobre una columna, la pieza entra en ella.
    func createTool(_ tool: ToolKind, at point: CGPoint) {
        focusArea = .canvas
        switch tool {
        case .board:
            addBoardFolder(at: point)
        case .note:
            let item = textItem(at: point)
            add(item)
            editingItem = item.id
        case .column:
            let item = columnItem(at: point)
            add(item)
            editingItem = item.id   // empieza nombrando la cabecera
        }
    }

    /// Contenedor en columna vacío, centrado en el punto indicado.
    func columnItem(at point: CGPoint) -> BoardItem {
        var item = BoardItem(kind: .column,
                             x: Grid.snap(point.x - 130), y: Grid.snap(point.y - 20),
                             w: 260, h: 0)
        item.children = []
        item.h = columnHeight(for: item)
        return item
    }

    // MARK: - Columnas

    /// Métricas de la tarjeta de columna; las comparten la vista y el cálculo de alto.
    enum ColumnMetrics {
        static let header: Double = 52      // alto de la cabecera con el nombre (más aire arriba/abajo)
        static let padding: Double = 10     // margen interior alrededor del contenido
        static let spacing: Double = 8      // separación entre piezas apiladas
        static let empty: Double = 70       // alto de la zona vacía «arrastra aquí»
        static let boardRow: Double = 44    // alto fijo de una carpeta en una columna (fila compacta)
    }

    /// Alto de la fila que ocupa una pieza dentro de una columna de ancho interior `inner`. Las carpetas
    /// usan una fila compacta de alto fijo (icono + nombre al lado); el resto se ajusta a su proporción.
    func childRowHeight(_ child: BoardItem, inner: Double) -> Double {
        child.kind == .board ? ColumnMetrics.boardRow : child.h * inner / max(child.w, 1)
    }

    /// Alto que necesita una columna para su cabecera y las piezas que contiene, a la retícula.
    func columnHeight(for column: BoardItem) -> Double {
        let inner = max(column.w - ColumnMetrics.padding * 2, 20)
        let ids = column.children ?? []
        let items = ids.compactMap { id in activeBoard?.items.first { $0.id == id } }
        var body = 0.0
        if items.isEmpty {
            body = ColumnMetrics.empty
        } else {
            for (i, child) in items.enumerated() {
                body += childRowHeight(child, inner: inner)
                if i > 0 { body += ColumnMetrics.spacing }
            }
        }
        return Grid.snapUp(ColumnMetrics.header + ColumnMetrics.padding * 2 + body)
    }

    /// Ids de las piezas que ya pertenecen a alguna columna (no se dibujan sueltas en el lienzo).
    var claimedItemIDs: Set<UUID> {
        Set((activeBoard?.items ?? []).flatMap { $0.children ?? [] })
    }

    /// Columna cuyo marco contiene el punto dado (para soltar piezas dentro).
    func columnID(at point: CGPoint) -> UUID? {
        activeBoard?.items.first { $0.kind == .column && $0.frameRect.contains(point) }?.id
    }

    /// Columna cuyo marco **se solapa** con `rect` (la de mayor solape si hay varias). Así basta con
    /// que una esquina de la pieza arrastrada toque la zona del contenedor: no hace falta centrarla.
    func columnID(overlapping rect: CGRect, excluding: Set<UUID> = []) -> UUID? {
        var best: (id: UUID, area: Double)?
        for item in activeBoard?.items ?? [] where item.kind == .column && !excluding.contains(item.id) {
            let inter = item.frameRect.intersection(rect)
            guard !inter.isNull, !inter.isEmpty else { continue }
            let area = Double(inter.width * inter.height)
            if area > (best?.area ?? 0) { best = (id: item.id, area: area) }
        }
        return best?.id
    }

    /// Carpeta (`.board`) cuyo marco contiene el punto dado (para soltar algo dentro con precisión).
    func boardFolderID(at point: CGPoint, excluding: Set<UUID> = []) -> UUID? {
        activeBoard?.items.first { $0.kind == .board && !excluding.contains($0.id) && $0.frameRect.contains(point) }?.id
    }

    /// Carpeta (`.board`) cuyo marco **se solapa** con `rect` (la de mayor solape si hay varias). Igual
    /// que `columnID(overlapping:)`, pero para soltar piezas dentro de una carpeta.
    func boardFolderID(overlapping rect: CGRect, excluding: Set<UUID> = []) -> UUID? {
        var best: (id: UUID, area: Double)?
        for item in activeBoard?.items ?? [] where item.kind == .board && !excluding.contains(item.id) {
            let inter = item.frameRect.intersection(rect)
            guard !inter.isNull, !inter.isEmpty else { continue }
            let area = Double(inter.width * inter.height)
            if area > (best?.area ?? 0) { best = (id: item.id, area: area) }
        }
        return best?.id
    }

    /// Posición (0…nº de hijos) que ocuparía una pieza soltada en `point` dentro de la columna:
    /// compara el punto con el centro de cada hijo ya apilado. La comparte el indicador de la vista.
    func dropIndex(in columnID: UUID, at point: CGPoint) -> Int {
        guard let column = activeBoard?.items.first(where: { $0.id == columnID }) else { return 0 }
        let inner = max(column.w - ColumnMetrics.padding * 2, 20)
        let items = (column.children ?? []).compactMap { id in activeBoard?.items.first { $0.id == id } }
        var y = column.y + ColumnMetrics.header + ColumnMetrics.padding
        for (i, child) in items.enumerated() {
            let h = childRowHeight(child, inner: inner)
            if point.y < y + h / 2 { return i }
            y += h + ColumnMetrics.spacing
        }
        return items.count
    }

    /// Pieza hija cuya fila (en la disposición apilada) contiene el punto del tablero, o nil si el
    /// punto cae en la cabecera o fuera del cuerpo. Sirve para que el arrastre de la columna sepa si
    /// el toque empezó sobre una pieza (y haya que sacarla) o en zona libre (mover la columna).
    func childID(in columnID: UUID, at point: CGPoint) -> UUID? {
        guard let column = activeBoard?.items.first(where: { $0.id == columnID }) else { return nil }
        let inner = max(column.w - ColumnMetrics.padding * 2, 20)
        let items = (column.children ?? []).compactMap { id in activeBoard?.items.first { $0.id == id } }
        var y = column.y + ColumnMetrics.header + ColumnMetrics.padding
        for child in items {
            let h = childRowHeight(child, inner: inner)
            if point.y >= y && point.y < y + h { return child.id }
            y += h + ColumnMetrics.spacing
        }
        return nil
    }

    /// Mete piezas en una columna (en `index`, o al final si es nil), quitándolas de cualquier otra.
    /// Devuelve si cambió algo.
    @discardableResult
    func claim(_ ids: [UUID], into columnID: UUID, at index: Int? = nil) -> Bool {
        let incoming = ids.filter { $0 != columnID && itemKind($0) != .column }
        guard !incoming.isEmpty else { return false }
        mutateBoard { board in
            // Primero se desvinculan de su columna anterior.
            for i in board.items.indices {
                board.items[i].children?.removeAll { incoming.contains($0) }
            }
            guard let c = board.items.firstIndex(where: { $0.id == columnID }) else { return }
            var list = board.items[c].children ?? []
            let at = min(max(index ?? list.count, 0), list.count)
            list.insert(contentsOf: incoming, at: at)
            board.items[c].children = list
        }
        refitColumnHeight(columnID)
        return true
    }

    /// Saca las piezas de una columna y las reparte sueltas bajo ella, en el lienzo.
    /// El historial lo registra quien llama (el menú «Vaciar» o `deleteSelection`).
    func releaseColumn(_ columnID: UUID) {
        guard let column = activeBoard?.items.first(where: { $0.id == columnID }),
              let ids = column.children, !ids.isEmpty else { return }
        var y = column.frameRect.maxY + Grid.gutter
        let x = Grid.snap(column.x)
        mutateBoard { board in
            for id in ids {
                guard let i = board.items.firstIndex(where: { $0.id == id }) else { continue }
                board.items[i].x = x
                board.items[i].y = Grid.snap(y)
                y += board.items[i].h + Grid.gutter
            }
            if let c = board.items.firstIndex(where: { $0.id == columnID }) {
                board.items[c].children = []
            }
        }
        refitColumnHeight(columnID)
    }

    func refitColumnHeight(_ id: UUID) {
        mutateBoard { board in
            guard let i = board.items.firstIndex(where: { $0.id == id }), board.items[i].kind == .column else { return }
            board.items[i].h = columnHeight(for: board.items[i])
        }
    }

    /// Saca una pieza de su columna y la deja suelta en el lienzo en `origin` (lo usa el arrastre
    /// para sacarla siguiendo el cursor). No hace nada si la pieza no pertenece a ninguna columna.
    func releaseItem(_ id: UUID, at origin: CGPoint) {
        guard let board = activeBoard,
              let column = board.items.first(where: { ($0.children ?? []).contains(id) }) else { return }
        checkpoint()
        let columnID = column.id
        mutateBoard { board in
            if let c = board.items.firstIndex(where: { $0.id == columnID }) {
                board.items[c].children?.removeAll { $0 == id }
            }
            if let i = board.items.firstIndex(where: { $0.id == id }) {
                board.items[i].origin = origin
                board.items[i].z = board.topZ
            }
        }
        refitColumnHeight(columnID)
        selection = [id]
    }

    private func itemKind(_ id: UUID) -> ItemKind? {
        activeBoard?.items.first { $0.id == id }?.kind
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

    /// Diálogo nativo para elegir videos. Los copia al almacén, los inserta con su proporción y los sube.
    func importVideosWithPanel(at point: CGPoint) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = "Agregar"
        guard panel.runModal() == .OK else { return }
        var offset = CGPoint.zero
        for url in panel.urls {
            guard let name = Store.storeMedia(copyingFrom: url) else { continue }
            let at = point + offset
            Task {
                add(await videoItem(fileName: name, at: at))
                await sync.uploadMedia(name, tracked: true)
            }
            offset.x += 28; offset.y += 28
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
