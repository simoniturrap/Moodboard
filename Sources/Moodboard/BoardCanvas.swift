import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BoardCanvas: View {
    @EnvironmentObject var store: Store

    @State private var dragOrigins: [UUID: CGPoint] = [:]
    /// Pieza tal como estaba al empezar a redimensionarla.
    @State private var resizeStart: BoardItem?
    @State private var panOrigin: Camera?
    /// Espacio o H mantenidos: arrastrar mueve el tablero en vez de seleccionar.
    @State private var isHandHeld = false
    /// Pieza que guía el imán al soltar (con ⌥ es la copia, no la original).
    @State private var dragPrimary: UUID?
    /// Eje bloqueado con ⇧ durante el arrastre.
    @State private var dragAxis: Axis?
    @State private var marquee: CGRect?
    @State private var viewportSize: CGSize = .zero
    @State private var isTargeted = false
    /// Último zoom distinto de 100 %, para alternar con Z.
    @State private var lastZoom: Double = 0.5

    private var board: Board? { store.activeBoard }
    private var camera: Camera { board?.camera ?? Camera() }
    private var scale: Double { camera.scale }

    // MARK: - Conversión de coordenadas

    private func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + camera.x, y: p.y * scale + camera.y)
    }

    private func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - camera.x) / scale, y: (p.y - camera.y) / scale)
    }

    /// Le dice al Store qué parte del tablero se ve, para decidir dónde pegar.
    private func updateVisibleRect() {
        let origin = toWorld(.zero)
        store.visibleWorldRect = CGRect(x: origin.x, y: origin.y,
                                        width: viewportSize.width / scale, height: viewportSize.height / scale)
    }

    /// Ancho de la tira de pestañas en la barra: la ventana menos semáforos e iconos de la derecha.
    private var tabsWidth: Double {
        max(160, viewportSize.width - 500)
    }

    private var viewportCenterInWorld: CGPoint {
        toWorld(CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2))
    }

    // MARK: - Cuerpo

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                DotGrid(camera: camera)
                    .contentShape(Rectangle())
                    .gesture(backgroundDrag)
                    .modifier(ToolCursor(tool: store.tool))
                    .onTapGesture { location in
                        if placeWithTool(at: location) { return }
                        store.selection = []
                        store.editingItem = nil
                        store.focusArea = .canvas
                        withAnimation(.spring(duration: 0.3, bounce: 0.18)) { store.isBoardMenuOpen = false }
                    }
                    .onTapGesture(count: 2) { location in
                        let item = store.noteItem(at: toWorld(location))
                        store.add(item)
                        store.editingItem = item.id
                    }

                content

                if isHandHeld {
                    // Capa de mano: tapa las piezas para que cualquier arrastre desplace el lienzo.
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(panDrag)
                        .modifier(HandCursor(grabbing: panOrigin != nil))
                }

                if let m = marquee {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                        .frame(width: m.width, height: m.height)
                        .offset(x: m.minX, y: m.minY)
                        .allowsHitTesting(false)
                }

                if board?.items.isEmpty ?? true {
                    hint.frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .background(WheelZoomCatcher(onScroll: handleScroll, onMagnify: handleMagnify))
            .background(KeyCatcher(onKey: handleKey))
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                isHandHeld = false   // si se cambia de ventana con el espacio pulsado, no queda la mano pegada
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    BoardSwitcher()
                    breadcrumb
                }
                .padding(20)
            }
            .overlay(alignment: .bottomLeading) {
                TrashButton().padding(20)
            }
            .overlay(alignment: .trailing) {
                // Sin selección: herramientas. Con algo seleccionado: opciones de ese elemento.
                ZStack(alignment: .trailing) {
                    if store.selection.isEmpty {
                        ToolPalette()
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        OptionsBar()
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(20)
                .animation(.spring(duration: 0.32, bounce: 0.2), value: store.selection.isEmpty)
            }
            .clipped()
            .coordinateSpace(name: "viewport")
            .onAppear { viewportSize = geo.size }
            .onChange(of: geo.size) { _, new in
                viewportSize = new
                frameOpenedBoard()
            }
            .onChange(of: store.boardToFrame) { _, _ in frameOpenedBoard() }
            .onAppear { DispatchQueue.main.async { frameOpenedBoard() } }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                        .background(Color.accentColor.opacity(0.08))
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, location in
                var offset = CGPoint.zero
                var added = false
                for url in urls {
                    if let item = store.makeImageItem(from: url, at: toWorld(location) + offset) {
                        store.add(item)
                        offset.x += 26; offset.y += 26
                        added = true
                    }
                }
                return added
            } isTargeted: { isTargeted = $0 }
        }
        .focusable()
        .focusEffectDisabled()
        .onChange(of: camera) { _, _ in updateVisibleRect() }
        .onChange(of: viewportSize) { _, _ in updateVisibleRect() }
        .onAppear(perform: updateVisibleRect)
        .toolbar { toolbarItems }
    }

    /// Sólo las piezas cercanas a lo que se ve: con muchas imágenes, dibujar las de fuera
    /// de pantalla hacía el desplazamiento y el zoom más pesados. El margen (medio viewport)
    /// las deja listas antes de entrar, para que no aparezcan de golpe al desplazarse.
    private var visibleItems: [BoardItem] {
        let all = (board?.items ?? []).sorted { $0.z < $1.z }
        guard viewportSize.width > 0, viewportSize.height > 0 else { return all }
        let origin = toWorld(.zero)
        let visible = CGRect(x: origin.x, y: origin.y,
                             width: viewportSize.width / scale, height: viewportSize.height / scale)
        let margin = max(visible.width, visible.height) * 0.5
        let reach = visible.insetBy(dx: -margin, dy: -margin)
        return all.filter { reach.intersects($0.frameRect) }
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            ForEach(visibleItems) { item in
                let isSelected = store.selection.contains(item.id)
                ItemView(item: item,
                         scale: scale,
                         isSelected: isSelected,
                         isEditing: store.editingItem == item.id,
                         onTextChange: { store.updateText(item.id, $0) },
                         onEndEditing: { store.editingItem = nil })
                    .frame(width: item.w, height: item.h)
                    .gesture(itemDrag(item))
                    .simultaneousGesture(TapGesture().onEnded { select(item) })
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        switch item.kind {
                        case .image:
                            withAnimation(.spring(duration: 0.3, bounce: 0.12)) { store.lightboxItem = item.id }
                        case .board:
                            store.openBoardFolder(item)
                        default:
                            store.editingItem = item.id
                        }
                    })
                    .contextMenu {
                        if item.kind == .image { imageMenu(item) }
                        if item.kind == .board { boardMenu(item) }
                    }
                    .overlay {
                        // Las asas de redimensionar sólo en lo seleccionado: antes había 4 por pieza
                        // (cada una con su gesto y seguimiento del cursor) aunque no estuviera elegida.
                        if isSelected {
                            ForEach(Corner.allCases, id: \.self) { corner in
                                ResizeHandle(corner: corner, scale: scale)
                                    .gesture(resizeDrag(item, from: corner))
                            }
                        }
                    }
                    .offset(x: item.x, y: item.y)
            }
        }
        .scaleEffect(scale, anchor: .topLeading)
        .offset(x: camera.x, y: camera.y)
    }

    /// Ruta de carpetas hasta el sub-tablero abierto; cada eslabón vuelve a su nivel.
    @ViewBuilder
    private var breadcrumb: some View {
        if let board, !store.ancestors(of: board.id).isEmpty {
            let chain = store.ancestors(of: board.id)
            HStack(spacing: 4) {
                ForEach(chain) { ancestor in
                    Button { store.select(board: ancestor.id) } label: {
                        Text(ancestor.name).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Text(board.name).lineLimit(1).fontWeight(.medium)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }

    private var hint: some View {
        VStack(spacing: 6) {
            Text("Tablero vacío")
                .font(.headline)
            Text("Arrastra fotos desde el Finder · ⌘V para pegar · doble clic para una nota")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Gestos

    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("viewport"))
            // Arrastrar el fondo dibuja un marco de selección; ⇧ suma a lo ya seleccionado.
            .onChanged { value in
                marquee = CGRect(x: min(value.startLocation.x, value.location.x),
                                 y: min(value.startLocation.y, value.location.y),
                                 width: abs(value.translation.width),
                                 height: abs(value.translation.height))
            }
            .onEnded { _ in
                if let m = marquee {
                    let world = CGRect(origin: toWorld(m.origin),
                                       size: CGSize(width: m.width / scale, height: m.height / scale))
                    let hit = Set((board?.items ?? [])
                        .filter { world.intersects($0.frameRect) }
                        .map(\.id))
                    store.focusArea = .canvas
                    store.editingItem = nil
                    store.selection = NSEvent.modifierFlags.contains(.shift) ? store.selection.union(hit) : hit
                }
                marquee = nil
            }
    }

    /// Con espacio o H mantenidos, arrastrar desplaza el lienzo.
    private var panDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("viewport"))
            .onChanged { value in
                let base = panOrigin ?? camera
                if panOrigin == nil { panOrigin = camera }
                store.mutateBoard {
                    $0.camera.x = base.x + value.translation.width
                    $0.camera.y = base.y + value.translation.height
                }
            }
            .onEnded { _ in panOrigin = nil }
    }

    private func itemDrag(_ item: BoardItem) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("viewport"))
            .onChanged { value in
                if dragOrigins.isEmpty {
                    // Mover no selecciona: si la pieza ya estaba seleccionada se mueve el grupo,
                    // si no, se mueve sola y se limpia la selección anterior.
                    let wasSelected = store.selection.contains(item.id)
                    var ids = wasSelected ? store.selection : [item.id]
                    if !wasSelected { store.selection = [] }
                    store.focusArea = .canvas
                    store.checkpoint()
                    dragPrimary = item.id
                    // ⌥: se arrastra una copia y el original se queda en su sitio.
                    if NSEvent.modifierFlags.contains(.option) {
                        let copies = store.cloneItems(ids)
                        ids = Set(copies.values)
                        dragPrimary = copies[item.id]
                        if wasSelected { store.selection = ids }
                    }
                    for it in board?.items ?? [] where ids.contains(it.id) {
                        dragOrigins[it.id] = it.origin
                    }
                    store.bringToFront(ids)
                }
                var dx = value.translation.width / scale
                var dy = value.translation.height / scale
                // ⇧: sólo en el eje en el que más se ha movido (horizontal o vertical).
                if NSEvent.modifierFlags.contains(.shift) {
                    dragAxis = abs(dx) >= abs(dy) ? .horizontal : .vertical
                    if dragAxis == .horizontal { dy = 0 } else { dx = 0 }
                } else {
                    dragAxis = nil
                }
                for (id, origin) in dragOrigins {
                    store.update(id) { $0.origin = CGPoint(x: origin.x + dx, y: origin.y + dy) }
                }
            }
            .onEnded { _ in
                // Imán al soltar: la pieza agarrada cae en la retícula y el resto la acompaña. ⌘ lo desactiva.
                if !NSEvent.modifierFlags.contains(.command),
                   let current = board?.items.first(where: { $0.id == (dragPrimary ?? item.id) }) {
                    var dx = Grid.snap(current.x) - current.x
                    var dy = Grid.snap(current.y) - current.y
                    let gutter = gutterOffset(current.frameRect.offsetBy(dx: dx, dy: dy),
                                              ignoring: Set(dragOrigins.keys))
                    dx += gutter.width
                    dy += gutter.height
                    // Con el eje bloqueado, el imán tampoco mueve en el otro eje.
                    if dragAxis == .horizontal { dy = 0 }
                    if dragAxis == .vertical { dx = 0 }
                    withAnimation(.easeOut(duration: 0.12)) {
                        for id in dragOrigins.keys {
                            store.update(id) { $0.x += dx; $0.y += dy }
                        }
                    }
                }
                dragOrigins = [:]
                dragPrimary = nil
                dragAxis = nil
            }
    }

    /// Redimensiona desde cualquier esquina dejando fija la opuesta.
    private func resizeDrag(_ item: BoardItem, from corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("viewport"))
            .onChanged { value in
                if resizeStart == nil {
                    resizeStart = item
                    store.checkpoint()
                }
                guard let base = resizeStart else { return }
                let keepRatio = item.kind.keepsRatio && !NSEvent.modifierFlags.contains(.shift)
                var w = base.w + corner.sx * value.translation.width / scale
                var h = base.h + corner.sy * value.translation.height / scale
                // Las imágenes conservan proporción salvo que se pulse ⇧.
                if keepRatio { h = w * base.h / max(base.w, 1) }
                w = max(60, w); h = max(40, h)
                store.update(item.id) { $0.frameRect = corner.rect(from: base.frameRect, size: CGSize(width: w, height: h)) }
            }
            .onEnded { _ in
                defer { resizeStart = nil }
                guard let base = resizeStart, !NSEvent.modifierFlags.contains(.command),
                      let current = board?.items.first(where: { $0.id == item.id }) else { return }
                // Al soltar, el ancho cae en la retícula; las fotos recalculan el alto por proporción.
                // El alto también cae en la retícula (las fotos recortan unos pocos px con aspectFill).
                let keepRatio = item.kind.keepsRatio && !NSEvent.modifierFlags.contains(.shift)
                let w = max(Grid.step * 6, Grid.snap(current.w))
                var h = keepRatio ? w * current.h / max(current.w, 1) : current.h
                h = max(Grid.step * 4, Grid.snap(h))
                if item.kind == .text {
                    var probe = current
                    probe.w = w
                    h = store.textHeight(for: probe)
                }
                withAnimation(.easeOut(duration: 0.12)) {
                    store.update(item.id) { $0.frameRect = corner.rect(from: base.frameRect, size: CGSize(width: w, height: h)) }
                }
            }
    }

    /// Clic derecho sobre una foto. Si la foto no estaba seleccionada, la acción se aplica sólo a ella;
    /// si formaba parte de la selección, a toda la selección.
    @ViewBuilder
    private func imageMenu(_ item: BoardItem) -> some View {
        Button("Copiar") { target(item); store.copySelection() }
        Button("Cortar") { target(item); store.cutSelection() }
        Button("Duplicar") { target(item); store.duplicateSelection() }
        Divider()
        Button("Descargar…") { store.downloadImage(item.id) }
    }

    /// Clic derecho sobre una carpeta: abrir el sub-tablero o renombrarla.
    @ViewBuilder
    private func boardMenu(_ item: BoardItem) -> some View {
        Button("Abrir") { store.openBoardFolder(item) }
        Button("Renombrar") { store.selection = [item.id]; store.editingItem = item.id }
        Divider()
        Button("Duplicar") { target(item); store.duplicateSelection() }
        Button("Eliminar", role: .destructive) { target(item); store.deleteSelection() }
    }

    private func target(_ item: BoardItem) {
        store.focusArea = .canvas
        if !store.selection.contains(item.id) { store.selection = [item.id] }
    }

    private func select(_ item: BoardItem) {
        store.focusArea = .canvas
        if NSEvent.modifierFlags.contains(.shift) {
            store.selection.formSymmetricDifference([item.id])
        } else {
            store.selection = [item.id]
        }
    }

    // MARK: - Teclado

    /// Z alterna 100 % ↔ último zoom; ⌫ borra la pieza o el tablero según dónde fue el último clic.
    private func handleKey(_ event: NSEvent) -> Bool {
        // Espacio (49) o H mantenidos activan la mano; al soltarlos, vuelve la selección.
        // Con el lightbox abierto, las teclas son suyas (Esc cancela, ↩ aplica).
        if store.lightboxItem != nil { return false }
        let isHandKey = event.keyCode == 49 || event.charactersIgnoringModifiers?.lowercased() == "h"
        if event.type == .keyUp {
            guard isHandKey else { return false }
            isHandHeld = false
            return true
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.isEmpty else { return false }
        if isHandKey {
            isHandHeld = true
            return true
        }
        switch event.keyCode {
        case 51, 117: // ⌫ y suprimir
            switch store.focusArea {
            case .canvas:
                guard !store.selection.isEmpty else { return false }
                store.deleteSelection()
            case .boards:
                guard let id = board?.id else { return false }
                store.deleteBoard(id)
            }
            return true
        case 53 where store.tool != .select: // Esc suelta la herramienta
            store.tool = .select
            return true
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z":
                if abs(camera.scale - 1) > 0.001 {
                    lastZoom = camera.scale
                    setZoom(1)
                } else {
                    setZoom(lastZoom)
                }
            case "t":
                store.tool = store.tool == .text ? .select : .text
            case "n":
                store.tool = store.tool == .note ? .select : .note
            case "b":
                store.tool = store.tool == .board ? .select : .board
            default:
                return false
            }
            return true
        }
    }

    // MARK: - Herramientas

    /// Con Texto o Nota activas, el clic en el fondo crea la pieza y empieza a escribir.
    private func placeWithTool(at location: CGPoint) -> Bool {
        let point = toWorld(location)
        store.focusArea = .canvas
        let item: BoardItem
        switch store.tool {
        case .select: return false
        case .board:
            // La carpeta crea además su sub-tablero; addBoardFolder deja la pieza en edición.
            store.addBoardFolder(at: point)
            store.tool = .select
            return true
        case .text: item = store.textItem(at: point)
        case .note: item = store.noteItem(at: point)
        }
        store.add(item)
        store.editingItem = item.id
        store.tool = .select
        return true
    }

    /// Desplazamiento para dejar exactamente `Grid.gutter` de separación con la pieza vecina más cercana,
    /// si está a menos de `reach` (tipo masonry). Sólo cuenta vecinos que se solapan en el otro eje.
    private func gutterOffset(_ r: CGRect, ignoring ids: Set<UUID>) -> CGSize {
        let gap = Grid.gutter, reach = 16.0
        var bestX: Double?, bestY: Double?
        func consider(_ d: Double, _ best: inout Double?) {
            if abs(d) < reach, abs(d) < abs(best ?? .infinity) { best = d }
        }
        for other in board?.items ?? [] where !ids.contains(other.id) {
            let f = other.frameRect
            if min(r.maxX, f.maxX) - max(r.minX, f.minX) > 0 {
                consider(f.maxY + gap - r.minY, &bestY)   // debajo del vecino
                consider(f.minY - gap - r.maxY, &bestY)   // encima del vecino
            }
            if min(r.maxY, f.maxY) - max(r.minY, f.minY) > 0 {
                consider(f.maxX + gap - r.minX, &bestX)   // a su derecha
                consider(f.minX - gap - r.maxX, &bestX)   // a su izquierda
            }
        }
        return CGSize(width: bestX ?? 0, height: bestY ?? 0)
    }

    // MARK: - Zoom y desplazamiento

    private func handleScroll(_ delta: CGVector, zooming: Bool) {
        if zooming {
            zoom(by: 1 + delta.dy * 0.01, around: mouseInViewport())
        } else {
            store.mutateBoard {
                $0.camera.x += delta.dx
                $0.camera.y += delta.dy
            }
        }
    }

    private func handleMagnify(_ magnification: CGFloat, at point: CGPoint) {
        zoom(by: 1 + magnification, around: point)
    }

    /// Zoom con rebote suave para los saltos (botones, Z, Ajustar); el pellizco y ⌘+scroll van directos.
    private let zoomSpring = Animation.spring(duration: 0.38, bounce: 0.22)

    private func zoom(by factor: Double, around pivot: CGPoint, animated: Bool = false) {
        let old = camera.scale
        let new = min(4, max(0.15, old * factor))
        guard new != old else { return }
        // Mantiene fijo el punto bajo el cursor.
        let world = CGPoint(x: (pivot.x - camera.x) / old, y: (pivot.y - camera.y) / old)
        withAnimation(animated ? zoomSpring : nil) {
            store.mutateBoard {
                $0.camera.scale = new
                $0.camera.x = pivot.x - world.x * new
                $0.camera.y = pivot.y - world.y * new
            }
        }
    }

    private func mouseInViewport() -> CGPoint {
        CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    }

    private func setZoom(_ value: Double) {
        zoom(by: value / camera.scale, around: mouseInViewport(), animated: true)
    }

    /// Encuadre al abrir un tablero: la esquina superior izquierda del contenido queda a
    /// `openMargin` del borde, con el zoom que permita ver casi todo (nunca más de 100 %).
    private let openMargin: Double = 100

    private func frameOpenedBoard() {
        guard let id = store.boardToFrame, id == board?.id,
              viewportSize.width > 0, viewportSize.height > 0 else { return }
        store.boardToFrame = nil
        guard let items = board?.items, !items.isEmpty else {
            store.mutateBoard { $0.camera = Camera(x: openMargin, y: openMargin, scale: 1) }
            return
        }
        let bounds = items.dropFirst().reduce(items[0].frameRect) { $0.union($1.frameRect) }
        let sx = (viewportSize.width - openMargin * 2) / max(bounds.width, 1)
        let sy = (viewportSize.height - openMargin * 2) / max(bounds.height, 1)
        let s = min(1, max(0.15, min(sx, sy)))
        store.mutateBoard {
            $0.camera = Camera(x: openMargin - bounds.minX * s, y: openMargin - bounds.minY * s, scale: s)
        }
    }

    private func fitToContent() {
        guard let items = board?.items, !items.isEmpty else { return }
        let bounds = items.dropFirst().reduce(items[0].frameRect) { $0.union($1.frameRect) }
        let pad: Double = 80
        let sx = (viewportSize.width - pad * 2) / max(bounds.width, 1)
        let sy = (viewportSize.height - pad * 2) / max(bounds.height, 1)
        let s = min(4, max(0.15, min(sx, sy)))
        withAnimation(zoomSpring) {
            store.mutateBoard {
                $0.camera.scale = s
                $0.camera.x = viewportSize.width / 2 - bounds.midX * s
                $0.camera.y = viewportSize.height / 2 - bounds.midY * s
            }
        }
    }

    // MARK: - Barras

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        TabsToolbarItem(width: tabsWidth)
        ToolbarItemGroup {
            Button { store.importWithPanel(at: viewportCenterInWorld) } label: {
                Label("Imagen", systemImage: "photo")
            }
            .help("Agregar imágenes")
            Button { store.importWithPanel(at: viewportCenterInWorld, kind: .frame) } label: {
                Label("Viñeta", systemImage: "rectangle.on.rectangle")
            }
            .help("Agregar viñeta de storyboard")
            Spacer()
            Button { setZoom(camera.scale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Alejar")
            Button { setZoom(1) } label: {
                Text("\(Int(camera.scale * 100))%").monospacedDigit().lineLimit(1).frame(width: 46)
            }
            .help("Zoom al 100 % (Z alterna)")
            Button { setZoom(camera.scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Acercar")
            Button { fitToContent() } label: { Label("Ajustar", systemImage: "arrow.up.left.and.arrow.down.right") }
                .help("Encuadrar todo el contenido")
            Button { if let board { PDFExporter.export(board) } } label: {
                Label("Exportar PDF", systemImage: "arrow.down.doc")
            }
            .help("Exportar el tablero a PDF")
            .disabled(board?.items.isEmpty ?? true)
        }
    }
}

/// Retícula de puntos que se mueve y escala con la cámara.
struct DotGrid: View, Animatable {
    var camera: Camera

    // Para que la retícula acompañe al contenido durante el zoom animado.
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(camera.x, camera.y), camera.scale) }
        set {
            camera.x = newValue.first.first
            camera.y = newValue.first.second
            camera.scale = newValue.second
        }
    }

    var body: some View {
        Canvas { context, size in
            let step = 24 * camera.scale
            guard step > 6 else { return }
            let color = Color.primary.opacity(0.13)
            var y = camera.y.truncatingRemainder(dividingBy: step)
            if y > 0 { y -= step }
            while y < size.height {
                var x = camera.x.truncatingRemainder(dividingBy: step)
                if x > 0 { x -= step }
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(color))
                    x += step
                }
                y += step
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// Hacia dónde crece la pieza al arrastrar esta esquina.
    var sx: Double { self == .topLeft || self == .bottomLeft ? -1 : 1 }
    var sy: Double { self == .topLeft || self == .topRight ? -1 : 1 }

    var alignment: Alignment {
        switch self {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    /// Nuevo marco con el tamaño dado, manteniendo fija la esquina opuesta.
    func rect(from base: CGRect, size: CGSize) -> CGRect {
        CGRect(x: sx > 0 ? base.minX : base.maxX - size.width,
               y: sy > 0 ? base.minY : base.maxY - size.height,
               width: size.width, height: size.height)
    }

    @available(macOS 15.0, *)
    var framePosition: FrameResizePosition {
        switch self {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}

/// Zona invisible de agarre en cada esquina: sólo el cursor indica que se puede redimensionar.
struct ResizeHandle: View {
    let corner: Corner
    let scale: Double

    private let hitSize: Double = 18

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: hitSize, height: hitSize)
        .modifier(ResizeCursor(corner: corner))
        .scaleEffect(1 / scale)
        .frame(width: hitSize / scale, height: hitSize / scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
        .offset(x: corner.sx * hitSize / scale / 2, y: corner.sy * hitSize / scale / 2)
    }
}

/// Cursor de redimensionar diagonal (macOS 15+); en macOS 14 usa la cruz.
private struct ResizeCursor: ViewModifier {
    let corner: Corner

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.frameResize(position: corner.framePosition))
        } else {
            content.onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
        }
    }
}
