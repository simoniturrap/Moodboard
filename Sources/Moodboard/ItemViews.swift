import SwiftUI
import AVKit

struct ItemView: View {
    let item: BoardItem
    let scale: Double
    let isSelected: Bool
    let isEditing: Bool
    let onTextChange: (String) -> Void
    let onEndEditing: () -> Void
    /// Resto de piezas del tablero: sólo lo usan las columnas para encontrar su contenido.
    var siblings: [BoardItem] = []
    /// Posición de inserción mientras se arrastra algo sobre esta columna (nil = no es el destino).
    var dropIndex: Int? = nil
    /// true mientras se arrastra algo sobre esta carpeta (`.board`): la resalta como destino.
    var folderTargeted: Bool = false
    /// Piezas contenidas que están seleccionadas (se resaltan dentro de la columna).
    var selectedChildren: Set<UUID> = []
    /// Clic sobre una pieza contenida: la activa para indicar que se puede sacar.
    var onChildTap: (UUID) -> Void = { _ in }
    /// Doble clic sobre una carpeta contenida: abre su sub-tablero.
    var onChildOpen: (UUID) -> Void = { _ in }
    /// Dibuja a resolución completa en vez de una miniatura dimensionada a pantalla. Lo usa el export
    /// a PDF, que necesita la foto entera para imprimir nítido; en el lienzo se queda en `false`.
    var fullResolution: Bool = false

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
            case .video: videoCard
            case .note:  noteCard
            case .frame: frameCard
            case .text:  textBlock
            case .board: boardCard
            case .column: columnCard
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
        picture.overlay(alignment: .topTrailing) {
            UploadBadge(media: item.media)
                .scaleEffect(1 / scale, anchor: .topTrailing)
        }
    }

    // MARK: - Video

    private var videoCard: some View {
        VideoCard(media: item.media)
            .overlay(alignment: .topTrailing) {
                UploadBadge(media: item.media)
                    .scaleEffect(1 / scale, anchor: .topTrailing)
            }
    }

    /// Lado mayor (en px físicos) al que de verdad se dibuja la foto, para pedir una miniatura a esa
    /// resolución y no un bitmap enorme. Incluye el zoom de la cámara, la densidad de la pantalla y el
    /// recorte (si sólo se ve un trozo de la foto, ese trozo necesita más resolución del original).
    private var targetPixels: Int {
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let cropW = max(item.crop?.width ?? 1, 0.01)
        let cropH = max(item.crop?.height ?? 1, 0.01)
        let wPx = item.w * scale * backing / cropW
        let hPx = item.h * scale * backing / cropH
        return Int(ceil(max(wPx, hPx)))
    }

    @ViewBuilder
    private var picture: some View {
        let loaded = item.media.flatMap {
            fullResolution ? ImageCache.shared.image(named: $0)
                           : ImageCache.shared.thumbnail(named: $0, maxPixel: targetPixels)
        }
        ZStack {
            if let img = loaded {
                CroppedImage(image: img, crop: item.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1),
                             size: CGSize(width: item.w, height: item.kind == .frame ? item.h - 34 : item.h))
                    // La foto recién descargada entra con un leve fundido/zoom en vez de aparecer de golpe.
                    .transition(.opacity.combined(with: .scale(scale: 1.03)))
            } else {
                Rectangle()
                    .fill(.gray.opacity(0.25))
                    .overlay {
                        // Mientras la foto se baja del servidor giramos un indicador; si no hay nada que
                        // esperar (sin media o sin sincronización) mostramos el marcador de imagen.
                        if item.media != nil && SyncConfig.isConfigured {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(1 / scale)
                        } else {
                            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                        }
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: loaded != nil)
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
                .overlay(alignment: .topLeading) {
                    // Guía mientras la nota está vacía; desaparece al escribir.
                    if item.text.isEmpty {
                        Text("Empieza a escribir…")
                            .font(item.swiftUIFont)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, TextMetrics.horizontalInset)
                            .padding(.vertical, TextMetrics.verticalInset)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            Text(item.text.isEmpty ? "Empieza a escribir…" : item.text)
                .font(item.swiftUIFont)
                .foregroundStyle(item.text.isEmpty ? AnyShapeStyle(.secondary) : item.textColor)
                .padding(.horizontal, TextMetrics.horizontalInset)
                .padding(.vertical, TextMetrics.verticalInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Carpeta: sub-tablero

    private var boardCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Color.accentColor)
            Group {
                if isEditing {
                    TextField("Nombre", text: Binding(get: { item.text }, set: onTextChange))
                        .textFieldStyle(.plain)
                        .focused($editorFocused)
                        .onAppear(perform: focusEditor)
                        .multilineTextAlignment(.center)
                        .onSubmit(onEndEditing)
                        .onExitCommand(perform: onEndEditing)
                } else {
                    Text(item.text.isEmpty ? "Tablero" : item.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        )
        .overlay(
            // En reposo, un borde tenue; mientras se arrastra algo encima, se resalta en acento.
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(folderTargeted ? Color.accentColor : .primary.opacity(0.08),
                              lineWidth: folderTargeted ? 2.5 : 1)
                .background(folderTargeted
                            ? RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08))
                            : nil)
        )
        .animation(.easeInOut(duration: 0.15), value: folderTargeted)
    }

    // MARK: - Columna: contenedor organizador

    private var columnCard: some View {
        let pad = Store.ColumnMetrics.padding
        let inner = max(item.w - pad * 2, 20)
        let byID = Dictionary(siblings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let childItems = (item.children ?? []).compactMap { byID[$0] }
        let active = dropIndex != nil
        return VStack(spacing: 0) {
            columnHeader
            Divider().opacity(0.3)
            if childItems.isEmpty {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(active ? Color.accentColor : .secondary.opacity(0.35),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(active ? Color.accentColor.opacity(0.08) : .clear)
                    .overlay(Text("Arrastra elementos hasta acá")
                        .font(.caption)
                        .foregroundStyle(active ? Color.accentColor : .secondary))
                    .frame(maxWidth: .infinity)
                    .frame(height: Store.ColumnMetrics.empty)
                    .padding(pad)
            } else {
                VStack(spacing: Store.ColumnMetrics.spacing) {
                    if dropIndex == 0 { insertionBar.transition(.opacity) }
                    ForEach(Array(childItems.enumerated()), id: \.element.id) { idx, child in
                        ColumnChildView(child: child, width: inner, scale: scale,
                                        siblings: siblings,
                                        isSelected: selectedChildren.contains(child.id),
                                        fullResolution: fullResolution,
                                        onTap: { onChildTap(child.id) },
                                        onOpen: { onChildOpen(child.id) })
                            // Al entrar/salir del contenedor la pieza se amplía/reduce con un fundido
                            // en lugar de aparecer o desaparecer de golpe.
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                        if dropIndex == idx + 1 { insertionBar.transition(.opacity) }
                    }
                }
                .padding(pad)
            }
        }
        // El cambio en la lista de hijos (y el indicador de inserción) se anima: las piezas se
        // acomodan y la columna crece o se encoge en lugar de dar un salto.
        .animation(.spring(duration: 0.4, bounce: 0.18), value: item.children)
        .animation(.easeInOut(duration: 0.18), value: dropIndex)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8)
                // Superficie de tarjeta del sistema: blanca en claro, gris oscuro en oscuro.
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
        )
        .overlay(
            // Sin borde en reposo: sólo se resalta mientras se arrastra algo encima.
            RoundedRectangle(cornerRadius: 8)
                .stroke(active ? Color.accentColor : .clear, lineWidth: active ? 2 : 0)
        )
    }

    /// Línea que señala la posición exacta donde caerá lo que se arrastra.
    private var insertionBar: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 3)
            .frame(maxWidth: .infinity)
    }

    private var columnHeader: some View {
        Group {
            if isEditing {
                TextField("Columna", text: Binding(get: { item.text }, set: onTextChange))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($editorFocused)
                    .onAppear(perform: focusEditor)
                    .onSubmit(onEndEditing)
                    .onExitCommand(perform: onEndEditing)
            } else {
                Text(item.text.isEmpty ? "Columna" : item.text)
                    .foregroundStyle(item.text.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 10)
        .frame(height: Store.ColumnMetrics.header)
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
        .overlay(alignment: .topTrailing) {
            UploadBadge(media: item.media)
                .scaleEffect(1 / scale, anchor: .topTrailing)
                .padding(5)
        }
    }
}

/// Insignia de verificación de subida sobre una foto: gira mientras sube, muestra un visto bueno
/// al terminar (y se desvanece), un aviso si la subida al servidor falló (toca para reintentar), o
/// una pausa si se frenó por cuota de almacenamiento (se reintenta sola al liberar espacio).
private struct UploadBadge: View {
    let media: String?
    @ObservedObject private var sync = SyncService.shared

    var body: some View {
        let state = sync.uploadState(media)
        ZStack {
            if let state {
                Circle().fill(.black.opacity(0.55))
                switch state {
                case .uploading:
                    ProgressView().controlSize(.mini).tint(.white)
                case .uploaded:
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.yellow)
                case .pausedQuota:
                    Image(systemName: "pause.fill")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
                }
            }
        }
        .frame(width: 22, height: 22)
        .padding(6)
        .opacity(state == nil ? 0 : 1)
        .help(state == .pausedQuota ? "En pausa: se subirá al liberar espacio" : "")
        .onTapGesture { if state == .failed || state == .pausedQuota, let media { sync.retryUpload(media) } }
        .allowsHitTesting(state == .failed || state == .pausedQuota)
        .animation(.easeInOut(duration: 0.25), value: state)
    }
}

