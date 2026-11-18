import SwiftUI
import Sparkle

/// Puente con Sparkle para buscar e instalar actualizaciones del `.app` empaquetado.
///
/// Sparkle sólo tiene sentido en la app distribuida: lee el feed (`SUFeedURL`) y la clave pública
/// (`SUPublicEDKey`) del Info.plist y valida cada update con una firma EdDSA propia (no necesita
/// certificado de Apple). En `swift run` no hay bundle ni esas claves, así que no se arranca el
/// updater: `canCheckForUpdates` queda en `false` y el ítem de menú, deshabilitado.
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    @Published var canCheckForUpdates = false

    init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
