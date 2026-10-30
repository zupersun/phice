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
            paired
            Divider()
            login
            HStack {
                Spacer()
                Button("Quit Phice") { controller.quit() }
            }
        }
        .padding(24)
        .frame(width: 420)
        // Bound to the request it was opened with: its buttons answer that one or nothing.
        .alert(
            "Allow “\(model.pairingRequest?.deviceName ?? "iPhone")” to control this Mac?",
            isPresented: Binding(get: { model.pairingRequest != nil }, set: { _ in }),
            presenting: model.pairingRequest
        ) { request in
            Button("Allow") { controller.resolvePairing(request, allow: true) }
            Button("Don't Allow", role: .cancel) { controller.resolvePairing(request, allow: false) }
        } message: { _ in
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

    /// Idle: a button. Open: the countdown and Cancel. Whatever ended the last attempt is noted.
    private var pairing: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.pairingOpen ? "Waiting for an iPhone" : "Pair a new iPhone")
                        .font(.headline)
                    pairingDetail
                }
                Spacer()
                if model.pairingOpen {
                    Button("Cancel") { controller.cancelPairing() }
                } else {
                    Button("Pair New iPhone") { controller.startPairing() }
                }
            }
            if let note = model.pairingNote {
                Text(note).font(.callout).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var pairingDetail: some View {
        if model.pairingOpen {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = model.pairingSecondsLeft(now: context.date) ?? 0
                Text("Open Phice on your iPhone and choose “\(model.macName)”. \(left) s left.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            Text("Click, then open Phice on your iPhone and choose “\(model.macName)”.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var paired: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paired iPhones").font(.headline)
            if model.pairedPhones.isEmpty {
                Text("None yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.pairedPhones) { phone in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phone.name)
                        if let date = phone.pairedAt {
                            Text("Paired \(date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Remove") { controller.remove(phone) }
                }
            }
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
