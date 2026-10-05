import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Formato de página

/// Medidas del formato estándar de guion (carta, Courier 12) en puntos.
enum ScriptLayout {
    static let page = CGSize(width: 612, height: 792)
    static let marginLeft: Double = 108      // 1,5"
    static let marginRight: Double = 72      // 1"
    static let marginTop: Double = 72
    static let marginBottom: Double = 72
    static let textWidth = page.width - marginLeft - marginRight   // 6"
    static let bodyHeight = page.height - marginTop - marginBottom

    static let nsFont = NSFont(name: "Courier", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
    static let font = Font(nsFont as CTFont)

    /// Sangría desde el margen izquierdo del texto.
    static func indent(_ type: ScriptElement) -> Double {
        switch type {
        case .scene, .action, .transition: 0
        case .character: 72       // misma columna que el diálogo; el nombre va centrado en ella
        case .parenthetical: 115  // 3,1"
        case .dialogue: 72        // 2,5"
        }
    }

    static func width(_ type: ScriptElement) -> Double {
        switch type {
        case .scene, .action, .transition: textWidth
        case .character: 252
        case .parenthetical: 144
        case .dialogue: 252
        }
    }

    /// Personaje centrado sobre su diálogo; transición a la derecha; el resto a la izquierda.
    static func textAlignment(_ type: ScriptElement) -> TextAlignment {
        switch type {
        case .character: .center
        case .transition: .trailing
        default: .leading
        }
    }

    static func alignment(_ type: ScriptElement) -> Alignment {
        switch type {
        case .character: .center
        case .transition: .trailing
        default: .leading
        }
    }

    /// Línea en blanco antes de cada elemento, salvo dentro de una intervención; dos antes de cada escena.
    static func spaceAbove(_ type: ScriptElement, after previous: ScriptElement?) -> Double {
        guard let previous else { return 0 }
        switch type {
        case .dialogue, .parenthetical:
            return [.character, .parenthetical, .dialogue].contains(previous) ? 0 : 12
        case .scene: return 24
        default: return 12
        }
    }

    /// Texto tal como se imprime: acotaciones entre paréntesis.
    static func display(_ line: ScriptLine) -> String {
        guard line.type == .parenthetical, !line.text.isEmpty else { return line.text }
        var t = line.text
        if !t.hasPrefix("(") { t = "(" + t }
        if !t.hasSuffix(")") { t += ")" }
        return t
    }

    static func height(_ line: ScriptLine, after previous: ScriptElement?) -> Double {
        let text = display(line).isEmpty ? " " : display(line)
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width(line.type), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: nsFont])
        return ceil(rect.height) + spaceAbove(line.type, after: previous)
    }

    /// Reparte las líneas en páginas. Cada entrada lleva el tipo anterior *en esa página*
    /// (arriba de página no se deja espacio).
    static func paginate(_ lines: [ScriptLine]) -> [[(line: ScriptLine, previous: ScriptElement?)]] {
        var pages: [[(line: ScriptLine, previous: ScriptElement?)]] = [[]]
        var used = 0.0
        var previous: ScriptElement?
        for line in lines {
            let h = height(line, after: previous)
            if used + h > bodyHeight, !(pages.last?.isEmpty ?? true) {
                pages.append([])
                used = 0
                previous = nil
            }
            pages[pages.count - 1].append((line, previous))
            used += height(line, after: previous)
            previous = line.type
        }
        return pages
    }
}

// MARK: - Editor

/// Editor de guion: una hoja con formato estándar donde cada línea es un elemento.
/// ↩ crea el siguiente elemento, ⇥ / ⇧⇥ cambian el tipo, ⌫ al principio une con la anterior,
/// ↑ / ↓ saltan entre líneas. ⌥↩ hace un salto de línea dentro del mismo elemento.
struct ScriptEditor: View {
    @EnvironmentObject var store: Store
    @FocusState private var focused: UUID?
    @State private var lastFocused: UUID?
    @State private var windowWidth: Double = 0

