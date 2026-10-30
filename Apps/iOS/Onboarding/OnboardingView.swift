import PhiceNet
import SwiftUI

/// Portrait, once: install the agent, grant Accessibility, choose a Mac, click Allow on it, turn
/// sideways. The exact screens get designed after the MVP; this is the order, in the mockup's type.
struct OnboardingView: View {
    let model: AppModel
    @State private var flow = OnboardingFlow()

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                screen
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Spacer(minLength: 24)
                if flow.step == .install || flow.step == .accessibility {
                    Button("Continue") { flow.next() }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                        .controlSize(.large)
                }
            }
            .padding(.top, 96)
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: proxy.size.width > proxy.size.height && flow.step == .sideways) { _, done in
                if done { OnboardingFlow.finish(model) }
            }
        }
        .foregroundStyle(Palette.ink)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onChange(of: model.linkState) { _, state in flow.linkChanged(to: state) }
    }

    @ViewBuilder private var screen: some View {
        switch flow.step {
        case .install:
            heading("Install the Mac agent", "on your Mac, open")
            Text("phice.app/mac")
                .font(.system(size: 22, design: .monospaced))
                .foregroundStyle(Palette.accent)
                .textSelection(.enabled)
        case .accessibility:
            heading("Grant Accessibility", "System Settings on the Mac")
            HStack(spacing: 12) {
                AppIcon()
                Text("Phice").font(.system(size: 19))
                Capsule().fill(Palette.on).frame(width: 36, height: 21)
                    .overlay(alignment: .trailing) { Circle().fill(.white).padding(2) }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
            .padding(.top, 20)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Phice, switched on")
        case .choose:
            heading("Choose your Mac", "in Phice on the Mac, click Pair New iPhone")
            MacList(model: model) { mac in
                flow.chose(mac)
                model.link.pair(with: mac)
            }
        case let .allow(name):
            heading("Click Allow on \(name)", "the Mac asks once, naming this iPhone")
            Spinner().frame(width: 48, height: 48).padding(.top, 28)
        case .sideways:
            heading("Turn your phone sideways",
                    "the copy gesture is taught on the pad the first time you use it")
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 25))
            Text(detail).font(.system(size: 19)).foregroundStyle(Palette.mute)
        }
    }
}

/// Only Macs where Pair New iPhone was just clicked, by their own names.
private struct MacList: View {
    let model: AppModel
    let choose: (DiscoveredMac) -> Void

    var body: some View {
        let macs = model.macs.filter(\.pairingOpen)
        VStack(spacing: 10) {
            if macs.isEmpty {
                Text("Waiting for a Mac to open pairing")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.mute)
            }
            ForEach(macs) { mac in
                Button { choose(mac) } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 5).fill(Palette.well)
                            .frame(width: 20, height: 20)
                        Text(mac.name).font(.system(size: 19))
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 24)
    }
}

private struct AppIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(LinearGradient(colors: [Color(red: 0.54, green: 0.71, blue: 1),
                                          Color(red: 0.23, green: 0.42, blue: 1)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 20, height: 20)
    }
}

/// The mockup's waiting ring: the connecting sweep's blues, turning.
private struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let turn = seconds.truncatingRemainder(dividingBy: 1.2) / 1.2
            Circle()
                .strokeBorder(AngularGradient(stops: Palette.sweepStops, center: .center), lineWidth: 5)
                .rotationEffect(.degrees(turn * 360))
        }
        .accessibilityLabel("Waiting for your Mac")
    }
}
