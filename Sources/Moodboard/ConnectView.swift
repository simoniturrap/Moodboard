import SwiftUI

/// Pantalla de entrada: inicia sesión o regístrate contra tu propio servidor de Cloudflare.
/// Aparece al abrir cuando no hay sesión. También permite entrar en modo local, sin cuenta.
struct ConnectView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var sync = SyncService.shared
    /// Lo sube el botón "Usar localmente": deja pasar a la app sin iniciar sesión.
    @Binding var useLocalOnly: Bool

    private enum Mode: Hashable { case signIn, register }
    @State private var mode: Mode = SyncConfig.workerURL.isEmpty ? .register : .signIn
    @State private var url = SyncConfig.workerURL
    @State private var email = SyncConfig.email
    @State private var password = ""
    @State private var setupToken = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack {
            Spacer()
            card
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Moodboard").font(.largeTitle.bold())
                Text("Conéctate a tu servidor para ver tus mesas de trabajo en todos tus equipos.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("", selection: $mode) {
                Text("Iniciar sesión").tag(Mode.signIn)
                Text("Registrarse").tag(Mode.register)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 10) {
                field("Servidor", placeholder: "https://moodboard-sync.xxx.workers.dev", text: $url)
                if mode == .register {
                    secureField("Token de configuración (SYNC_TOKEN)", text: $setupToken)
                }
                field("Email", placeholder: "tu@email.com", text: $email)
                secureField("Contraseña", text: $password)
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: submit) {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(mode == .signIn ? "Iniciar sesión" : "Crear cuenta y entrar")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(busy || !canSubmit)

            HStack {
                Link("¿Cómo despliego mi servidor?",
                     destination: URL(string: "https://github.com/simoniturrap/Moodboard/tree/main/server")!)
                    .font(.caption)
                Spacer()
                Button("Usar localmente sin cuenta") { useLocalOnly = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .frame(width: 380)
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 6)
    }

    private var canSubmit: Bool {
        !url.isEmpty && !email.isEmpty && !password.isEmpty && (mode == .signIn || !setupToken.isEmpty)
    }

    @ViewBuilder
    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        }
    }

    @ViewBuilder
    private func secureField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            SecureField("", text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func submit() {
        guard !busy, canSubmit else { return }
        busy = true
        error = nil
        Task {
            let result = mode == .signIn
                ? await sync.login(workerURL: url, email: email, password: password)
                : await sync.register(workerURL: url, setupToken: setupToken, email: email, password: password)
            busy = false
            if let result {
                error = result
                return
            }
            password = ""
            setupToken = ""
            await store.resync()
        }
    }
}
