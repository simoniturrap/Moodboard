import AppKit
import SwiftUI
import ImageIO

/// Caché de imágenes para no releer del disco en cada redibujado.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, NSImage>()
    /// Archivos que ya se han pedido al servidor, para no lanzar descargas repetidas en cada redibujado.
    private var requested = Set<String>()

    init() {
        // Tope de memoria para bitmaps decodificados: por encima, NSCache desaloja los menos usados.
        cache.totalCostLimit = 300 * 1024 * 1024
    }

    /// Imagen a resolución completa: lightbox, recorte y portapapeles, que sí necesitan el original.
    /// Cara en memoria (un bitmap puede ocupar decenas o cientos de MB); para dibujar en el lienzo usa
    /// `thumbnail(named:maxPixel:)`.
    func image(named file: String) -> NSImage? {
        let key = file as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = Store.mediaDir.appendingPathComponent(file)
        if let img = NSImage(contentsOf: url) {
            cache.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height) * 4)
            return img
        }
        // No está en disco: si hay sincronización, intenta bajarla y avisa para redibujar al terminar.
        requestDownload(file)
        return nil
    }

    /// Miniatura decodificada al tamaño en que se va a mostrar. Evita cargar en memoria el bitmap
    /// completo (las fotos del tablero rondan 1440–10000 px pero se ven a ~240 pt): ImageIO decodifica
    /// directamente a la resolución pedida, sin pasar nunca por el original entero. Se cachea por
    /// escalón de tamaño, así el zoom sólo vuelve a decodificar al cruzar un escalón, no en cada frame.
    func thumbnail(named file: String, maxPixel: Int) -> NSImage? {
        let bucket = Self.bucket(for: maxPixel)
        let key = "\(file)@\(bucket)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = Store.mediaDir.appendingPathComponent(file)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            requestDownload(file)
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // respeta la orientación EXIF
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: bucket,         // no amplía: topa en el tamaño nativo
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key, cost: cg.bytesPerRow * cg.height)
        return img
    }

    /// Escalones del lado mayor (px) de las miniaturas. Pocos a propósito: así el zoom continuo apenas
    /// cruza un par de escalones en todo su recorrido. 2048 cubre el zoom máximo (240 pt · 4× · 2 retina).
    private static func bucket(for maxPixel: Int) -> Int {
        let steps = [256, 512, 1024, 2048]
        return steps.first { maxPixel <= $0 } ?? steps.last!
    }

    private func requestDownload(_ file: String) {
        guard !requested.contains(file) else { return }
        requested.insert(file)
        Task { @MainActor in
            guard SyncConfig.isConfigured else { return }
            await SyncService.shared.downloadMedia(file)
        }
    }
}

/// Fase de un gesto de desplazamiento, para saber cuándo asentar el lienzo sin temblores.
/// `active`: dedo o inercia en marcha. `ended`: terminó el gesto (y su inercia). `legacy`: rueda
/// clásica de ratón, que no reporta fase (se asienta por tiempo).
enum ScrollMomentum { case active, ended, legacy }

/// Escucha rueda del trackpad/mouse y pellizco sobre una zona concreta de la ventana.
/// SwiftUI no expone estos eventos, así que se toman del monitor local de NSEvent.
struct WheelZoomCatcher: NSViewRepresentable {
    var onScroll: (CGVector, Bool, ScrollMomentum) -> Void   // (delta, esZoom, fase)
    var onMagnify: (CGFloat, CGPoint, ScrollMomentum) -> Void   // (factor, punto, fase)
    /// true: el scroll normal sigue a la vista de abajo (p. ej. un ScrollView); sólo ⌘/⌃ + scroll hace zoom.
    var passesPlainScroll = false

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        v.onMagnify = onMagnify
        v.passesPlainScroll = passesPlainScroll
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onMagnify = onMagnify
        nsView.passesPlainScroll = passesPlainScroll
    }

    final class CatcherView: NSView {
        var passesPlainScroll = false
        var onScroll: ((CGVector, Bool, ScrollMomentum) -> Void)?
        var onMagnify: ((CGFloat, CGPoint, ScrollMomentum) -> Void)?

        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil } // no roba clics a SwiftUI

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let local = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(local) else { return event }

                switch event.type {
                case .scrollWheel:
                    let zooming = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
                    if self.passesPlainScroll && !zooming { return event }
                    let phase: ScrollMomentum
                    if event.phase.isEmpty && event.momentumPhase.isEmpty {
                        phase = .legacy
                    } else if event.momentumPhase.contains(.ended)
                        || event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                        phase = .ended
                    } else {
                        phase = .active
                    }
                    self.onScroll?(CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY), zooming, phase)
                    return nil
                case .magnify:
                    let phase: ScrollMomentum = event.phase.contains(.ended) || event.phase.contains(.cancelled)
                        ? .ended : (event.phase.isEmpty ? .legacy : .active)
                    self.onMagnify?(event.magnification, local, phase)
                    return nil
                default:
                    return event
                }
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
        private var monitor: Any?
    }
}

/// Recibe teclas sueltas (pulsar y soltar) de la ventana mientras no se esté escribiendo en un campo de texto.
struct KeyCatcher: NSViewRepresentable {
    var onKey: (NSEvent) -> Bool   // true = tecla consumida
    /// false: también recibe las teclas mientras se escribe (lo usa el editor de guion).
    var ignoresTextEditing = true

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onKey = onKey
        v.ignoresTextEditing = ignoresTextEditing
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onKey = onKey
        nsView.ignoresTextEditing = ignoresTextEditing
    }

    final class CatcherView: NSView {
        var onKey: ((NSEvent) -> Bool)?
        var ignoresTextEditing = true
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !(self.ignoresTextEditing && window.firstResponder is NSText) else { return event }
                return self.onKey?(event) == true ? nil : event
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}

/// Mano abierta / cerrada mientras se desplaza el lienzo con espacio o H (macOS 15+).
struct HandCursor: ViewModifier {
    let grabbing: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(grabbing ? .grabActive : .grabIdle)
        } else {
            content
        }
    }
}

/// Punto del cursor dentro de una vista, útil para pegar donde mira el usuario.
extension NSView {
    var cursorPointInside: CGPoint? {
        guard let window else { return nil }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(local) ? local : nil
    }
}