    private var lines: [ScriptLine] { store.scriptLines }
    private var index: ScriptIndex { ScriptIndex(lines) }
    private var zoom: Double { store.scriptZoom }
    @State private var paperHeight: Double = ScriptLayout.page.height
    private var currentType: ScriptElement? {
        lines.first { $0.id == (focused ?? lastFocused) }?.type
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                // scaleEffect no cambia el tamaño que ve el ScrollView: se reserva a mano el tamaño escalado.
                paper
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { paperHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in paperHeight = h }
                    })
                    .scaleEffect(zoom, anchor: .top)
                    .frame(width: ScriptLayout.page.width * zoom, height: paperHeight * zoom, alignment: .top)
                    .padding(.vertical, 70)
                    .frame(minWidth: windowWidth)
            }
            .onChange(of: focused) { _, id in
                if let id {
                    lastFocused = id
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .background(KeyCatcher(onKey: handleKey, ignoresTextEditing: false))
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { windowWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in windowWidth = w }
        })
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 12) {
                BoardSwitcher()
                ScriptIndexPanel(index: index, onJump: { focus($0, caret: .max) })
            }
            .padding(20)
        }
        .overlay(alignment: .bottomLeading) { TrashButton().padding(20) }
        .overlay(alignment: .trailing) {
            ElementPalette(current: currentType, onPick: setType).padding(20)
        }
        .toolbar {
            // A la derecha van semáforos, páginas, zoom y exportar (~580 px): el resto para pestañas.
            TabsToolbarItem(width: max(160, windowWidth - 580))
            ToolbarItem(placement: .primaryAction) { pagesMenu }
            ToolbarItem(placement: .primaryAction) { zoomControls }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { if let board = store.activeBoard { ScriptPDF.export(board) } } label: {
                    Label("Exportar PDF", systemImage: "arrow.down.doc")
                }
                .help("Exportar el guion a PDF con formato de página")
            }
        }
        .onAppear { focus(lines.last?.id, caret: .max) }
        .onChange(of: store.activeBoard?.id) { _, _ in focus(lines.last?.id, caret: .max) }
    }

    /// La hoja se dibuja como páginas reales: los saltos se intercalan entre líneas
    /// (lista plana, así ninguna línea pierde el foco al pasar de una página a otra).
    private enum PaperRow: Identifiable {
        case line(ScriptLine, previous: ScriptElement?)
        case pageBreak(nextPage: Int, fill: Double)

        var id: String {
            switch self {
            case .line(let line, _): line.id.uuidString
            case .pageBreak(let n, _): "salto-\(n)"
            }
        }
    }

    private func paperRows() -> (rows: [PaperRow], lastFill: Double) {
        var rows: [PaperRow] = []
        let pages = ScriptLayout.paginate(lines)
        var lastFill = ScriptLayout.bodyHeight
        for (p, page) in pages.enumerated() {
            let used = page.reduce(0) { $0 + ScriptLayout.height($1.line, after: $1.previous) }
            let fill = max(0, ScriptLayout.bodyHeight - used)
            for entry in page { rows.append(.line(entry.line, previous: entry.previous)) }
            if p < pages.count - 1 {
                rows.append(.pageBreak(nextPage: p + 2, fill: fill))
            } else {
                lastFill = fill
            }
        }
        return (rows, lastFill)
    }

    private var paper: some View {
        let (rows, lastFill) = paperRows()
        return VStack(alignment: .leading, spacing: 0) {
            Color.white.frame(height: ScriptLayout.marginTop)
            ForEach(rows) { row in
                switch row {
                case .line(let line, let previous):
                    ScriptLineField(line: line,
                                    previous: previous,
                                    isFocused: focused == line.id,
                                    focus: $focused,
                                    onChange: { store.updateLine(line.id, text: $0) })
                        .padding(.leading, ScriptLayout.marginLeft)
                        .frame(width: ScriptLayout.page.width, alignment: .leading)
                        .background(Color.white)
                        .id(line.id)
                case .pageBreak(let next, let fill):
                    PageBreak(fill: fill, nextPage: next)
                }
            }
            // Resto de la última página; clic aquí sigue escribiendo al final.
            Color.white
                .frame(height: lastFill + ScriptLayout.marginBottom)
                .contentShape(Rectangle())
                .onTapGesture { focus(lines.last?.id, caret: .max) }
        }
        .frame(width: ScriptLayout.page.width)
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .environment(\.colorScheme, .light)   // la hoja siempre es papel blanco con tinta negra
    }

    private func setZoom(_ value: Double) {
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { store.setScriptZoom(value) }
    }

    /// Zoom de la hoja: − / + de 10 en 10 % y, en el porcentaje, un submenú con tamaños fijos.
    private static let zoomPresets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    private static let zoomStep: Double = 0.1

    /// Suma o resta un 10 % y redondea a la decena, así 75 % → 80 % y no 85 %.
    private func stepZoom(_ direction: Double) {
        let next = ((zoom + direction * Self.zoomStep) * 10).rounded() / 10
        setZoom(next)
    }

    /// Tres botones juntos: Zoom − | porcentaje (clic → menú de tamaños) | Zoom +.
    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button { stepZoom(-1) } label: {
                Image(systemName: "minus.magnifyingglass").frame(width: 26, height: 24)
            }
            .help("Alejar 10 %")
            .disabled(zoom <= 0.5 + 0.001)

            Menu {
                ForEach(Self.zoomPresets, id: \.self) { value in
                    Button {
                        setZoom(value)
                    } label: {
                        if abs(value - zoom) < 0.01 {
                            Label("\(Int(value * 100)) %", systemImage: "checkmark")
                        } else {
                            Text("\(Int(value * 100)) %")
                        }
                    }
                }
            } label: {
                Text("\(Int((zoom * 100).rounded())) %")
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 48, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Tamaños predefinidos")

            Button { stepZoom(1) } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 26, height: 24)
            }
            .help("Acercar 10 %")
            .disabled(zoom >= 3 - 0.001)
        }
        .buttonStyle(.borderless)
    }

    /// Páginas del guion: en qué página está el cursor y salto a cualquiera.
    private var pagesMenu: some View {
        let pages = ScriptLayout.paginate(lines)
        let currentID = focused ?? lastFocused
        let current = pages.firstIndex { page in page.contains { $0.line.id == currentID } } ?? 0
        return Menu {
            ForEach(Array(pages.enumerated()), id: \.offset) { i, page in
                Button("Página \(i + 1)") { focus(page.first?.line.id, caret: 0) }
            }
        } label: {
            Label("Página \(current + 1) de \(pages.count)", systemImage: "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .monospacedDigit()
        }
        .help("Páginas del guion")
    }

    private func setType(_ type: ScriptElement) {
        guard let id = focused ?? lastFocused else { return }
        store.setLineType(id, type)
        focus(id, caret: .max)
    }

    // MARK: Teclado

    private func handleKey(_ event: NSEvent) -> Bool {
        // El catcher también recibe al soltar la tecla: sólo cuenta al pulsarla
        // (antes cada ↩ se procesaba dos veces y creaba dos líneas).
        guard event.type == .keyDown else { return false }
        guard store.lightboxItem == nil, let id = focused,
              let i = lines.firstIndex(where: { $0.id == id }),
              let tv = event.window?.firstResponder as? NSTextView else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let text = tv.string as NSString
        let selection = tv.selectedRange()
        let caret = text.substring(to: min(selection.location, text.length)).count
        let line = lines[i]

        switch event.keyCode {
        case 36, 76: // ↩
            guard mods.isEmpty else { return false }        // ⌥↩ = salto dentro del elemento
            if line.text.isEmpty, line.type == .character { // ↩ en personaje vacío: se termina el diálogo
                store.setLineType(id, .action)
                return true
            }
            // Un nombre de personaje ya conocido escrito como acción: se reconoce como personaje
            // y la línea siguiente pasa a ser su diálogo.
            if line.type == .action, caret == line.text.count,
               index.characters.contains(where: { $0.name == ScriptIndex.characterName(line.text) }) {
                store.setLineType(id, .character)
            }
            if let new = store.splitLine(id, at: caret) { focus(new, caret: 0) }
            return true
        case 48: // ⇥ / ⇧⇥
            guard mods.isEmpty || mods == [.shift] else { return false }
            let all = ScriptElement.allCases
            let index = all.firstIndex(of: line.type) ?? 0
            let step = mods.contains(.shift) ? -1 : 1
            store.setLineType(id, all[(index + step + all.count) % all.count])
            return true
        case 51: // ⌫ al principio: une con la línea anterior
            guard mods.isEmpty, selection.location == 0, selection.length == 0, i > 0 else { return false }
            if let merged = store.mergeWithPrevious(id) { focus(merged.id, caret: merged.caret) }
            return true
        case 126: // ↑ desde la primera línea visual
            guard mods.isEmpty, i > 0, Self.caretOnFirstLine(tv) else { return false }
            focus(lines[i - 1].id, caret: .max)
            return true
        case 125: // ↓ desde la última línea visual
            guard mods.isEmpty, i < lines.count - 1, Self.caretOnLastLine(tv) else { return false }
            focus(lines[i + 1].id, caret: 0)
            return true
        default:
            return false
        }
    }

    /// Enfoca una línea y coloca el cursor (en caracteres; `.max` = al final).
    private func focus(_ id: UUID?, caret: Int) {
        guard let id else { return }
        DispatchQueue.main.async {
            focused = id
            DispatchQueue.main.async {
                guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                let chars = tv.string
                let prefix = String(chars.prefix(min(caret, chars.count)))
                tv.setSelectedRange(NSRange(location: (prefix as NSString).length, length: 0))
            }
        }
    }

    private static func caretOnFirstLine(_ tv: NSTextView) -> Bool {
        guard let lm = tv.layoutManager, lm.numberOfGlyphs > 0 else { return true }
        let glyph = lm.glyphIndexForCharacter(at: min(tv.selectedRange().location, lm.numberOfGlyphs - 1))
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            <= lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + 0.5
    }

    private static func caretOnLastLine(_ tv: NSTextView) -> Bool {
        guard let lm = tv.layoutManager, lm.numberOfGlyphs > 0 else { return true }
        let last = lm.numberOfGlyphs - 1
        let glyph = lm.glyphIndexForCharacter(at: min(tv.selectedRange().location, last))
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            >= lm.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).minY - 0.5
    }
}

