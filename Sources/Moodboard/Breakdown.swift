import SwiftUI

// MARK: - Construcción del desglose

/// Desglose de una escena, ya resuelto (detección + decisiones del usuario) y listo para mostrar.
struct SceneBreakdown: Identifiable {
    let id: UUID
    let number: Int
    let heading: String
    let place: String
    let synopsis: String
    var byDept: [Department: [String]]
    var unclassified: [String]
}

enum BreakdownBuilder {
    /// Parte el guion en escenas y resuelve el desglose de cada una.
    static func scenes(_ lines: [ScriptLine], _ details: [String: SceneDetail]) -> [SceneBreakdown] {
        var result: [SceneBreakdown] = []
        var cur: (id: UUID, heading: String, cues: [String], action: [String])?
        func flush() {
            guard let c = cur else { return }
            let detail = details[c.id.uuidString] ?? SceneDetail()
            result.append(build(id: c.id, number: result.count + 1, heading: c.heading,
                                cues: c.cues, action: c.action.joined(separator: " "), detail: detail))
        }
        for line in lines {
            if line.type == .scene {
                flush()
                cur = (line.id, line.text, [], [])
            } else if cur != nil {
                if line.type == .character {
                    let n = ScriptIndex.characterName(line.text)
                    if !n.isEmpty { cur!.cues.append(n) }
                } else if line.type == .action {
                    cur!.action.append(line.text)
                }
            }
        }
        flush()
        return result
    }

    private static func build(id: UUID, number: Int, heading: String,
                              cues: [String], action: String, detail: SceneDetail) -> SceneBreakdown {
        let place = ScriptIndex.placeName(heading)
        let removed = Set(detail.removed)
        var exclude = Set<String>()
        for c in cues { for w in c.lowercased().split(whereSeparator: { !$0.isLetter }) { exclude.insert(String(w)) } }
        for w in place.lowercased().split(whereSeparator: { !$0.isLetter }) { exclude.insert(String(w)) }

        var byDept: [Department: [String]] = [:]
        func append(_ dept: Department, _ display: String) {
            var list = byDept[dept] ?? []
            if !list.contains(where: { $0.caseInsensitiveCompare(display) == .orderedSame }) { list.append(display) }
            byDept[dept] = list
        }

        var castSeen = Set<String>()
        for c in cues where !removed.contains(c.lowercased()) {
            if castSeen.insert(c.lowercased()).inserted { append(.cast, c.capitalized) }
        }

        var unclassified: [String] = []
        for noun in ScriptProps.detect(in: action) where !removed.contains(noun) && !exclude.contains(noun) {
            if let raw = detail.assigned[noun], let d = Department(rawValue: raw) { append(d, noun.capitalized) }
            else if let d = ScriptProps.classify(noun) { append(d, noun.capitalized) }
            else { unclassified.append(noun.capitalized) }
        }

        for (raw, items) in detail.added {
            guard let d = Department(rawValue: raw) else { continue }
            for it in items where !removed.contains(it.lowercased()) { append(d, it) }
        }

        return SceneBreakdown(id: id, number: number, heading: heading, place: place,
                              synopsis: detail.synopsis, byDept: byDept, unclassified: unclassified)
    }

    /// Agregado de todas las escenas, para la vista «Total».
    static func total(_ scenes: [SceneBreakdown]) -> (byDept: [Department: [String]], unclassified: [String]) {
        var byDept: [Department: [String]] = [:]
        var unclassified: [String] = []
        func merge(_ dept: Department, _ items: [String]) {
            var list = byDept[dept] ?? []
            for it in items where !list.contains(where: { $0.caseInsensitiveCompare(it) == .orderedSame }) { list.append(it) }
            byDept[dept] = list
        }
        for s in scenes {
            for (d, items) in s.byDept { merge(d, items) }
            for u in s.unclassified where !unclassified.contains(where: { $0.caseInsensitiveCompare(u) == .orderedSame }) {
                unclassified.append(u)
            }
        }
        return (byDept, unclassified)
    }
}

// MARK: - Disposición en flujo (tags que saltan de línea)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - Panel de desglose

/// Panel lateral del guion: selector de escena (o Total), ficha descriptiva y los departamentos del
/// desglose como tags, con detección automática, asignación de lo «sin clasificar» y añadido manual.
struct BreakdownPanel: View {
    @EnvironmentObject var store: Store
    let onJump: (UUID) -> Void

    @State private var selected: UUID?
    @State private var adding: Department?
    @State private var draft = ""
    @FocusState private var addFocused: Bool

