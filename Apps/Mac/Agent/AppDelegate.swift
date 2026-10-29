import AppKit
import SwiftUI

/// One fixed activation policy (LSUIElement, constraint 5): no Dock tile, no menu bar item, and the
/// window is how the app is reached again.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var controller: AgentController?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppEnvironment.isTesting else { return }
        let controller = AgentController.live(arguments: CommandLine.arguments)
        controller.onNeedsWindow = { [weak self] in self?.showSetup() }
        controller.start()
        self.controller = controller
        // At login there is nothing to show, unless Phice cannot do its job yet.
        let launch = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = AppEnvironment.launchedAsLoginItem(launch)
        if !atLogin || !controller.model.accessibilityGranted { showSetup() }
    }

    /// Launching Phice again (Spotlight, Finder) while it runs is how the user gets the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowWillClose(_ notification: Notification) {
        controller?.setPairingOpen(false)
    }

    private func showSetup() {
        guard let controller else { return }
        let window = window ?? makeWindow(for: controller)
        self.window = window
        controller.refreshLoginItem()
        controller.setPairingOpen(true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow(for controller: AgentController) -> NSWindow {
        let content = NSHostingController(rootView: SetupView(controller: controller))
        let window = NSWindow(contentViewController: content)
        window.title = "Phice"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}
