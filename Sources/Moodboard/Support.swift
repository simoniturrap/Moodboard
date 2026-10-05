import AppKit
import SwiftUI

/// Caché de imágenes para no releer del disco en cada redibujado.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(named file: String) -> NSImage? {
        if let hit = cache.object(forKey: file as NSString) { return hit }
        let url = Store.mediaDir.appendingPathComponent(file)
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache.setObject(img, forKey: file as NSString)
        return img
    }
}

/// Escucha rueda del trackpad/mouse y pellizco sobre una zona concreta de la ventana.
/// SwiftUI no expone estos eventos, así que se toman del monitor local de NSEvent.
struct WheelZoomCatcher: NSViewRepresentable {
    var onScroll: (CGVector, Bool) -> Void      // (delta, esZoom)
    var onMagnify: (CGFloat, CGPoint) -> Void   // (factor, punto en la vista)
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
        var onScroll: ((CGVector, Bool) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?

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
                    self.onScroll?(CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY), zooming)
                    return nil
                case .magnify:
                    self.onMagnify?(event.magnification, local)
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