    private var scenes: [SceneBreakdown] {
        BreakdownBuilder.scenes(store.scriptLines, store.activeBoard?.sceneDetails ?? [:])
    }
    private var selectedScene: SceneBreakdown? { scenes.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            scenePicker
            Divider()
            if scenes.isEmpty {
                Text("Escribe una escena para empezar el desglose.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let scene = selectedScene {
                            sceneBody(scene)
                        } else {
                            totalBody
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 420)
            }
        }
        .padding(12)
        .frame(width: 248)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    // MARK: Selector de escena

    private var scenePicker: some View {
        Menu {
            Button("Total (todas las escenas)") { selected = nil }
            Divider()
            ForEach(scenes) { s in
                Button("\(s.number). \(s.heading)") {
                    selected = s.id
                    onJump(s.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle").font(.caption)
                Text(selectedScene.map { "\($0.number). \($0.heading)" } ?? "Total")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    // MARK: Cuerpo de una escena

    @ViewBuilder
    private func sceneBody(_ scene: SceneBreakdown) -> some View {
        if !scene.place.isEmpty {
            Label(scene.place, systemImage: "mappin.and.ellipse")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        TextField("Ficha descriptiva…", text: Binding(
            get: { scene.synopsis },
            set: { store.setSceneSynopsis(scene.id, $0) }), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .lineLimit(2...6)
            .padding(8)
            .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

        ForEach(Department.allCases) { dept in
            deptGroup(dept, items: scene.byDept[dept] ?? [], scene: scene.id, editable: true)
        }
        if !scene.unclassified.isEmpty {
            unclassifiedGroup(scene.unclassified, scene: scene.id)
        }
    }

    // MARK: Cuerpo del total

    @ViewBuilder
    private var totalBody: some View {
        let total = BreakdownBuilder.total(scenes)
        ForEach(Department.allCases) { dept in
            deptGroup(dept, items: total.byDept[dept] ?? [], scene: nil, editable: false)
        }
        if !total.unclassified.isEmpty {
            groupHeader("Sin clasificar", icon: "questionmark.circle", count: total.unclassified.count)
            FlowLayout(spacing: 6) {
                ForEach(total.unclassified, id: \.self) { TagChip(text: $0) }
            }
        }
    }

    // MARK: Grupos y tags

    private func groupHeader(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(title).font(.caption.weight(.semibold))
            if count > 0 { Text("\(count)").font(.caption2).foregroundStyle(.tertiary) }
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func deptGroup(_ dept: Department, items: [String], scene: UUID?, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            groupHeader(dept.title, icon: dept.icon, count: items.count)
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    TagChip(text: item, onRemove: editable && scene != nil
                            ? { store.removeBreakdownItem(scene!, dept, item) } : nil)
                }
                if editable, let scene {
                    addControl(dept, scene: scene)
                }
            }
        }
    }

    @ViewBuilder
    private func addControl(_ dept: Department, scene: UUID) -> some View {
        if adding == dept {
            TextField("añadir…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(width: 80)
                .focused($addFocused)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(.background))
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.5)))
                .onSubmit {
                    store.addBreakdownItem(scene, dept, draft)
                    draft = ""
                    addFocused = true   // permite encadenar varios
                }
                .onExitCommand { adding = nil; draft = "" }
        } else {
            Button {
                adding = dept
                draft = ""
                addFocused = true
            } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Capsule().fill(.primary.opacity(0.06)))
                    .overlay(Capsule().stroke(.primary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("Añadir a \(dept.title)")
        }
    }

    @ViewBuilder
    private func unclassifiedGroup(_ items: [String], scene: UUID) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            groupHeader("Sin clasificar", icon: "questionmark.circle", count: items.count)
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Menu {
                        ForEach(Department.allCases) { dept in
                            Button {
                                store.assignBreakdownItem(scene, item, to: dept)
                            } label: { Label(dept.title, systemImage: dept.icon) }
                        }
                        Divider()
                        Button("Descartar", role: .destructive) {
                            store.removeBreakdownItem(scene, .props, item)
                        }
                    } label: {
                        TagChip(text: item, trailingIcon: "arrow.right.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Badge de un ítem del desglose. Opcionalmente con «x» para quitar (al pasar el ratón) o un icono guía.
private struct TagChip: View {
    let text: String
    var onRemove: (() -> Void)? = nil
    var trailingIcon: String? = nil
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
            if let trailingIcon {
                Image(systemName: trailingIcon).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if let onRemove, hover {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(.primary.opacity(0.07)))
        .overlay(Capsule().stroke(.primary.opacity(0.1)))
        .onHover { hover = $0 }
    }
}
