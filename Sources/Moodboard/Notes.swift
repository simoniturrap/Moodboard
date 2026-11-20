import SwiftUI
import AppKit

/// Gestor de notas tipo Notion: barra lateral con las páginas y, a la derecha,
/// título y cuerpo de texto enriquecido de la nota activa.
struct NotesView: View {
    @EnvironmentObject var store: Store
    @State private var windowWidth: Double = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 260)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { windowWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in windowWidth = w }
        })
        .overlay(alignment: .bottomLeading) { HStack(spacing: 10) { InboxButton(); TrashButton() }.padding(16) }
        .toolbar { TabsToolbarItem(width: max(160, windowWidth - 160)) }
    }

    // MARK: - Barra lateral

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            BoardSwitcher()
                .padding(.horizontal, 12)
                .padding(.top, 12)

            HStack {
                Text("Notas")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { store.addNote() } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help("Nueva nota")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.notes) { note in
                        NoteRow(note: note, isActive: note.id == store.activeNote?.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 56)   // deja sitio al botón de papelera flotante
            }
        }
    }

    // MARK: - Detalle

    @ViewBuilder
    private var detail: some View {
        if let note = store.activeNote {
            NoteDetail(note: note)
                .id(note.id)   // cambiar de nota recrea el editor con su contenido
        } else {
            VStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Selecciona o crea una nota.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Fila de una nota en la barra lateral.
private struct NoteRow: View {
    @EnvironmentObject var store: Store
    let note: Note
    let isActive: Bool
    @State private var isHovered = false

    var body: some View {
        Button { store.selectNote(note.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title.isEmpty ? "Sin título" : note.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(note.title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Text(note.modifiedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(background, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Eliminar", role: .destructive) { store.deleteNote(note.id) }
        }
    }

    private var background: Color {
        if isActive { return Color.accentColor.opacity(0.18) }
        if isHovered { return Color.primary.opacity(0.06) }
        return .clear
    }
}

/// Título y cuerpo enriquecido de una nota. Se recrea al cambiar de nota (`.id`).
private struct NoteDetail: View {
    @EnvironmentObject var store: Store
    let note: Note
    @StateObject private var editor = RichTextController()
    @State private var title: String

    init(note: Note) {
        self.note = note
        _title = State(initialValue: note.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormatBar(editor: editor)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                TextField("Sin título", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .bold))
                    .onChange(of: title) { _, new in store.renameNote(note.id, to: new) }
                // El editor gestiona su propio desplazamiento (sin scroll anidado).
                RichTextEditor(initialRTF: note.rtf, controller: editor) { data in
                    store.updateNoteBody(note.id, rtf: data)
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Barra de formato: estilos de bloque y marcas en línea.
private struct FormatBar: View {
    @ObservedObject var editor: RichTextController

    var body: some View {
        HStack(spacing: 6) {
            Button { editor.applyBlock(size: 28, bold: true) } label: { Text("Título").font(.callout.weight(.bold)) }
                .help("Título")
            Button { editor.applyBlock(size: 20, bold: true) } label: { Text("Encabezado").font(.callout) }
                .help("Encabezado")
            Button { editor.applyBlock(size: 15, bold: false) } label: { Text("Cuerpo").font(.callout) }
                .help("Texto normal")
            Divider().frame(height: 16)
            Button { editor.toggleBold() } label: { Image(systemName: "bold") }
                .help("Negrita")
            Button { editor.toggleItalic() } label: { Image(systemName: "italic") }
                .help("Cursiva")
            Button { editor.toggleUnderline() } label: { Image(systemName: "underline") }
                .help("Subrayado")
            Spacer()
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
    }
}

// MARK: - Editor de texto enriquecido (AppKit)

/// Controla el `NSTextView` del editor para aplicar formato desde la barra.
final class RichTextController: ObservableObject {
    weak var textView: NSTextView?

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    /// Aplica un estilo de bloque (tamaño y grosor) a la selección o a lo que se escriba.
    func applyBlock(size: CGFloat, bold: Bool) {
        guard let tv = textView else { return }
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        let range = tv.selectedRange()
        if range.length == 0 {
            tv.typingAttributes[.font] = font
        } else if let storage = tv.textStorage {
            storage.addAttribute(.font, value: font, range: range)
            tv.didChangeText()
        }
    }

    func toggleUnderline() {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let isOn = (currentValue(.underlineStyle, tv, range) as? Int ?? 0) != 0
        let value = isOn ? 0 : NSUnderlineStyle.single.rawValue
        if range.length == 0 {
            tv.typingAttributes[.underlineStyle] = value
        } else if let storage = tv.textStorage {
            storage.addAttribute(.underlineStyle, value: value, range: range)
            tv.didChangeText()
        }
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let tv = textView else { return }
        let fm = NSFontManager.shared
        let range = tv.selectedRange()
        let sample = currentFont(tv, at: range)
        let isOn = fm.traits(of: sample).contains(trait)
        let apply: (NSFont) -> NSFont = { f in
            isOn ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait)
        }
        if range.length == 0 {
            var attrs = tv.typingAttributes
            attrs[.font] = apply((attrs[.font] as? NSFont) ?? sample)
            tv.typingAttributes = attrs
        } else if let storage = tv.textStorage {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                let f = (value as? NSFont) ?? sample
                storage.addAttribute(.font, value: apply(f), range: sub)
            }
            storage.endEditing()
            tv.didChangeText()
        }
    }

    private func currentFont(_ tv: NSTextView, at range: NSRange) -> NSFont {
        (currentValue(.font, tv, range) as? NSFont) ?? NSFont.systemFont(ofSize: 15)
    }

    /// Valor de un atributo en la selección (o en los atributos de escritura si está vacía).
    private func currentValue(_ key: NSAttributedString.Key, _ tv: NSTextView, _ range: NSRange) -> Any? {
        if range.length > 0, let storage = tv.textStorage, storage.length > 0 {
            return storage.attribute(key, at: min(range.location, storage.length - 1), effectiveRange: nil)
        }
        return tv.typingAttributes[key]
    }
}

/// `NSTextView` enriquecido envuelto para SwiftUI; serializa a RTF en cada cambio.
struct RichTextEditor: NSViewRepresentable {
    let initialRTF: Data?
    let controller: RichTextController
    let onChange: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }

        tv.delegate = context.coordinator
        tv.isEditable = true
        tv.isRichText = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 8)
        tv.font = NSFont.systemFont(ofSize: 15)
        tv.textColor = .labelColor
        tv.typingAttributes = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true

        if let data = initialRTF,
           let str = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil) {
            tv.textStorage?.setAttributedString(str)
        }

        controller.textView = tv
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let tv = nsView.documentView as? NSTextView { controller.textView = tv }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let onChange: (Data) -> Void
        init(onChange: @escaping (Data) -> Void) { self.onChange = onChange }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView, let storage = tv.textStorage else { return }
            let range = NSRange(location: 0, length: storage.length)
            if let data = storage.rtf(from: range, documentAttributes: [:]) { onChange(data) }
        }
    }
}
