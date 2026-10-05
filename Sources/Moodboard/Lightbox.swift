import SwiftUI
import AppKit

/// Foto a pantalla completa (doble clic) con la herramienta de recorte abajo.
/// Esc o clic fuera cancela; ↩ o «Aplicar» guarda el recorte.
struct Lightbox: View {
    @EnvironmentObject var store: Store
    let item: BoardItem

    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var ratio: CropRatio = .free

    private var image: NSImage? { item.media.flatMap { ImageCache.shared.image(named: $0) } }

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            if let image {
                VStack(spacing: 20) {
                    GeometryReader { geo in
                        let display = fitSize(image.size, in: geo.size)
                        CropCanvas(image: image, displaySize: display, crop: $crop, ratio: ratio.value(for: image.size))
                            .frame(width: display.width, height: display.height)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                    cropBar(imageSize: image.size)
                }
                .padding(.horizontal, 40)
                .padding(.top, 40)
                .padding(.bottom, 24)
            }
        }
        .onAppear { crop = item.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1) }
    }

    private func fitSize(_ size: CGSize, in area: CGSize) -> CGSize {
        let s = min(area.width / max(size.width, 1), area.height / max(size.height, 1))
        return CGSize(width: size.width * s, height: size.height * s)
    }

    // MARK: - Barra de recorte

    private func cropBar(imageSize: CGSize) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "crop").foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(CropRatio.allCases, id: \.self) { option in
                    let active = option == ratio
                    Button {
                        ratio = option
                        if let r = option.value(for: imageSize) {
                            withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                                crop = CropMath.fit(ratio: r, around: crop, imageSize: imageSize)
                            }
                        }
                    } label: {
                        Text(option.title)
                            .font(.system(size: 12, weight: active ? .semibold : .regular))
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .foregroundStyle(active ? Color.white : Color.primary)
                            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider().frame(height: 20)
            Button("Restablecer") {
                ratio = .free
                withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                    crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                }
            }
            Button("Cancelar", action: close)
                .keyboardShortcut(.cancelAction)
            Button("Aplicar") {
                store.applyCrop(item.id, crop)
                close()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private func close() {
        withAnimation(.spring(duration: 0.3, bounce: 0.12)) { store.lightboxItem = nil }
    }
}

/// Proporciones de recorte disponibles.
enum CropRatio: CaseIterable {
    case free, original, square, portrait45, portrait34, landscape32, wide169

    var title: String {
        switch self {
        case .free: "Libre"
        case .original: "Original"
        case .square: "1:1"
        case .portrait45: "4:5"
        case .portrait34: "3:4"
        case .landscape32: "3:2"
        case .wide169: "16:9"
        }
    }

    /// Ancho / alto en píxeles; nil = libre.
    func value(for image: CGSize) -> Double? {
        switch self {
        case .free: nil
        case .original: image.width / max(image.height, 1)
        case .square: 1
        case .portrait45: 4.0 / 5
        case .portrait34: 3.0 / 4
        case .landscape32: 3.0 / 2
        case .wide169: 16.0 / 9
        }
    }
}

/// Cálculos del recorte en coordenadas normalizadas (0…1) de la imagen.
enum CropMath {
    static let minSize: Double = 0.05

    /// Alto normalizado que corresponde a un ancho normalizado con la proporción dada.
    static func height(forWidth w: Double, ratio: Double, imageSize: CGSize) -> Double {
        w * imageSize.width / (ratio * max(imageSize.height, 1))
    }

