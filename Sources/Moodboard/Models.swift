import Foundation
import CoreGraphics

/// Tipo de pieza que vive en un tablero.
enum ItemKind: String, Codable {
    case image      // foto suelta
    case video      // video corto con reproductor embebido
    case note       // nota de papel de color (en desuso: sólo para tableros antiguos)
    case frame      // viñeta de storyboard: imagen + pie de texto
    case text       // nota de texto sin fondo
    case board      // pseudo carpeta: abre un sub-tablero propio
    case column     // contenedor en columna: organiza otras piezas apiladas

    /// Piezas cuyo texto se puede tipografiar.
    var hasTypography: Bool { self == .text || self == .note }
}

/// Herramientas que se arrastran desde la paleta de la derecha hasta el lienzo.
enum ToolKind: String, CaseIterable, Identifiable {
    case note       // nota de texto sin fondo
    case column     // contenedor en columna
    case board      // carpeta: sub-tablero

    var id: String { rawValue }

    /// Nombre al pie de la herramienta en la paleta.
    var title: String {
        switch self {
        case .note: "Nota"
        case .column: "Columna"
        case .board: "Tablero"
        }
    }

    var icon: String {
        switch self {
        case .note: "textformat"
        case .column: "rectangle.split.1x2"
        case .board: "folder"
        }
    }

    /// Tipo de pieza que crea al soltarse.
    var itemKind: ItemKind {
        switch self {
        case .note: .text
        case .column: .column
        case .board: .board
        }
    }

    // MARK: - Carga útil de arrastre (texto plano con un prefijo propio)

    // Sin dos puntos a propósito: un «:» haría que NSItemProvider lo registrara además como
    // `public.url` y el arrastre se confundiría con el de imágenes.
    static let dragPrefix = "moodboard-tool/"
    var dragPayload: String { Self.dragPrefix + rawValue }

    init?(payload: String) {
        guard payload.hasPrefix(Self.dragPrefix) else { return nil }
        self.init(rawValue: String(payload.dropFirst(Self.dragPrefix.count)))
    }
}

struct BoardItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: ItemKind
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var z: Int = 0
    var text: String = ""
    var colorHex: String = "FFE9A8"
    /// Nombre del archivo dentro de la carpeta Media (nil en notas).
    var media: String?
    /// Familia tipográfica del sistema (nil = fuente del sistema).
    var fontFamily: String?
    var fontSize: Double?
    /// Color del texto en bloques de texto (nil = color principal del sistema).
    var textColorHex: String?
    /// Recorte de la foto en coordenadas normalizadas (0…1) de la imagen original; nil = entera.
    var crop: CGRect?
    /// Sub-tablero que abre esta carpeta (sólo en piezas `.board`).
    var childBoardID: UUID?
    /// Piezas contenidas, en orden de arriba a abajo (sólo en contenedores `.column`).
    var children: [UUID]?
    /// Última modificación de esta pieza. Permite fusionar los cambios de dos equipos pieza por
    /// pieza (gana la versión más reciente de cada una), en vez de que el tablero más nuevo pise
    /// el entero. nil = pieza de un archivo antiguo (se trata como la más vieja posible).
    var modifiedAt: Date? = Date()

    var origin: CGPoint {
        get { CGPoint(x: x, y: y) }
        set { x = newValue.x; y = newValue.y }
    }
    var size: CGSize {
        get { CGSize(width: w, height: h) }
        set { w = max(60, newValue.width); h = max(40, newValue.height) }
    }
    var frameRect: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.minX; y = newValue.minY; w = newValue.width; h = newValue.height }
    }
}

struct Camera: Codable, Hashable {
    var x: Double = 0
    var y: Double = 0
    var scale: Double = 1
}

