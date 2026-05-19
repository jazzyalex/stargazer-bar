import AppKit
import SwiftUI

@MainActor
final class PreferencesWindow: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindow()
    private var controller: NSWindowController?
    var visibilityDidChange: (() -> Void)?

    var isVisible: Bool {
        controller?.window?.isVisible == true
    }

    var canRestoreAfterExternalPrompt: Bool {
        controller?.window?.isVisible == true
    }

    func keepVisibleAfterActivationPolicyChange() {
        guard let window = controller?.window, window.isVisible else { return }
        present(window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window.isVisible else { return }
            self.present(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak window] in
            guard let self, let window, window.isVisible else { return }
            self.present(window)
        }
    }

    func restoreAfterExternalPrompt(if shouldRestore: Bool) {
        guard shouldRestore else { return }
        guard let window = controller?.window else { return }
        present(window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.present(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak window] in
            guard let self, let window else { return }
            self.present(window)
        }
    }

    func show(
        repoStore: TrackedRepoStore,
        settingsStore: SettingsStore,
        gitHubClient: GitHubClient,
        updaterController: UpdaterController
    ) {
        if let controller, let window = controller.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            visibilityDidChange?()
            return
        }

        let root = SettingsView(
            repoStore: repoStore,
            settingsStore: settingsStore,
            gitHubClient: gitHubClient,
            updaterController: updaterController
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self
        let size = NSSize(width: SettingsView.contentWidth, height: SettingsView.contentHeight)
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size
        window.center()

        let controller = NSWindowController(window: window)
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        visibilityDidChange?()
    }

    func windowWillClose(_ notification: Notification) {
        visibilityDidChange?()
    }

    private func present(_ window: NSWindow) {
        window.hidesOnDeactivate = false
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
