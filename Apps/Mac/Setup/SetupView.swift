import SwiftUI

/// The agent's one window: who is connected, the permission, pairing, login item, quit.
struct SetupView: View {
    let controller: AgentController
    private var model: AgentModel { controller.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            phone
            Divider()
            accessibility
            Divider()
            pairing
            Divider()
            login
            HStack {
                Spacer()
                Button("Quit Phice") { controller.quit() }
            }
        }
        .padding(24)
        .frame(width: 420)
        .alert(
            "Allow “\(model.pairingRequest?.deviceName ?? "iPhone")” to control this Mac?",
            isPresented: Binding(get: { model.pairingRequest != nil }, set: { _ in })
        ) {
            Button("Allow") { controller.resolvePairing(allow: true) }
            Button("Don't Allow", role: .cancel) { controller.resolvePairing(allow: false) }
        } message: {
            Text("Only allow an iPhone that is yours. It will be able to move the pointer and click.")
        }
    }

    private var phone: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.connectedDevice == nil ? Color.secondary.opacity(0.4) : Color.green)
                .frame(width: 10, height: 10)
            Text(model.connectedDevice.map { "Connected to \($0)" } ?? "Waiting for your iPhone")
                .font(.headline)
        }
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility").font(.headline)
                    Text(model.accessibilityGranted ? "Phice can move the pointer and click."
                         : "Phice needs it to move the pointer and click.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.accessibilityGranted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Grant Access") { controller.requestAccessibility() }
                }
            }
            if !model.accessibilityGranted {
                HStack {
                    Text("macOS applies a new grant only after Phice relaunches.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Relaunch") { controller.relaunch() }
                }
            }
        }
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Pair a new iPhone").font(.headline)
            Text("Open Phice on your iPhone and choose “\(model.macName)”. "
                 + "This Mac accepts a new iPhone only while this window is open.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var login: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at login", isOn: Binding(
                get: { model.loginItemEnabled }, set: { controller.setLoginItem($0) }))
            if let note = model.loginItemNote {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