struct Board: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var items: [BoardItem] = []
    var camera = Camera()
    /// Última vez que se abrió; ordena los recientes del selector.
    var openedAt: Date?
    /// Última vez que se editó su contenido; la lista de inicio la muestra.
    var modifiedAt: Date?
    /// Tablero (nil, por compatibilidad) o guion de cine.
    var kind: DocumentKind?
    /// Líneas del guion, sólo si `kind == .script`.
    var script: [ScriptLine]?
    /// Notas del gestor, sólo si `kind == .notes`.
    var notes: [Note]?
    /// Nota seleccionada en el gestor.
    var activeNoteID: UUID?
    /// Tablero padre si éste es un sub-tablero de una carpeta; nil = tablero de primer nivel.
    var parentID: UUID?
    /// Nombre de archivo de la imagen usada como portada del enlace compartido (nil = la primera foto).
    var cover: String?
    /// Documentos vinculados a éste (guion↔tablero), por id. Vínculo por documento y simétrico: al
    /// vincular se escribe en ambos lados; para mostrar se usa la unión, por si la fusión entre equipos
    /// dejara el vínculo anotado en uno solo.
    var linkedBoardIDs: [UUID]?
    /// Desglose por escena (sólo guiones): ficha de cada escena, por id de la línea de encabezado.
    var sceneDetails: [String: SceneDetail]?
    /// Lápidas: piezas (y notas) borradas de este tablero, con la fecha del borrado. Evitan que la
    /// fusión con otro equipo resucite algo que ya habías eliminado. Se podan por antigüedad (como la
    /// papelera). Clave = UUID de la pieza en texto.
    var deletedItemIDs: [String: Date]?

    var isScript: Bool { kind == .script }
    var isNotes: Bool { kind == .notes }
    /// Tablero visual (los antiguos sin `kind` lo son).
    var isBoard: Bool { (kind ?? .board) == .board }

    /// Escenas del guion (encabezados «INT./EXT.»).
    var sceneCount: Int { script?.filter { $0.type == .scene }.count ?? 0 }

    /// Fecha que resume «última actividad» para la lista de inicio.
    var lastModified: Date { modifiedAt ?? openedAt ?? createdAt }

    /// Siguiente valor de z para que lo nuevo quede siempre encima.
    var topZ: Int { (items.map(\.z).max() ?? 0) + 1 }

    /// Cuenta que resume el contenido para la lista de inicio.
    var summary: String {
        switch kind ?? .board {
        case .board:  return "\(items.count) elementos"
        case .script: return "\(sceneCount) escenas"
        case .notes:  return "\((notes ?? []).count) notas"
        }
    }
}

/// Los documentos que se pueden crear: tableros visuales, guiones de cine o notas.
enum DocumentKind: String, Codable, CaseIterable {
    case board, script, notes

    var title: String {
        switch self {
        case .board: "Tablero"
        case .script: "Guion"
        case .notes: "Notas"
        }
    }

    var untitled: String {
        switch self {
        case .board: "Tablero sin título"
        case .script: "Guion sin título"
        case .notes: "Notas sin título"
        }
    }

    var icon: String {
        switch self {
        case .board: "square.grid.2x2"
        case .script: "doc.text"
        case .notes: "note.text"
        }
    }
}

/// Una nota del gestor: título y cuerpo de texto enriquecido guardado como RTF.
struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = "Nota sin título"
    var createdAt = Date()
    var modifiedAt = Date()
    /// Cuerpo en formato RTF (NSAttributedString archivado); nil = nota vacía.
    var rtf: Data?
}

/// Elementos del formato estándar de guion.
enum ScriptElement: String, Codable, CaseIterable {
    case scene, action, character, parenthetical, dialogue, transition

    var title: String {
        switch self {
        case .scene: "Escena"
        case .action: "Acción"
        case .character: "Personaje"
        case .parenthetical: "Acotación"
        case .dialogue: "Diálogo"
        case .transition: "Transición"
        }
    }

    var placeholder: String {
        switch self {
        case .scene: "INT. LUGAR – DÍA"
        case .action: "Lo que se ve y se oye…"
        case .character: "PERSONAJE"
        case .parenthetical: "en voz baja"
        case .dialogue: "Lo que dice…"
        case .transition: "CORTE A:"
        }
    }

    /// Escena, personaje y transición se escriben siempre en mayúsculas.
    var isUppercase: Bool { self == .scene || self == .character || self == .transition }

    /// Qué elemento sigue al pulsar ↩.
    var next: ScriptElement {
        switch self {
        case .scene, .action, .transition: .action
        case .character, .parenthetical: .dialogue
        case .dialogue: .character
        }
    }
}

struct ScriptLine: Identifiable, Codable, Hashable {
    var id = UUID()
    var type: ScriptElement
    var text: String = ""
}

/// Departamentos del desglose de producción. Cada uno se muestra como un grupo de tags/badges.
enum Department: String, Codable, CaseIterable, Identifiable {
    case cast, props, setDressing, wardrobe, lighting, sound

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cast:       "Reparto"
        case .props:      "Utilería"
        case .setDressing:"Escenografía"
        case .wardrobe:   "Vestuario"
        case .lighting:   "Iluminación"
        case .sound:      "Sonido"
        }
    }

    var icon: String {
        switch self {
        case .cast:        "person.2"
        case .props:       "shippingbox"
        case .setDressing: "sofa"
        case .wardrobe:    "tshirt"
        case .lighting:    "lightbulb"
        case .sound:       "waveform"
        }
    }
}

