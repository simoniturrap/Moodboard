import SwiftUI

/// Texto que se convierte en campo editable con doble clic.
/// Enter o perder el foco confirma; Esc cancela.
struct RenamableText: View {
    let text: String
    @Binding var isEditing: Bool
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if isEditing {
            TextField("Nombre", text: $draft)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { isEditing = false }
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onAppear {
                    draft = text
                    DispatchQueue.main.async { focused = true }
                }
        } else {
            Text(text)
                .lineLimit(1)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded { isEditing = true })
                .help("Doble clic para renombrar")
        }
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != text { onCommit(name) }
    }
}

/// Modal que pide el nombre antes de crear un tablero.
struct NewBoardSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nuevo \(store.newDocumentKind.title.lowercased())")
                .font(.headline)
            Picker("Tipo", selection: $store.newDocumentKind) {
                ForEach(DocumentKind.allCases, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.icon).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField(store.newDocumentKind.untitled, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Crear", action: create)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = store.newDocumentKind
        store.newBoard(named: trimmed.isEmpty ? kind.untitled : trimmed, kind: kind)
        dismiss()
    }
}

/// Oculta el título nativo de la ventana para usar uno propio renombrable en la barra.
struct HideSystemTitle: ViewModifier {
    let windowTitle: String

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .navigationTitle(windowTitle)
                .toolbar(removing: .title)
        } else {
            content.navigationTitle("")
        }
    }
}
