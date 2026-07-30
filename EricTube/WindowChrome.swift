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
		// nonisolated(unsafe): only written once during wiring on the main
		// thread; deinit (nonisolated in Swift 6) needs to read it.
		private nonisolated(unsafe) var dragMonitor: Any?

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			guard !wired, let window else { return }
			wired = true
			restoreFrame(of: window)
			// Deliberately NOT isMovableByWindowBackground: it made the
			// rail a window-drag surface, which fought list drag-and-drop.
			wireBarDrag(window)
		}

		deinit {
			if let dragMonitor {
				NSEvent.removeMonitor(dragMonitor)
			}
		}

		// Window dragging, as measured 2026-07-30: the hidden-titlebar
		// window keeps a native, transparent titlebar band over the top
		// ~28pt of the bar, and that band drags the window for ANY press in
		// it — buttons, slider, URL selection included. It decides at the
		// frame level (content views' mouseDownCanMoveWindow is never
		// consulted) and cancels SwiftUI's in-flight gesture once its move
		// hysteresis trips. A background drag NSView can't replace it
		// either: the hosting view claims all content events (a
		// WindowDragArea lived here until today, provably inert). So the
		// native band is disabled outright (isMovable = false) and dragging
		// is rebuilt in a local event monitor: any bar-height press that is
		// not over a control's DragShieldMarkerView and not in the
		// traffic-light corner starts a performDrag. The monitor returns
		// the event untouched, so SwiftUI sees exactly what it always saw.
		private func wireBarDrag(_ window: NSWindow) {
			window.isMovable = false
			dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
				self?.dragBarIfEligible(event)
				return event
			}
		}

		private func dragBarIfEligible(_ event: NSEvent) {
			guard let window, event.window === window,
			      let content = window.contentView else { return }
			let point = event.locationInWindow
			// The bar is the top 46pt (TopBar's frame height); the first
			// ~80pt of it belong to the traffic lights.
			guard point.y >= content.bounds.height - 46, point.x >= 80,
			      !HookView.markerClaims(content, point) else { return }
			window.performDrag(with: event)
		}

		private static func markerClaims(_ view: NSView, _ pointInWindow: NSPoint) -> Bool {
			if view is DragShieldMarkerView, !view.isHiddenOrHasHiddenAncestor {
				return view.bounds.contains(view.convert(pointInWindow, from: nil))
			}
			return view.subviews.contains { markerClaims($0, pointInWindow) }
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

// Marks a bar control's footprint as a no-window-drag zone. Completely inert
// (hitTest nil, like TooltipOverlay) — HookView's drag monitor scans for
// these by frame before starting a drag. Everything stays exactly as SwiftUI
// runs it; the marker is only geometry.
final class DragShieldMarkerView: NSView {
	override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct WindowDragShield: NSViewRepresentable {
	func makeNSView(context: Context) -> NSView {
		DragShieldMarkerView()
	}

	func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
	// The bar is one big drag surface; put this on anything interactive in it.
	func stopsWindowDrag() -> some View {
		overlay(WindowDragShield())
	}
}
