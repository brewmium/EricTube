import SwiftUI

// Closing the window must not quit the app: the sessions (music especially)
// live in WebSessionManager and survive windowless; the dock icon brings the
// window back with everything intact.
final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}
}

@main
struct EricTubeApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	@StateObject private var sessions = WebSessionManager.shared

	var body: some Scene {
		Window("EricTube", id: "main") {
			ContentView(sessions: sessions)
				.frame(minWidth: 1000, minHeight: 640)
				.background(WindowChrome())
		}
		.defaultSize(width: 1440, height: 900)
		.windowStyle(.hiddenTitleBar)
	}
}
