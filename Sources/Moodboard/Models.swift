import Foundation
import CoreGraphics

/// Tipo de pieza que vive en un tablero.
enum ItemKind: String, Codable {
    case image      // foto suelta
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

struct Library: Codable {
    var boards: [Board]
    var activeBoardID: UUID?
    var trash: [TrashEntry] = []
    /// Tableros abiertos como pestañas, en orden.
    var openBoardIDs: [UUID] = []

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
    }

    /// Une esta biblioteca con otra **sin perder tableros**: los que existen en ambas se quedan con
    /// la versión modificada más recientemente; los que sólo están en una se conservan. La papelera
    /// se une por id. Es la pieza que hace la sincronización no-destructiva: ni un servidor vacío
    /// puede vaciar el disco, ni el disco puede vaciar el servidor al adoptar su versión.
    /// Mantiene el estado de interfaz local (pestañas y tablero activo).
    func merged(with other: Library) -> Library {
        var winner: [UUID: Board] = [:]
        for board in boards { winner[board.id] = board }
        for board in other.boards {
            if let mine = winner[board.id] {
                if board.lastModified > mine.lastModified { winner[board.id] = board }
            } else {
                winner[board.id] = board
            }
        }
        // Orden estable: primero los tableros locales en su orden; luego los que sólo trae el otro.
        var order: [UUID] = []
        var seen: Set<UUID> = []
        for board in boards + other.boards where seen.insert(board.id).inserted {
            order.append(board.id)
        }
        var result = self
        result.boards = order.compactMap { winner[$0] }
        // Papelera: unión por id, conservando primero la local.
        var trashSeen = Set(trash.map(\.id))
        for entry in other.trash where trashSeen.insert(entry.id).inserted {
            result.trash.append(entry)
        }
        return result
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
