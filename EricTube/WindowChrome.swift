import SwiftUI
import AppKit

// Grabs the AppKit window behind the SwiftUI scene for what SwiftUI doesn't
// expose. Window-frame persistence is split with SwiftUI on purpose: the
// Window scene autosaves the frame under its scene id ("NSWindow Frame main"
// in the per-machine defaults) on every move/resize, but does not reliably
// restore it at launch — so this hook does the restore, and only the restore.
// A second autosave name here would fight SwiftUI's and lose (learned the
// hard way). The name is coupled to the scene id in EricTubeApp.
struct WindowChrome: NSViewRepresentable {
	static let frameName = "main"

	func makeNSView(context: Context) -> NSView {
		HookView()
	}

	func updateNSView(_ nsView: NSView, context: Context) {}

	private final class HookView: NSView {
		private var wired = false

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			guard !wired, let window else { return }
			wired = true
			restoreFrame(of: window)
			// No title bar to grab; the web view swallows its own mouse
			// events, so background-drag applies to the rail only.
			window.isMovableByWindowBackground = true
		}

		// Not setFrameUsingName: macOS 26 appends a tilingState JSON blob
		// to the saved string, which makes that call silently fail — and
		// the OS then re-applies "fill" tiling on whatever screen the
		// window defaulted to. Parsing the leading "x y w h" ourselves and
		// setting the frame early puts the window on the right screen
		// before tiling restoration runs.
		private func restoreFrame(of window: NSWindow) {
			guard let saved = UserDefaults.standard.string(
				forKey: "NSWindow Frame \(WindowChrome.frameName)") else { return }
			let nums = saved.split(separator: " ").prefix(4).compactMap { Double($0) }
			guard nums.count == 4 else { return }
			let frame = NSRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
			guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return }
			window.setFrame(frame, display: false)
		}
	}
}