/// Ficha de desglose de una escena: sinopsis más los ítems que el usuario añadió, quitó o reasignó a
/// mano. Lo detectado automáticamente no se guarda (se recalcula del texto); sólo se persisten las
/// decisiones del usuario, que mandan sobre la detección.
struct SceneDetail: Codable, Hashable {
    /// Ficha descriptiva de la escena.
    var synopsis: String = ""
    /// Ítems añadidos a mano, por departamento (clave = `Department.rawValue`).
    var added: [String: [String]] = [:]
    /// Objetos (en minúscula) que el usuario quitó: la detección no los vuelve a mostrar.
    var removed: [String] = []
    /// Objeto (en minúscula) → departamento al que el usuario lo asignó (manda sobre el diccionario).
    var assigned: [String: String] = [:]
}

/// Personajes y lugares que aparecen en un guion, en orden de primera aparición.
struct ScriptIndex {
    struct Entry: Identifiable {
        var id: String { name }
        let name: String
        var count: Int
        let firstLine: UUID
    }

    var characters: [Entry] = []
    var places: [Entry] = []

    init(_ lines: [ScriptLine]) {
        for line in lines {
            switch line.type {
            case .character:
                let name = Self.characterName(line.text)
                if !name.isEmpty { Self.add(name, line.id, to: &characters) }
            case .scene:
                let place = Self.placeName(line.text)
                if !place.isEmpty { Self.add(place, line.id, to: &places) }
            default: break
            }
        }
    }

