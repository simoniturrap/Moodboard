import SwiftUI
import AppKit

/// Márgenes internos de los bloques de texto; los usan la vista y el cálculo de alto.
enum TextMetrics {
    static let horizontalInset: Double = 5
    static let verticalInset: Double = 4
}

/// Estilos por cuerpo: los usa la barra de opciones y el clic derecho sobre una fuente.
enum TextStyle: CaseIterable {
    case title, subtitle, body

    var title: String {
        switch self {
        case .title: "Título"
        case .subtitle: "Subtítulo"
        case .body: "Texto"
        }
    }

    var size: Double {
        switch self {
        case .title: 32
        case .subtitle: 18
        case .body: 12
        }
    }
}

extension ItemKind {
    /// Fotos y viñetas conservan la proporción al redimensionar.
    var keepsRatio: Bool { self == .image || self == .frame }
}

/// Cursor según la herramienta activa (macOS 15+).
struct ToolCursor: ViewModifier {
    let tool: Store.Tool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            switch tool {
            case .select: content
            case .text: content.pointerStyle(.horizontalText)
            case .note: content.pointerStyle(.rectSelection)
            }
        } else {
            content
        }
    }
}

extension BoardItem {
    var resolvedFontSize: Double { fontSize ?? (kind == .note ? 14 : TextStyle.body.size) }

    var textColor: AnyShapeStyle {
        textColorHex.map { AnyShapeStyle(Color(hex: $0)) } ?? AnyShapeStyle(.primary)
    }

    /// Fuente real: la familia elegida o, si no hay, la del sistema.
    var nsFont: NSFont {
        let size = resolvedFontSize
        if let family = fontFamily,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return .systemFont(ofSize: size)
    }

    var swiftUIFont: Font { Font(nsFont as CTFont) }
}

/// Fuentes favoritas, guardadas en las preferencias del usuario.
@MainActor
final class FontFavorites: ObservableObject {
    static let shared = FontFavorites()
    private let key = "favoriteFonts"

    @Published private(set) var families: [String]

    private init() {
        families = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func contains(_ family: String) -> Bool { families.contains(family) }

    func toggle(_ family: String) {
        if let i = families.firstIndex(of: family) {
            families.remove(at: i)
        } else {
            families.append(family)
            families.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        UserDefaults.standard.set(families, forKey: key)
    }
}

/// Selector de fuentes del sistema: favoritas arriba, buscador, estrella para marcar
/// y clic derecho con estilos H1 / H2 / H3 / párrafo.
struct FontPicker: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var favorites = FontFavorites.shared
    let current: String?
    @State private var query = ""

    private static let allFamilies = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    private func matches(_ family: String) -> Bool {
        query.isEmpty || family.localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar fuente", text: $query).textFieldStyle(.plain)
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty {
                        row(nil)
                    }
                    let favs = favorites.families.filter(matches)
                    if !favs.isEmpty {
                        header("Favoritas")
                        ForEach(favs, id: \.self) { row($0) }
                    }
                    header("Todas")
                    ForEach(Self.allFamilies.filter(matches), id: \.self) { row($0) }
                }
                .padding(.vertical, 4)
            }
            Divider()
            Text("Clic derecho sobre una fuente: Título, Subtítulo o Texto")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(width: 280, height: 380)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    /// Una fila por familia; nil es la fuente del sistema.
    private func row(_ family: String?) -> some View {
        let name = family ?? "Sistema"
        let preview = family.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 14) }
            ?? .systemFont(ofSize: 14)
        return HStack {
            Text(name)
                .font(Font(preview as CTFont))
                .lineLimit(1)
            Spacer()
            if current == family {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
            if let family {
                Button { favorites.toggle(family) } label: {
                    Image(systemName: favorites.contains(family) ? "star.fill" : "star")
                        .foregroundStyle(favorites.contains(family) ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(favorites.contains(family) ? "Quitar de favoritas" : "Marcar como favorita")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { store.applyFont(family: family) }
        .contextMenu {
            ForEach(TextStyle.allCases, id: \.self) { style in
                Button("\(style.title) · \(Int(style.size)) pt") {
                    store.applyFont(family: family, size: style.size)
                }
            }
        }
    }
}

/// Paleta de herramientas flotante a la derecha.
struct ToolPalette: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 4) {
            button(.text, icon: "textformat", help: "Texto (T)")
            button(.note, icon: "note.text", help: "Nota (N)")
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }

    private func button(_ tool: Store.Tool, icon: String, help: String) -> some View {
        let active = store.tool == tool
        return Button { store.tool = active ? .select : tool } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 8).fill(active ? Color.accentColor : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
