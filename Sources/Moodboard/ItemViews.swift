import SwiftUI

struct ItemView: View {
    let item: BoardItem
    let scale: Double
    let isSelected: Bool
    let isEditing: Bool
    let onTextChange: (String) -> Void
    let onEndEditing: () -> Void

    /// Al entrar en edición el cursor ya está dentro: se escribe sin un segundo clic.
    @FocusState private var editorFocused: Bool

    private func focusEditor() {
        // Dos vueltas: la primera deja que el lienzo termine de procesar el clic que creó la pieza.
        DispatchQueue.main.async { DispatchQueue.main.async { editorFocused = true } }
    }

    var body: some View {
        Group {
            switch item.kind {
            case .image: imageCard
            case .note:  noteCard
            case .frame: frameCard
            case .text:  textBlock
            }
        }
        .overlay {
            if isSelected {
                // Contorno interno de 2 px blanco, siguiendo la forma de la pieza.
                RoundedRectangle(cornerRadius: item.kind == .image || item.kind == .text ? 0 : 8)
                    .strokeBorder(.white, lineWidth: 2 / scale)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Foto suelta

    private var imageCard: some View {
        picture
    }

    @ViewBuilder
    private var picture: some View {
        if let file = item.media, let img = ImageCache.shared.image(named: file) {
            CroppedImage(image: img, crop: item.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1),
                         size: CGSize(width: item.w, height: item.kind == .frame ? item.h - 34 : item.h))
        } else {
            Rectangle()
                .fill(.gray.opacity(0.25))
                .overlay(Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary))
        }
    }

    // MARK: - Nota

    private var noteCard: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: item.colorHex))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)

            if isEditing {
                TextEditor(text: Binding(get: { item.text }, set: onTextChange))
                    .focused($editorFocused)
                    .onAppear(perform: focusEditor)
                    .font(item.swiftUIFont)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(.black)
                    .padding(8)
                    .onExitCommand(perform: onEndEditing)
            } else {
                Text(item.text.isEmpty ? "Doble clic para escribir" : item.text)
                    .font(item.swiftUIFont)
                    .foregroundStyle(item.text.isEmpty ? .black.opacity(0.35) : .black.opacity(0.85))
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: - Bloque de texto (sin fondo)

    @ViewBuilder
    private var textBlock: some View {
        if isEditing {
            TextEditor(text: Binding(get: { item.text }, set: onTextChange))
                    .focused($editorFocused)
                    .onAppear(perform: focusEditor)
                .font(item.swiftUIFont)
                .foregroundStyle(item.textColor)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .padding(.vertical, TextMetrics.verticalInset)
                .onExitCommand(perform: onEndEditing)
        } else {
            Text(item.text.isEmpty ? "Escribe…" : item.text)
                .font(item.swiftUIFont)
                .foregroundStyle(item.text.isEmpty ? AnyShapeStyle(.secondary) : item.textColor)
                .padding(.horizontal, TextMetrics.horizontalInset)
                .padding(.vertical, TextMetrics.verticalInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Viñeta de storyboard

    private var frameCard: some View {
        VStack(spacing: 0) {
            picture
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Group {
                if isEditing {
                    TextField("Acción / plano…", text: Binding(get: { item.text }, set: onTextChange), axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($editorFocused)
                        .onAppear(perform: focusEditor)
                        .onSubmit(onEndEditing)
                } else {
                    Text(item.text.isEmpty ? "Acción / plano…" : item.text)
                        .foregroundStyle(item.text.isEmpty ? .secondary : .primary)
                }
            }
            .font(.system(size: 12))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .frame(height: 34)
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: item.colorHex).opacity(0.9))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        )
    }
}

/// Muestra la zona recortada de una imagen cubriendo el tamaño dado (como aspectFill, pero del recorte).
struct CroppedImage: View {
    let image: NSImage
    let crop: CGRect
    let size: CGSize

    var body: some View {
        let img = image.size
        let cropW = max(crop.width * img.width, 1), cropH = max(crop.height * img.height, 1)
        let s = max(size.width / cropW, size.height / cropH)
        // Desplaza la imagen completa para que el centro del recorte quede en el centro del marco.
        let x = -crop.minX * img.width * s - (cropW * s - size.width) / 2
        let y = -crop.minY * img.height * s - (cropH * s - size.height) / 2
        Image(nsImage: image)
            .resizable()
            .frame(width: img.width * s, height: img.height * s)
            .offset(x: x, y: y)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
    }
}
