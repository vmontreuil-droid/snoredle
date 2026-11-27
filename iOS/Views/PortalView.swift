import SwiftUI
import SwiftData

/// Instellingen › Portaal: aanmelden, toestemming, synchroniseren, gegevens wissen.
struct PortalView: View {
    @ObservedObject private var sync = SyncService.shared
    @Environment(\.modelContext) private var context
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var confirmWipe = false
    @State private var confirmAccount = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Text("Bekijk al je nachten op een groot scherm via het Snoredle-portaal, ook op je computer. Na elke nacht stuurt de app je meting automatisch door.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !SyncConfig.isConfigured {
                    Label("Het portaal wordt nog ingesteld. Probeer het binnenkort opnieuw.", systemImage: "hourglass")
                        .foregroundStyle(.orange)
                }
            }

            if let s = sync.session {
                Section("Account") {
                    LabeledContent("Aangemeld als", value: s.email)
                    Toggle(isOn: Binding(get: { sync.consent }, set: { on in
                        sync.consent = on
                        if on { Task { await sync.saveConsent(); await sync.syncPending(context: context) } }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nachten naar het portaal sturen")
                            Text("Ik geef toestemming om mijn slaap- en gezondheidsgegevens (snurken, houding, hartslag, zuurstof, slaapfasen) te bewaren in mijn Snoredle-account. Opnames van geluid blijven op mijn iPhone.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Synchronisatie") {
                    if let d = sync.lastSync {
                        LabeledContent("Laatst", value: d.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button {
                        Task { await sync.syncPending(context: context, force: true) }
                    } label: { Label("Alles opnieuw versturen", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(!sync.enabled || sync.busy)
                    Button { openURL(SyncConfig.portalURL) } label: { Label("Open het portaal", systemImage: "safari") }
                }
                Section {
                    Button("Afmelden") { sync.signOut() }
                    Button("Gegevens in het portaal wissen", role: .destructive) { confirmWipe = true }
                    Button("Account volledig verwijderen", role: .destructive) { confirmAccount = true }
                } footer: {
                    Text("Wissen in het portaal laat je nachten op deze iPhone staan.")
                }
            } else {
                Section {
                    TextField("E-mailadres", text: $email)
                        .keyboardType(.emailAddress).textContentType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if codeSent {
                        TextField("Code uit de e-mail", text: $code)
                            .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        Button("Aanmelden") { Task { if await sync.verify(email: email, code: code) { code = "" } } }
                            .disabled(code.count < 6 || sync.busy)
                        Button("Nieuwe code sturen") { Task { _ = await sync.sendCode(to: email) } }.font(.footnote)
                    } else {
                        Button("Stuur me een code") { Task { codeSent = await sync.sendCode(to: email) } }
                            .disabled(!email.contains("@") || sync.busy || !SyncConfig.isConfigured)
                    }
                } header: {
                    Text("Aanmelden")
                } footer: {
                    Text("Geen wachtwoord nodig: je krijgt telkens een code per e-mail. Met hetzelfde adres meld je je aan op het portaal.")
                }
            }

            if let st = sync.status {
                Section { Text(st).font(.footnote) }
            }
            if sync.busy { Section { ProgressView() } }
        }
        .navigationTitle("Portaal")
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog("Alle nachten in het portaal wissen?", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("Wissen", role: .destructive) { Task { _ = await sync.deleteCloudData(context: context) } }
        }
        .confirmationDialog("Account en alle gegevens in het portaal definitief verwijderen?", isPresented: $confirmAccount, titleVisibility: .visible) {
            Button("Verwijderen", role: .destructive) { Task { _ = await sync.deleteAccount(context: context) } }
        }
    }
}