/// Reproductor de video embebido en el lienzo. Carga el archivo local del almacén; si aún no está
/// (sincronización en curso) muestra un marcador y lo baja del servidor, reconstruyendo el reproductor al
/// llegar. AVKit aporta los controles de transporte.
private struct VideoCard: View {
    let media: String?
    @ObservedObject private var sync = SyncService.shared
    @State private var player: AVPlayer?
    @State private var requested = false

    private var fileURL: URL? {
        guard let media else { return nil }
        let url = Store.mediaDir.appendingPathComponent(media)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.black.opacity(0.85))
                    .overlay {
                        if media != nil && SyncConfig.isConfigured {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "film").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
                        }
                    }
            }
        }
        .onAppear(perform: load)
        .onChange(of: sync.mediaTick) { _, _ in load() }   // el archivo llegó del servidor: monta el reproductor
        .onDisappear { player?.pause() }
    }

    private func load() {
        guard player == nil else { return }
        if let url = fileURL {
            player = AVPlayer(url: url)
        } else if let media, SyncConfig.isConfigured, !requested {
            requested = true
            Task { await SyncService.shared.downloadMedia(media) }
        }
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

/// Pieza dentro de una columna: se dibuja escalada al ancho del contenedor y sin interacción propia.
/// Arrastrarla la saca del contenedor y la deja suelta en el lienzo siguiendo el cursor (el trabajo
/// lo hace `BoardCanvas` por callbacks, porque esta vista también se usa al exportar a PDF, sin store).
private struct ColumnChildView: View {
    let child: BoardItem
    let width: Double
    let scale: Double
    let siblings: [BoardItem]
    let isSelected: Bool
    var fullResolution: Bool = false
    let onTap: () -> Void
    /// Doble clic: replica el del lienzo según el tipo (tablero → entrar, foto → lightbox…).
    var onOpen: () -> Void = {}

    /// El mouse está encima: resalta la pieza para indicar que se interactúa con ella (no con la columna).
    @State private var hovering = false

    var body: some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onOpen() }
            .onTapGesture { onTap() }
            .onHover { hovering = $0 }
            // Aro de realce al pasar el mouse (si no está ya seleccionada): avisa de que es la pieza activa.
            .overlay {
                if hovering && !isSelected {
                    RoundedRectangle(cornerRadius: child.kind == .board ? 6 : 2)
                        .stroke(Color.accentColor.opacity(0.7), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private var content: some View {
        // Las carpetas se dibujan como una fila compacta (icono + nombre), no como la tarjeta cuadrada.
        if child.kind == .board {
            CompactBoardRow(child: child, width: width, isSelected: isSelected)
        } else {
            let f = width / max(child.w, 1)
            ItemView(item: child, scale: scale * f, isSelected: isSelected, isEditing: false,
                     onTextChange: { _ in }, onEndEditing: {}, siblings: siblings,
                     fullResolution: fullResolution)
                .frame(width: child.w, height: child.h)
                .scaleEffect(f, anchor: .topLeading)
                .frame(width: width, height: child.h * f, alignment: .topLeading)
                .clipped()
                .allowsHitTesting(false)
                // El arrastre para sacar la pieza del contenedor lo conduce el gesto de la columna
                // (ver `itemDrag` en BoardCanvas): aquí no se añade, porque esta vista desaparece en
                // cuanto la pieza abandona la columna y cortaría el arrastre a mitad.
        }
    }
}

/// Fila compacta de una carpeta dentro de una columna: el icono de carpeta y, al lado, su nombre.
/// Ocupa poco alto (`ColumnMetrics.boardRow`) en vez de la tarjeta cuadrada del lienzo.
private struct CompactBoardRow: View {
    let child: BoardItem
    let width: Double
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
            Text(child.text.isEmpty ? "Tablero" : child.text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: Store.ColumnMetrics.boardRow, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : .primary.opacity(0.1),
                        lineWidth: isSelected ? 2 : 1)
        )
    }
}