    /// «ANA (V.O.)» → «ANA».
    static func characterName(_ text: String) -> String {
        let base = text.components(separatedBy: "(").first ?? text
        return base.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// «INT. CASA DE ANA – NOCHE» → «CASA DE ANA».
    static func placeName(_ text: String) -> String {
        var t = text.uppercased()
        if let r = t.range(of: #"^\s*(INT\.?/EXT|INT|EXT|I/E)\.?\s*"#, options: .regularExpression) {
            t.removeSubrange(r)
        }
        for separator in [" – ", " — ", " - "] {
            if let r = t.range(of: separator) { t = String(t[..<r.lowerBound]) }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func add(_ name: String, _ id: UUID, to list: inout [Entry]) {
        if let i = list.firstIndex(where: { $0.name == name }) {
            list[i].count += 1
        } else {
            list.append(Entry(name: name, count: 1, firstLine: id))
        }
    }
}

/// Algo eliminado que todavía se puede recuperar.
struct TrashEntry: Identifiable, Codable, Hashable {
    enum Content: Codable, Hashable {
        case item(BoardItem, boardID: UUID, boardName: String)
        case board(Board)
    }

    var id = UUID()
    var deletedAt = Date()
    var content: Content
}

/// Una captura esperando en la bandeja de entrada del servidor (p. ej. recortada desde Instagram con
/// la extensión de Chrome). Vive sólo en el servidor, no en el documento sincronizado: la app la baja
/// para mostrarla y, al cargarla en un tablero, se convierte en una `BoardItem` normal y se consume.
struct InboxItem: Identifiable, Codable, Hashable {
    let id: String
    let media: String
    var sourceUrl: String?
    var kind: String = "image"
    var w: Int?
    var h: Int?
    var createdAt: String?

    var isVideo: Bool { kind == "video" }
}

struct Library: Codable {
    var boards: [Board]
    var activeBoardID: UUID?
    var trash: [TrashEntry] = []
    /// Tableros abiertos como pestañas, en orden.
    var openBoardIDs: [UUID] = []
    /// Lápidas de tableros borrados, con su fecha: evitan que la fusión resucite un tablero que ya
    /// eliminaste en otro equipo. Clave = UUID del tablero en texto.
    var deletedBoardIDs: [String: Date]?

    static var starter: Library {
        let board = Board(name: "Mi primer tablero")
        return Library(boards: [board], activeBoardID: board.id, openBoardIDs: [board.id])
    }
}

extension Library {
    /// Decodificación tolerante: los library.json anteriores no tienen papelera.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        boards = try c.decode([Board].self, forKey: .boards)
        activeBoardID = try c.decodeIfPresent(UUID.self, forKey: .activeBoardID)
        trash = try c.decodeIfPresent([TrashEntry].self, forKey: .trash) ?? []
        openBoardIDs = try c.decodeIfPresent([UUID].self, forKey: .openBoardIDs) ?? []
        deletedBoardIDs = try c.decodeIfPresent([String: Date].self, forKey: .deletedBoardIDs)
    }

    /// Une esta biblioteca con otra **sin perder trabajo**, con la granularidad de la pieza (no del
    /// tablero entero). Reglas:
    ///  - Un tablero presente en ambas se fusiona pieza por pieza (ver `mergeBoards`); el que sólo
    ///    está en una se conserva, salvo que el otro lado tenga una lápida de borrado posterior a su
    ///    última edición.
    ///  - Las lápidas (piezas y tableros borrados) impiden resucitar lo que ya se eliminó.
    ///  - La papelera se une por id.
    /// Así ni un servidor vacío puede vaciar el disco, ni dos equipos que editan el mismo tablero se
    /// pisan el trabajo: las piezas que cada uno añadió conviven. Mantiene el estado de interfaz local.
    func merged(with other: Library) -> Library {
        let boardTombs = Self.mergeDateMaps(deletedBoardIDs, other.deletedBoardIDs)

        var winner: [UUID: Board] = [:]
        for board in boards { winner[board.id] = board }
        for board in other.boards {
            if let mine = winner[board.id] {
                winner[board.id] = Self.mergeBoards(mine, board)
            } else {
                winner[board.id] = board
            }
        }
        // Aplica las lápidas: quita un tablero sólo si se borró *después* de su última modificación
        // (si se volvió a editar más tarde, es que renació y se conserva).
        for (idStr, deletedAt) in boardTombs {
            if let id = UUID(uuidString: idStr), let b = winner[id], b.lastModified <= deletedAt {
                winner.removeValue(forKey: id)
            }
        }
        // Orden estable: primero los tableros locales en su orden; luego los que sólo trae el otro.
        var order: [UUID] = []
        var seen: Set<UUID> = []
        for board in boards + other.boards where seen.insert(board.id).inserted {
            if winner[board.id] != nil { order.append(board.id) }
        }
        var result = self
        result.boards = order.compactMap { winner[$0] }
        // Red de seguridad: colapsa piezas con id repetido (corrupción heredada). Los tableros que
        // sólo están en un lado no pasan por `mergeBoards`, así que podrían llegar con duplicados.
        _ = result.dedupeItems()
        // Conserva sólo las lápidas de tableros que sigan muertos (poda las de los revividos).
        let liveBoardTombs = boardTombs.filter { idStr, _ in
            guard let id = UUID(uuidString: idStr) else { return false }
            return winner[id] == nil
        }
        result.deletedBoardIDs = liveBoardTombs.isEmpty ? nil : liveBoardTombs
        // Papelera: unión por id, conservando primero la local.
        var trashSeen = Set(trash.map(\.id))
        for entry in other.trash where trashSeen.insert(entry.id).inserted {
            result.trash.append(entry)
        }
        return result
    }

    /// Fusiona dos versiones del mismo tablero. Los metadatos (nombre, cámara, portada, guion) vienen
    /// del que se editó más recientemente; las piezas y las notas se unen por id, ganando la versión
    /// más reciente de cada una y respetando las lápidas de borrado de ambos lados.
    static func mergeBoards(_ mine: Board, _ theirs: Board) -> Board {
        var result = mine.lastModified >= theirs.lastModified ? mine : theirs

        // --- Piezas: unión por id ---
        var byID: [UUID: BoardItem] = [:]
        var order: [UUID] = []
        var seenOrder: Set<UUID> = []
        for item in mine.items + theirs.items where seenOrder.insert(item.id).inserted { order.append(item.id) }
        for item in mine.items { byID[item.id] = item }
        for item in theirs.items {
            if let cur = byID[item.id] {
                if date(item.modifiedAt) > date(cur.modifiedAt) { byID[item.id] = item }
            } else {
                byID[item.id] = item
            }
        }
        let itemTombs = mergeDateMaps(mine.deletedItemIDs, theirs.deletedItemIDs)
        for (idStr, deletedAt) in itemTombs {
            if let id = UUID(uuidString: idStr), let item = byID[id], date(item.modifiedAt) <= deletedAt {
                byID.removeValue(forKey: id)
            }
        }
        result.items = order.compactMap { byID[$0] }
        let liveTombs = itemTombs.filter { idStr, _ in
            guard let id = UUID(uuidString: idStr) else { return false }
            return byID[id] == nil
        }
        result.deletedItemIDs = liveTombs.isEmpty ? nil : liveTombs

        // --- Notas (gestor de notas): unión por id, gana la más reciente ---
        if mine.notes != nil || theirs.notes != nil {
            var notesByID: [UUID: Note] = [:]
            var notesOrder: [UUID] = []
            for note in (mine.notes ?? []) + (theirs.notes ?? []) where notesByID[note.id] == nil {
                notesOrder.append(note.id)
            }
            for note in mine.notes ?? [] { notesByID[note.id] = note }
            for note in theirs.notes ?? [] {
                if let cur = notesByID[note.id] {
                    if note.modifiedAt > cur.modifiedAt { notesByID[note.id] = note }
                } else {
                    notesByID[note.id] = note
                }
            }
            result.notes = notesOrder.compactMap { notesByID[$0] }
        }
        return result
    }

    /// Fecha de una pieza para comparar; nil (archivo antiguo) se trata como la más vieja posible.
    private static func date(_ value: Date?) -> Date { value ?? .distantPast }

    /// Repara datos heredados: colapsa piezas **y notas** con el mismo id dentro de cada tablero,
    /// conservando por id la versión más reciente (y, en empate, la primera). Una versión vieja del
    /// sync concatenaba piezas (y notas) sin deduplicar, duplicándolas en cada ronda (×2, ×4, … hasta
    /// miles): eso inflaba el documento (lentitud), dejaba ids repetidos que hacían abortar el
    /// pegar/clonar, y disparaba el conteo de notas a decenas de miles. Devuelve `true` si eliminó algo.
    @discardableResult
    mutating func dedupeItems() -> Bool {
        var changed = false
        for i in boards.indices {
            let items = boards[i].items
            var byID: [UUID: BoardItem] = [:]
            var order: [UUID] = []
            for item in items {
                if let cur = byID[item.id] {
                    if Self.date(item.modifiedAt) > Self.date(cur.modifiedAt) { byID[item.id] = item }
                } else {
                    byID[item.id] = item
                    order.append(item.id)
                }
            }
            if order.count != items.count {
                boards[i].items = order.compactMap { byID[$0] }
                changed = true
            }
            // Notas (documentos de Notas): mismo colapso por id, conservando la más reciente.
            if let notes = boards[i].notes {
                var notesByID: [UUID: Note] = [:]
                var notesOrder: [UUID] = []
                for note in notes {
                    if let cur = notesByID[note.id] {
                        if note.modifiedAt > cur.modifiedAt { notesByID[note.id] = note }
                    } else {
                        notesByID[note.id] = note
                        notesOrder.append(note.id)
                    }
                }
                if notesOrder.count != notes.count {
                    boards[i].notes = notesOrder.compactMap { notesByID[$0] }
                    changed = true
                }
            }
        }
        return changed
    }

    /// Une dos mapas de lápidas conservando, por clave, la fecha más reciente.
    static func mergeDateMaps(_ a: [String: Date]?, _ b: [String: Date]?) -> [String: Date] {
        var out = a ?? [:]
        for (key, value) in b ?? [:] {
            if let cur = out[key] { if value > cur { out[key] = value } } else { out[key] = value }
        }
        return out
    }
}

/// Paleta de las notas y de los bordes de viñeta.
enum Palette {
    static let colors: [String] = [
        "FFE9A8", // amarillo papel
        "FFC6A8", // durazno
        "F7A8C0", // rosa
        "C9B8FF", // lavanda
        "A8D8FF", // azul
        "A8F0D0", // menta
        "E4E4EC"  // gris claro
    ]

    /// Colores para texto sin fondo.
    static let textColors: [String] = [
        "1C1C1E", // casi negro
        "FFFFFF", // blanco
        "8E8E93", // gris
        "FF3B30", // rojo
        "FF9500", // naranja
        "FFCC00", // amarillo
        "34C759", // verde
        "007AFF", // azul
        "AF52DE"  // violeta
    ]
}

/// Retícula invisible a la que se imantan las piezas al moverlas.
enum Grid {
    static let step: Double = 10
    /// Ancho con el que entra cada foto nueva (24 celdas).
    static let imageWidth: Double = 240

    /// Separación mínima entre piezas vecinas, tipo masonry.
    static let gutter: Double = 10

    static func snap(_ value: Double) -> Double { (value / step).rounded() * step }
    static func snapUp(_ value: Double) -> Double { (value / step).rounded(.up) * step }
}