    /// El mayor recorte con esa proporción que cabe en la imagen, centrado donde estaba el actual.
    static func fit(ratio: Double, around current: CGRect, imageSize: CGSize) -> CGRect {
        var w = 1.0
        var h = height(forWidth: w, ratio: ratio, imageSize: imageSize)
        if h > 1 { w /= h; h = 1 }
        let x = min(max(current.midX - w / 2, 0), 1 - w)
        let y = min(max(current.midY - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// La imagen con el marco de recorte encima: se arrastra por dentro para moverlo
/// y por esquinas (y lados, en modo libre) para cambiar su tamaño.
private struct CropCanvas: View {
    let image: NSImage
    let displaySize: CGSize
    @Binding var crop: CGRect
    let ratio: Double?

    @State private var dragStart: CGRect?

    private var frame: CGRect {
        CGRect(x: crop.minX * displaySize.width, y: crop.minY * displaySize.height,
               width: crop.width * displaySize.width, height: crop.height * displaySize.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: image)
                .resizable()
                .frame(width: displaySize.width, height: displaySize.height)

            // Oscurece lo que queda fuera del recorte.
            Path { p in
                p.addRect(CGRect(origin: .zero, size: displaySize))
                p.addRect(frame)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // Marco con tercios; arrastrar por dentro lo mueve.
            ZStack {
                Rectangle().stroke(.white, lineWidth: 1)
                thirds.stroke(.white.opacity(0.35), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .gesture(drag(sx: 0, sy: 0, moving: true))

            ForEach(handles, id: \.self) { h in
                handle(h)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height, alignment: .topLeading)
    }

    private var thirds: Path {
        Path { p in
            for i in 1...2 {
                let x = frame.width * Double(i) / 3, y = frame.height * Double(i) / 3
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: frame.height))
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: frame.width, y: y))
            }
        }
    }

    // MARK: - Tiradores

    private struct Handle: Hashable { let sx: Int; let sy: Int }

    /// Esquinas siempre; lados sólo con proporción libre.
    private var handles: [Handle] {
        var list = [Handle(sx: -1, sy: -1), Handle(sx: 1, sy: -1), Handle(sx: -1, sy: 1), Handle(sx: 1, sy: 1)]
        if ratio == nil {
            list += [Handle(sx: 0, sy: -1), Handle(sx: 0, sy: 1), Handle(sx: -1, sy: 0), Handle(sx: 1, sy: 0)]
        }
        return list
    }

    private func handle(_ h: Handle) -> some View {
        let isCorner = h.sx != 0 && h.sy != 0
        let x = frame.minX + frame.width * Double(h.sx + 1) / 2
        let y = frame.minY + frame.height * Double(h.sy + 1) / 2
        return ZStack {
            Color.clear.contentShape(Rectangle())
            if isCorner {
                // Escuadra blanca en la esquina.
                Path { p in
                    let l = 14.0
                    p.move(to: CGPoint(x: 0, y: l)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: l, y: 0))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))
                .frame(width: 14, height: 14)
                .scaleEffect(x: Double(-h.sx), y: Double(-h.sy))
                .offset(x: Double(h.sx) * -5, y: Double(h.sy) * -5)
            } else {
                Capsule().fill(.white)
                    .frame(width: h.sx == 0 ? 22 : 4, height: h.sx == 0 ? 4 : 22)
            }
        }
        .frame(width: 30, height: 30)
        .position(x: x, y: y)
        .gesture(drag(sx: h.sx, sy: h.sy, moving: false))
    }

    // MARK: - Arrastre

    private func drag(sx: Int, sy: Int, moving: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = crop }
                guard let start = dragStart else { return }
                let dx = value.translation.width / displaySize.width
                let dy = value.translation.height / displaySize.height
                crop = moving ? moved(start, dx, dy) : resized(start, dx, dy, sx: sx, sy: sy)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func moved(_ r: CGRect, _ dx: Double, _ dy: Double) -> CGRect {
        CGRect(x: min(max(r.minX + dx, 0), 1 - r.width),
               y: min(max(r.minY + dy, 0), 1 - r.height),
               width: r.width, height: r.height)
    }

    private func resized(_ r: CGRect, _ dx: Double, _ dy: Double, sx: Int, sy: Int) -> CGRect {
        let minS = CropMath.minSize
        var left = r.minX, right = r.maxX, top = r.minY, bottom = r.maxY
        if sx < 0 { left = min(max(r.minX + dx, 0), right - minS) }
        if sx > 0 { right = max(min(r.maxX + dx, 1), left + minS) }
        if sy < 0 { top = min(max(r.minY + dy, 0), bottom - minS) }
        if sy > 0 { bottom = max(min(r.maxY + dy, 1), top + minS) }

        guard let ratio else {
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
        // Con proporción fija: manda el ancho y la esquina opuesta queda anclada.
        let size = image.size
        var w = right - left
        var h = CropMath.height(forWidth: w, ratio: ratio, imageSize: size)
        let anchorX = sx < 0 ? r.maxX : r.minX
        let anchorY = sy < 0 ? r.maxY : r.minY
        let maxW = sx < 0 ? anchorX : 1 - anchorX
        let maxH = sy < 0 ? anchorY : 1 - anchorY
        if h > maxH { w *= maxH / h; h = maxH }
        if w > maxW { h *= maxW / w; w = maxW }
        return CGRect(x: sx < 0 ? anchorX - w : anchorX,
                      y: sy < 0 ? anchorY - h : anchorY,
                      width: w, height: h)
    }
}
