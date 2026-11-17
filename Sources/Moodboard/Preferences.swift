import SwiftUI

/// Apariencia elegida por la persona: seguir el sistema, o forzar claro u oscuro.
enum ThemePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Sistema"
        case .light:  return "Claro"
        case .dark:   return "Oscuro"
        }
    }

    /// `nil` deja que mande el sistema; el resto fuerza el esquema.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// Clave de `@AppStorage` compartida para la preferencia de tema.
let themePreferenceKey = "appearance.theme"

/// Panel de Preferencias (Moodboard ▸ Preferencias…, ⌘,).
struct PreferencesView: View {
    @AppStorage(themePreferenceKey) private var theme = ThemePreference.system.rawValue

    private var selection: Binding<ThemePreference> {
        Binding(
            get: { ThemePreference(rawValue: theme) ?? .system },
            set: { theme = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Picker("Tema", selection: selection) {
                ForEach(ThemePreference.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .frame(width: 380)
    }
}