/// Una línea editable del guion, con la sangría de su tipo y su nombre en el margen al enfocarla.
private struct ScriptLineField: View {
    let line: ScriptLine
    let previous: ScriptElement?
    let isFocused: Bool
    var focus: FocusState<UUID?>.Binding
    let onChange: (String) -> Void

    var body: some View {
        let space = ScriptLayout.spaceAbove(line.type, after: previous)
        TextField(line.type == .parenthetical ? "(\(line.type.placeholder))" : line.type.placeholder,
                  text: Binding(get: { line.text }, set: onChange),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .font(ScriptLayout.font)
            .foregroundStyle(.black)
            .multilineTextAlignment(ScriptLayout.textAlignment(line.type))
            .focused(focus, equals: line.id)
            .frame(width: ScriptLayout.width(line.type), alignment: ScriptLayout.alignment(line.type))
            .padding(.leading, ScriptLayout.indent(line.type))
            .padding(.top, space)
            .overlay(alignment: .topLeading) {
                if isFocused {
                    Text(line.type.title.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 84, alignment: .trailing)
                        .offset(x: -96, y: space + 2)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Final de una página y comienzo de la siguiente, con el número de página como en el PDF.
private struct PageBreak: View {
    let fill: Double
    let nextPage: Int

    var body: some View {
        VStack(spacing: 0) {
            Color.white.frame(height: fill + ScriptLayout.marginBottom)
            Color.clear.frame(height: 28)
            Color.white
                .frame(height: ScriptLayout.marginTop)
                .overlay(alignment: .topTrailing) {
                    Text("\(nextPage).")
                        .font(ScriptLayout.font)
                        .foregroundStyle(.black)
                        .padding(.top, 36)
                        .padding(.trailing, ScriptLayout.marginRight)
                }
        }
        .frame(width: ScriptLayout.page.width)
        .allowsHitTesting(false)
    }
}

/// Aside izquierdo: personajes y lugares que van apareciendo; clic salta a su primera aparición.
private struct ScriptIndexPanel: View {
    let index: ScriptIndex
    let onJump: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Personajes", icon: "person.2", entries: index.characters,
                    empty: "Aparecerán al escribir un Personaje")
            Divider()
            section("Lugares", icon: "mappin.and.ellipse", entries: index.places,
                    empty: "Aparecerán al escribir una Escena")
        }
        .padding(10)
        .frame(width: 180)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: index.characters.map(\.name))
        .animation(.spring(duration: 0.3, bounce: 0.15), value: index.places.map(\.name))
    }

    private func section(_ title: String, icon: String, entries: [ScriptIndex.Entry], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            if entries.isEmpty {
                Text(empty)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(entries) { entry in
                            Button { onJump(entry.firstLine) } label: {
                                HStack {
                                    Text(entry.name)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer(minLength: 4)
                                    Text("\(entry.count)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 6)
                                .frame(height: 22)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Ir a la primera aparición")
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Paleta derecha del guion: el tipo de la línea actual y los demás para cambiarlo.
private struct ElementPalette: View {
    let current: ScriptElement?
    let onPick: (ScriptElement) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Elemento")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ForEach(ScriptElement.allCases, id: \.self) { type in
                let active = type == current
                Button { onPick(type) } label: {
                    Text(type.title)
                        .font(.system(size: 12, weight: active ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .foregroundStyle(active ? Color.white : Color.primary)
                        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 6)
            Text("↩ siguiente · ⇥ cambia\n⌥↩ salto de línea")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
        }
        .padding(8)
        .frame(width: 150)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }
}

// MARK: - Página impresa (PDF y miniatura)

/// Una página del guion tal como se imprime.
struct ScriptPage: View {
    let entries: [(line: ScriptLine, previous: ScriptElement?)]
    var number: Int? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            VStack(alignment: .leading, spacing: 0) {
                ForEach(entries, id: \.line.id) { entry in
                    Text(ScriptLayout.display(entry.line).isEmpty ? " " : ScriptLayout.display(entry.line))
                        .font(ScriptLayout.font)
                        .foregroundStyle(.black)
                        .multilineTextAlignment(ScriptLayout.textAlignment(entry.line.type))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: ScriptLayout.width(entry.line.type), alignment: ScriptLayout.alignment(entry.line.type))
                        .padding(.leading, ScriptLayout.indent(entry.line.type))
                        .padding(.top, ScriptLayout.spaceAbove(entry.line.type, after: entry.previous))
                }
            }
            .padding(.top, ScriptLayout.marginTop)
            .padding(.leading, ScriptLayout.marginLeft)

            if let number, number > 1 {
                Text("\(number).")
                    .font(ScriptLayout.font)
                    .foregroundStyle(.black)
                    .frame(width: ScriptLayout.page.width - ScriptLayout.marginRight, alignment: .trailing)
                    .padding(.top, 36)
            }
        }
        .frame(width: ScriptLayout.page.width, height: ScriptLayout.page.height, alignment: .topLeading)
        .environment(\.colorScheme, .light)
    }
}

/// Portada: el título centrado.
struct ScriptTitlePage: View {
    let title: String

    var body: some View {
        ZStack {
            Color.white
            Text(title.uppercased())
                .font(ScriptLayout.font)
                .underline()
                .foregroundStyle(.black)
                .multilineTextAlignment(.center)
                .frame(width: ScriptLayout.textWidth)
                .offset(y: -ScriptLayout.page.height / 6)
        }
        .frame(width: ScriptLayout.page.width, height: ScriptLayout.page.height)
        .environment(\.colorScheme, .light)
    }
}

/// Miniatura para el inicio: la primera página, escalada.
struct ScriptPreview: View {
    let board: Board

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width / ScriptLayout.page.width, geo.size.height / ScriptLayout.page.height) * 1.6
            let first = ScriptLayout.paginate(board.script ?? []).first ?? []
            ScriptPage(entries: first)
                .scaleEffect(s, anchor: .top)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .offset(y: 8)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipped()
        .allowsHitTesting(false)
    }
}

// MARK: - Exportar

@MainActor
enum ScriptPDF {
    static func export(_ board: Board) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = board.name + ".pdf"
        panel.prompt = "Exportar"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var box = CGRect(origin: .zero, size: ScriptLayout.page)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }

        func draw<V: View>(_ view: V) {
            ImageRenderer(content: view).render { _, render in
                pdf.beginPDFPage(nil)
                render(pdf)
                pdf.endPDFPage()
            }
        }

        draw(ScriptTitlePage(title: board.name))
        let lines = (board.script ?? []).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        for (i, page) in ScriptLayout.paginate(lines).enumerated() where !page.isEmpty {
            draw(ScriptPage(entries: page, number: i + 1))
        }
        pdf.closePDF()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
