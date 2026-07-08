import SwiftUI

@main
struct EricTubeApp: App {
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
