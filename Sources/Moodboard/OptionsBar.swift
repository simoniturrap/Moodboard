import SwiftUI
import AppKit

/// Barra de opciones del elemento seleccionado; ocupa el lugar de la paleta de herramientas.
/// Texto y notas: Tamaño, Fuente y Color. Viñetas: Color. Siempre: capas, duplicar y eliminar.
struct OptionsBar: View {
    @EnvironmentObject var store: Store
    @State private var showFontPicker = false

    private var items: [BoardItem] {
        (store.activeBoard?.items ?? []).filter { store.selection.contains($0.id) }
    }
    private var typographic: [BoardItem] { items.filter { $0.kind.hasTypography } }
    private var colorable: [BoardItem] { items.filter { $0.kind != .image } }

    /// Si todo lo coloreable es texto sin fondo, se ofrecen colores de letra; si no, de papel.
    private var usesTextColors: Bool { colorable.allSatisfy { $0.kind == .text } }

    private var currentSize: Double? {
        let sizes = Set(typographic.map(\.resolvedFontSize))
        return sizes.count == 1 ? sizes.first : nil
    }

    private var currentColorHex: String? {
        guard let first = colorable.first else { return nil }
        return first.kind == .text ? first.textColorHex : first.colorHex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !typographic.isEmpty {
                section("Tamaño") { sizeOptions }
                section("Fuente") { fontButton }
            }
            if !colorable.isEmpty {
                section("Color") { colorOptions }
            }
            actions
        }
        .padding(12)
        .frame(width: 184)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .animation(.spring(duration: 0.28, bounce: 0.15), value: typographic.isEmpty)
        .animation(.spring(duration: 0.28, bounce: 0.15), value: colorable.isEmpty)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Tamaño

    private var sizeOptions: some View {
        VStack(spacing: 2) {
            ForEach(TextStyle.allCases, id: \.self) { style in
                let active = currentSize == style.size
                Button { store.applyFont(family: nil, size: style.size, keepFamily: true) } label: {
                    HStack {
                        Text(style.title)
                            .font(.system(size: style == .title ? 15 : style == .subtitle ? 13 : 11,
                                          weight: style == .body ? .regular : .semibold))
                        Spacer()
                        Text("\(Int(style.size)) px")
                            .font(.caption2)
                            .foregroundStyle(active ? Color.white.opacity(0.85) : Color.secondary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .foregroundStyle(active ? Color.white : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Fuente

    private var fontButton: some View {
        let family = typographic.first?.fontFamily
        let preview = family.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 13) }
            ?? .systemFont(ofSize: 13)
        return Button { showFontPicker.toggle() } label: {
            HStack {
                Text(family ?? "Sistema")
                    .font(Font(preview as CTFont))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showFontPicker, arrowEdge: .leading) {
            FontPicker(current: family)
                .environmentObject(store)
        }
    }

    // MARK: - Color

    private var colorOptions: some View {
        let palette = usesTextColors ? Palette.textColors : Palette.colors
        // Todo en vistas SwiftUI planas (sin LazyVGrid ni ColorPicker nativo) para que
        // el bloque entre con la misma animación que el resto de la barra.
        let rows = stride(from: 0, to: palette.count, by: 5).map { Array(palette[$0..<min($0 + 5, palette.count)]) }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { swatch($0) }
                }
            }
            Button(action: openColorPanel) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                              center: .center))
                        .frame(width: 20, height: 20)
                    Text("Personalizado").font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Abrir el selector de color del sistema")
        }
    }

    private func swatch(_ hex: String) -> some View {
        let active = currentColorHex?.uppercased() == hex
        return Button { store.applyColorToSelection(hex) } label: {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 2).padding(-3).opacity(active ? 1 : 0))
        }
        .buttonStyle(.plain)
    }

    private func openColorPanel() {
        let initial = currentColorHex.map { NSColor(Color(hex: $0)) } ?? (usesTextColors ? .labelColor : .white)
        ColorPanelBridge.shared.open(initial: initial) { [store] color in
            store.applyColorToSelection(Color(nsColor: color).hexString, coalescing: true)
        }
    }

    // MARK: - Acciones

    private var actions: some View {
        HStack(spacing: 0) {
            action("square.3.layers.3d.top.filled", "Al frente") { store.bringSelectionToFront() }
            action("square.3.layers.3d.bottom.filled", "Atrás") { store.sendSelectionToBack() }
            action("plus.square.on.square", "Duplicar (⌘D)") { store.duplicateSelection() }
            action("trash", "Eliminar (⌫)") { store.deleteSelection() }
        }
        .padding(.top, 2)
    }

    private func action(_ icon: String, _ help: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: icon)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension Color {
    /// "RRGGBB" en sRGB, para guardar colores elegidos con el selector del sistema.
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

/// Conecta el panel de color del sistema con la selección, sin usar la vista nativa ColorPicker.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((NSColor) -> Void)?

    func open(initial: NSColor, onChange: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)          // que fijar el color inicial no dispare un cambio
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = initial
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}
