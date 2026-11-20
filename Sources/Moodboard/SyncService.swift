import Foundation

/// Sincroniza la biblioteca con el Worker de Cloudflare (D1 + R2).
/// Local-first: nunca bloquea la app; empuja los cambios y baja lo que falte en segundo plano.
@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService()

    enum Status: Equatable {
        case disabled          // sin configurar
        case idle              // configurado, en reposo
        case syncing
        case upToDate
        case error(String)

        var label: String {
            switch self {
            case .disabled:  return "Desactivada"
            case .idle:      return "Lista"
            case .syncing:   return "Sincronizando…"
            case .upToDate:  return "Al día"
            case .error(let m): return "Error: \(m)"
            }
        }
    }

    /// Estado de subida de una imagen al servidor, para confirmarlo en la vista.
    /// `pausedQuota`: no se subió porque pasaría el tope de almacenamiento; se reintenta sola
    /// al liberar espacio.
    enum MediaUploadState: Equatable { case uploading, uploaded, failed, pausedQuota }

    /// Tope de almacenamiento que nos autoimponemos: por debajo de los 10 GB gratuitos de R2,
    /// con margen para no empezar a pagar sin querer. (R2 no lo impone; es decisión nuestra.)
    static let storageCap: Int64 = 9_500_000_000

    @Published private(set) var status: Status = .disabled
    /// Hay una sesión iniciada en este equipo (hay token guardado). Lo observa la pantalla de entrada.
    @Published private(set) var loggedIn: Bool = !SyncConfig.token.isEmpty
    /// Cambia cada vez que llega una imagen nueva, para que las vistas que la esperaban se redibujen.
    @Published private(set) var mediaTick = 0
    /// Subidas en curso o recién terminadas, por nombre de archivo (para la insignia sobre la foto).
    @Published private(set) var mediaUploads: [String: MediaUploadState] = [:]
    /// Almacenamiento usado en R2 (bytes) y si ya lo sabemos (para el indicador y el freno de cuota).
    @Published private(set) var usageBytes: Int64 = 0
    @Published private(set) var usageKnown = false

    /// Fracción del tope usada (0…1), para la barra del indicador.
    var usageFraction: Double { min(1, Double(usageBytes) / Double(Self.storageCap)) }
    /// Imágenes que no se subieron por falta de cuota, esperando a que se libere espacio.
    private var pausedUploads: Set<String> = []

    /// Store instala esto para adoptar un documento que llega del servidor.
    var applyRemoteLibrary: ((Library) -> Void)?
    /// Store instala esto para redibujar cuando llega una imagen nueva del servidor.
    var onMediaArrived: (() -> Void)?

    private var pushTask: Task<Void, Never>?
    /// Reintento de una subida que falló por red; se reprograma solo hasta que logre salir.
    private var retryTask: Task<Void, Never>?
    private let pushRetryDelay = 5.0
    /// Serialización de subidas: `isPushing` marca que hay una en curso; `pendingPush` es
    /// la versión más reciente esperando a que termine la actual.
    private var isPushing = false
    private var pendingPush: Library?
    /// Reintentos de "gana lo local" ante conflictos seguidos, con tope para no entrar en bucle
    /// si hay otro equipo editando a la vez.
    private var conflictRetries = 0
    private let maxConflictRetries = 3
    private var inFlightDownloads: Set<String> = []
    private var inFlightUploads: Set<String> = []
    private let pushDebounce = 1.0

    private init() {
        status = SyncConfig.isConfigured ? .idle : .disabled
    }

    func refreshEnabledState() {
        if !SyncConfig.isConfigured { status = .disabled }
        else if status == .disabled { status = .idle }
    }

    /// Inicia sesión contra el Worker: manda email+contraseña a `/login` y, si cuadran, guarda la URL,
    /// el email y el token devuelto (en el Keychain). La contraseña no se guarda. Devuelve `nil` si
    /// todo fue bien, o un mensaje de error listo para mostrar.
    func login(workerURL: String, email: String, password: String) async -> String? {
        let base = workerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: clean + "/login") else { return "La URL del servidor no es válida." }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return "El servidor no respondió." }
            if http.statusCode == 401 { return "Email o contraseña incorrectos." }
            guard http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = obj["token"] as? String, !token.isEmpty else {
                return "El servidor respondió con un error (\(http.statusCode))."
            }
            SyncConfig.workerURL = clean
            SyncConfig.email = email
            SyncConfig.token = token
            loggedIn = true
            refreshEnabledState()
            return nil
        } catch {
            return "No se pudo conectar: \(error.localizedDescription)"
        }
    }

    /// Da de alta la cuenta en el propio servidor (primera vez) y, si sale bien, inicia sesión.
    /// El `setupToken` es el secreto SYNC_TOKEN que se fijó al desplegar el Worker: autoriza el alta.
    /// Devuelve `nil` si todo fue bien, o un mensaje de error para mostrar.
    func register(workerURL: String, setupToken: String, email: String, password: String) async -> String? {
        let base = workerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = base.hasSuffix("/") ? String(base.dropLast()) : base
        let token = setupToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: clean + "/auth/setup") else { return "La URL del servidor no es válida." }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return "El servidor no respondió." }
            if http.statusCode == 401 { return "Token de configuración incorrecto." }
            guard http.statusCode == 200 else { return "El servidor respondió con un error (\(http.statusCode))." }
        } catch {
            return "No se pudo conectar: \(error.localizedDescription)"
        }
        // Cuenta creada: ahora inicia sesión para obtener y guardar el token de sync.
        return await login(workerURL: clean, email: email, password: password)
    }

    /// Cierra la sesión en este equipo: borra el token (y por tanto desactiva la sincronización).
    func signOut() {
        SyncConfig.token = ""
        loggedIn = false
        refreshEnabledState()
    }

    // MARK: - Tipos del protocolo HTTP

    private struct PutRequest: Encodable { let baseRevision: Int; let json: String }
    private struct PutResponse: Decodable { let revision: Int }
    private struct LibraryResponse: Decodable { let revision: Int; let json: String }
    private struct UsageResponse: Decodable { let count: Int; let bytes: Int64 }

    // MARK: - Utilidades de red

    private func makeRequest(_ path: String, method: String = "GET",
                             body: Data? = nil, contentType: String? = nil) -> URLRequest? {
        guard SyncConfig.isConfigured, let url = URL(string: SyncConfig.workerURL + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(SyncConfig.token)", forHTTPHeaderField: "Authorization")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        return req
    }

    private static func encode(_ library: Library) -> String? {
        guard let data = try? JSONEncoder().encode(library) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode(_ jsonString: String) -> Library? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Library.self, from: data)
    }

    // MARK: - Documento (push / pull)

    /// Empuja la biblioteca con un pequeño retraso (varios guardados seguidos = una sola subida).
    func schedulePush(_ library: Library) {
        guard SyncConfig.isConfigured else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.pushDebounce ?? 1.0))
            guard !Task.isCancelled else { return }
            await self?.pushNow(library)
        }
    }

    /// Empuja ya mismo, sin esperar el retraso. Para usar al cerrar/suspender la app: así los cambios
    /// salen de este equipo antes de apagarlo, en vez de quedarse esperando el debounce.
    func pushImmediately(_ library: Library) {
        guard SyncConfig.isConfigured else { return }
        pushTask?.cancel()
        retryTask?.cancel()
        Task { [weak self] in await self?.pushNow(library) }
    }

    /// Serializa las subidas: nunca hay dos a la vez. Si llega un cambio mientras se sube,
    /// se guarda como pendiente y se envía justo después, ya con la revisión actualizada.
    /// Así una subida no "pisa" a otra basándose en una revisión vieja (lo que antes hacía
    /// que el servidor rechazara por conflicto y los movimientos volvieran a su sitio anterior).
    func pushNow(_ library: Library) async {
        guard SyncConfig.isConfigured else { return }
        if isPushing { pendingPush = library; return }
        isPushing = true
        defer { isPushing = false }
        await performPush(library)
        while let next = pendingPush {
            pendingPush = nil
            await performPush(next)
        }
    }

    private func performPush(_ library: Library) async {
        guard let jsonString = Self.encode(library) else { return }
        status = .syncing
        let body = try? JSONEncoder().encode(PutRequest(baseRevision: SyncConfig.knownRevision, json: jsonString))
        guard let req = makeRequest("/library", method: "PUT", body: body, contentType: "application/json") else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                if let r = try? JSONDecoder().decode(PutResponse.self, from: data) {
                    SyncConfig.knownRevision = r.revision
                }
                conflictRetries = 0
                retryTask?.cancel()   // salió bien: cancela cualquier reintento en espera
                status = .upToDate
                await reconcile(referenced: Self.referencedMedia(library))
            case 409:
                handleConflict(data, local: library)
            default:
                status = .error("HTTP \(code)")
                scheduleRetry(library)
            }
        } catch {
            status = .error(error.localizedDescription)
            scheduleRetry(library)   // típico sin red: reintenta solo hasta que vuelva la conexión
        }
    }

    /// Reprograma una subida que falló (p. ej. sin red), para que acabe saliendo sin que el usuario
    /// tenga que hacer nada. La cola serializada evita que choque con una subida nueva.
    private func scheduleRetry(_ library: Library) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.pushRetryDelay ?? 5.0))
            guard !Task.isCancelled else { return }
            await self?.pushNow(library)
        }
    }

    /// Conflicto: el servidor tiene otra revisión. Reenviamos la **unión** de lo local y lo remoto,
    /// con la revisión ya corregida. Así un conflicto nunca pierde tableros de ninguno de los dos
    /// lados: ni lo que el usuario está editando, ni lo que el servidor tuviera y el disco no.
    /// (Antes "ganaba lo local" y descartaba por completo el remoto.) Guardamos el remoto por si
    /// acaso, con un tope de reintentos.
    private func handleConflict(_ data: Data, local: Library) {
        guard let remote = try? JSONDecoder().decode(LibraryResponse.self, from: data) else {
            status = .error("Conflicto sin resolver")
            return
        }
        // Respaldo del remoto que vamos a sobrescribir (red de seguridad).
        let name = "library.remote-conflict-\(Self.timestamp()).json"
        try? remote.json.data(using: .utf8)?.write(to: Store.root.appendingPathComponent(name))
        SyncConfig.knownRevision = remote.revision

        guard conflictRetries < maxConflictRetries else {
            conflictRetries = 0
            status = .error("Conflicto de sincronización")
            return
        }
        conflictRetries += 1
        // La cola serializada reenviará la unión con la revisión ya corregida.
        pendingPush = Self.decode(remote.json).map { local.merged(with: $0) } ?? local
    }

    private struct RevisionResponse: Decodable { let revision: Int }

    /// Sondeo barato: sólo el número de revisión del servidor, sin bajar el documento ni tocar el
    /// estado visible. El cliente lo compara con la revisión que conoce para decidir si vale la pena
    /// bajar el documento entero. nil si falla o no hay sesión.
    func pollRevision() async -> Int? {
        guard let req = makeRequest("/revision"),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(RevisionResponse.self, from: data) else { return nil }
        return r.revision
    }

    /// Baja el documento del servidor. Devuelve (biblioteca, revisión) o nil si no hay nada / error.
    func pull() async -> (library: Library, revision: Int)? {
        guard let req = makeRequest("/library") else { return nil }
        status = .syncing
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { status = .upToDate; return nil }   // servidor vacío
            guard code == 200,
                  let r = try? JSONDecoder().decode(LibraryResponse.self, from: data),
                  let library = Self.decode(r.json) else {
                status = .error("HTTP \(code)")
                return nil
            }
            status = .upToDate
            return (library, r.revision)
        } catch {
            status = .error(error.localizedDescription)
            return nil
        }
    }

    // MARK: - Media (R2)

    @discardableResult
    func downloadMedia(_ name: String) async -> Bool {
        guard SyncConfig.isConfigured, !inFlightDownloads.contains(name) else { return false }
        let dest = Store.mediaDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return true }
        inFlightDownloads.insert(name)
        defer { inFlightDownloads.remove(name) }
        guard let req = makeRequest("/media/\(name)"),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        try? data.write(to: dest)
        mediaTick &+= 1
        onMediaArrived?()
        return true
    }

    /// Sube una imagen si el servidor no la tiene ya (los nombres son UUID, así que basta el nombre).
    /// Con `tracked` se publica el progreso (subiendo / subida / error) para mostrarlo sobre la foto;
    /// las subidas de conciliación en segundo plano van sin rastrear para no parpadear en cada guardado.
    func uploadMedia(_ name: String, tracked: Bool = false) async {
        guard SyncConfig.isConfigured, !inFlightUploads.contains(name) else { return }
        let src = Store.mediaDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: src) else { return }

        // Freno de cuota: si subir esta imagen pasaría el tope, se deja pausada (local, sin subir).
        // Se reintentará sola cuando se libere espacio (ver `retryPausedIfRoom`). Solo frenamos si
        // ya conocemos el uso real; si aún no, dejamos pasar para no bloquear a ciegas.
        if usageKnown, usageBytes + Int64(data.count) > Self.storageCap {
            pausedUploads.insert(name)
            if tracked { mediaUploads[name] = .pausedQuota }
            return
        }

        inFlightUploads.insert(name)
        defer { inFlightUploads.remove(name) }
        if tracked { mediaUploads[name] = .uploading }
        // Una imagen recién agregada tiene un nombre UUID nuevo: no puede estar aún en el servidor,
        // así que nos saltamos el HEAD y vamos directo al PUT (un viaje de red menos).
        // La conciliación en segundo plano sí consulta primero para no resubir lo que ya existe.
        if !tracked,
           let head = makeRequest("/media/\(name)", method: "HEAD"),
           let (_, resp) = try? await URLSession.shared.data(for: head),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            return
        }
        guard let req = makeRequest("/media/\(name)", method: "PUT",
                                    body: data, contentType: "application/octet-stream") else {
            if tracked { mediaUploads[name] = .failed }
            return
        }
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            usageBytes += Int64(data.count)   // objeto nuevo en R2: suma al uso conocido
            if tracked { markUploaded(name) }
        } else if tracked {
            mediaUploads[name] = .failed
        }
    }

    /// Borra una imagen del servidor (R2). Idempotente: borrar algo inexistente no es error.
    func deleteMedia(_ name: String) async {
        guard SyncConfig.isConfigured, let req = makeRequest("/media/\(name)", method: "DELETE") else { return }
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Estado de subida de una foto (para la insignia de verificación en la vista).
    func uploadState(_ name: String?) -> MediaUploadState? {
        guard let name else { return nil }
        return mediaUploads[name]
    }

    /// Reintenta subir una imagen cuya subida falló o quedó pausada por cuota.
    func retryUpload(_ name: String) {
        pausedUploads.remove(name)
        Task { await uploadMedia(name, tracked: true) }
    }

    /// Consulta al servidor el almacenamiento usado en R2. Al conocerse (o bajar), reintenta
    /// las subidas que quedaron pausadas por falta de espacio.
    func refreshUsage() async {
        guard let req = makeRequest("/usage"),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let u = try? JSONDecoder().decode(UsageResponse.self, from: data) else { return }
        usageBytes = u.bytes
        usageKnown = true
        retryPausedIfRoom()
    }

    /// Reintenta las subidas pausadas por cuota. Cada una vuelve a pasar por el freno: si ya hay
    /// espacio, sube; si no, se vuelve a pausar.
    private func retryPausedIfRoom() {
        guard !pausedUploads.isEmpty else { return }
        let names = pausedUploads
        pausedUploads.removeAll()
        for name in names {
            mediaUploads[name] = nil
            Task { await uploadMedia(name, tracked: true) }
        }
    }

    /// Marca la subida como lograda y retira el visto bueno pasados unos segundos.
    private func markUploaded(_ name: String) {
        mediaUploads[name] = .uploaded
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.mediaUploads[name] = nil
        }
    }

    /// Tras un pull/push: baja las imágenes referenciadas que falten y sube las que el servidor no tenga.
    /// Las transferencias van en paralelo (hasta 4 a la vez) para no esperar una tras otra.
    func reconcile(referenced: Set<String>) async {
        guard SyncConfig.isConfigured else { return }
        if !referenced.isEmpty { status = .syncing }
        let fm = FileManager.default
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for name in referenced {
                if running >= 4 { await group.next(); running -= 1 }
                let onDisk = fm.fileExists(atPath: Store.mediaDir.appendingPathComponent(name).path)
                group.addTask { @MainActor in
                    if onDisk { await self.uploadMedia(name) } else { await self.downloadMedia(name) }
                }
                running += 1
            }
        }
        if case .error = status {} else { status = .upToDate }
    }

    // MARK: - Compartir tablero

    private struct ShareRequest: Encodable { let boardId: String }
    private struct ShareResponse: Decodable { let token: String }

    /// Pide (o reutiliza) el token público de un tablero. Idempotente en el servidor.
    func share(boardID: UUID) async -> String? {
        let body = try? JSONEncoder().encode(ShareRequest(boardId: boardID.uuidString))
        guard let req = makeRequest("/share", method: "POST", body: body, contentType: "application/json"),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(ShareResponse.self, from: data) else { return nil }
        return r.token
    }

    /// Token con el que ya está compartido un tablero, o nil si no lo está.
    func sharedToken(boardID: UUID) async -> String? {
        guard let req = makeRequest("/share/\(boardID.uuidString)"),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(ShareResponse.self, from: data) else { return nil }
        return r.token
    }

    /// Deja de compartir un tablero (revoca el enlace).
    func unshare(boardID: UUID) async {
        guard let req = makeRequest("/share/\(boardID.uuidString)", method: "DELETE") else { return }
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Bandeja de entrada

    private struct InboxResponse: Decodable { let items: [InboxItem] }

    /// Baja la lista de capturas que esperan en la bandeja del servidor. nil si falla o no hay sesión.
    func fetchInbox() async -> [InboxItem]? {
        guard let req = makeRequest("/inbox"),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(InboxResponse.self, from: data) else { return nil }
        return r.items
    }

    /// Consume una captura de la bandeja. Con `discardMedia` borra también su imagen de R2 (descartar
    /// sin importar); al importarla a un tablero se conserva, porque la biblioteca pasa a usarla.
    func deleteInboxItem(_ id: String, discardMedia: Bool) async {
        let path = "/inbox/\(id)" + (discardMedia ? "?media=delete" : "")
        guard let req = makeRequest(path, method: "DELETE") else { return }
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Prueba de conexión

    @discardableResult
    func testConnection() async -> Status {
        guard SyncConfig.isConfigured else { status = .disabled; return status }
        status = .syncing
        guard let req = makeRequest("/library") else { status = .error("URL inválida"); return status }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // 200 = hay biblioteca; 404 = servidor vacío. Ambos significan conectado y autorizado.
            status = (code == 200 || code == 404) ? .upToDate
                : code == 401 ? .error("Token incorrecto")
                : .error("HTTP \(code)")
        } catch {
            status = .error(error.localizedDescription)
        }
        return status
    }

    // MARK: - Ayudas

    /// Todos los nombres de imagen que usa la biblioteca (tableros + papelera).
    static func referencedMedia(_ library: Library) -> Set<String> {
        var names: Set<String> = []
        for board in library.boards {
            for item in board.items { if let m = item.media { names.insert(m) } }
        }
        for entry in library.trash {
            switch entry.content {
            case .board(let b): for item in b.items { if let m = item.media { names.insert(m) } }
            case .item(let item, _, _): if let m = item.media { names.insert(m) }
            }
        }
        return names
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
