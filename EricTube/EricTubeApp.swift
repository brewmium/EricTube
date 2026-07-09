import SwiftUI

// Closing the window must not quit the app: the sessions (music especially)
// live in WebSessionManager and survive windowless; the menu bar item and
// the dock icon bring the window back with everything intact.
final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}
}

@main
struct EricTubeApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	@StateObject private var sessions = WebSessionManager.shared
	@StateObject private var store = OverlayStore.shared

	var body: some Scene {
		Window("EricTube", id: "main") {
			ContentView(sessions: sessions, store: store)
				.frame(minWidth: 1000, minHeight: 640)
				.background(WindowChrome())
		}
		.defaultSize(width: 1440, height: 900)
		.windowStyle(.hiddenTitleBar)
		.commands {
			CommandGroup(after: .toolbar) {
				Button("Zoom In") {
					WebSessionManager.shared.adjustZoom(by: 0.1)
				}
				.keyboardShortcut("=")
				Button("Zoom Out") {
					WebSessionManager.shared.adjustZoom(by: -0.1)
				}
				.keyboardShortcut("-")
				Button("Actual Size") {
					WebSessionManager.shared.adjustZoom(by: nil)
				}
				.keyboardShortcut("0")
			}
		}

		MenuBarExtra("EricTube", systemImage: "play.rectangle.fill") {
			MenuBarContent()
		}
	}
}

private struct MenuBarContent: View {
	@Environment(\.openWindow) private var openWindow

	// Which build am I running? Answered from the menu bar, no guessing.
	private var buildStamp: String {
		guard let url = Bundle.main.executableURL,
		      let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
		else { return "unknown" }
		return date.formatted(date: .abbreviated, time: .shortened)
	}

	var body: some View {
		Button("Open EricTube") {
			openWindow(id: "main")
			NSApp.activate(ignoringOtherApps: true)
		}
		Text("Build \(buildStamp)")
		Divider()
		Button("Quit EricTube") {
			NSApp.terminate(nil)
		}
	}
}
