import AppKit
import SwiftUI

@MainActor
final class PreferencesWindow {
    static let shared = PreferencesWindow()
    private var controller: NSWindowController?

    func show(repoStore: TrackedRepoStore, settingsStore: SettingsStore, gitHubClient: GitHubClient) {
        if let controller, let window = controller.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = SettingsView(repoStore: repoStore, settingsStore: settingsStore, gitHubClient: gitHubClient)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        let size = NSSize(width: SettingsView.contentWidth, height: SettingsView.contentHeight)
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size
        window.center()

        let controller = NSWindowController(window: window)
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

