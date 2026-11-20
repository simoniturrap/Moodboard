import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Exporta un tablero completo a un PDF de una página, encuadrado a su contenido.
@MainActor
enum PDFExporter {
    private static let padding: Double = 48

    static func export(_ board: Board) {
        guard !board.items.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = board.name + ".pdf"
        panel.prompt = "Exportar"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let renderer = ImageRenderer(content: page(for: board))
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            pdf.beginPDFPage(nil)
            draw(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// El PDF va sobre fondo blanco: el texto blanco (o casi) pasa a negro para que se lea.
    private static func printable(_ item: BoardItem) -> BoardItem {
        guard item.kind == .text, let hex = item.textColorHex, isNearWhite(hex) else { return item }
        var copy = item
        copy.textColorHex = "000000"
        return copy
    }

    private static func isNearWhite(_ hex: String) -> Bool {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF), g = Double((value >> 8) & 0xFF), b = Double(value & 0xFF)
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 > 0.9
    }

    /// El tablero dibujado sin cámara ni selección, con fondo claro.
    private static func page(for board: Board) -> some View {
        // Las piezas dentro de una columna las dibuja la columna, no el lienzo. Los videos no se imprimen.
        let claimed = Set(board.items.flatMap { $0.children ?? [] })
        let items = board.items
            .filter { !claimed.contains($0.id) && $0.kind != .video }
            .sorted { $0.z < $1.z }.map(printable)
        let bounds = items.first.map { first in
            items.dropFirst().reduce(first.frameRect) { $0.union($1.frameRect) }
        } ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                ItemView(item: item, scale: 1, isSelected: false, isEditing: false,
                         onTextChange: { _ in }, onEndEditing: {}, siblings: board.items,
                         fullResolution: true)
                    .frame(width: item.w, height: item.h)
                    .offset(x: item.x - bounds.minX + padding, y: item.y - bounds.minY + padding)
            }
        }
        .frame(width: bounds.width + padding * 2, height: bounds.height + padding * 2, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}
