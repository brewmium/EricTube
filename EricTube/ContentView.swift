import SwiftUI

struct ContentView: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var store: OverlayStore
	@AppStorage("railCollapsed") private var collapsed = false
	@AppStorage("railWidth") private var railWidth = 280.0

	var body: some View {
		VStack(spacing: 0) {
			TopBar(sessions: sessions, store: store)
			Divider()
			HStack(spacing: 0) {
				if !collapsed {
					RailView(sessions: sessions, store: store)
						.frame(width: max(220, min(500, railWidth)))
					RailResizeHandle(width: $railWidth)
				}
				ZStack {
					// Every session stays mounted; switching toggles opacity
					// so hidden sessions keep playing and keep their place
					// (music keeps going while browsing elsewhere).
					ForEach(sessions.displayed) { entry in
						WebView(webView: entry.webView,
							interactive: sessions.active == entry.key)
							.opacity(sessions.active == entry.key ? 1 : 0)
							.allowsHitTesting(sessions.active == entry.key)
							.zIndex(sessions.active == entry.key ? 1 : 0)
					}
				}
				.overlay(alignment: .topLeading) {
					PaletteAnchor(sessions: sessions, store: store)
				}
			}
		}
		.ignoresSafeArea()
	}
}

// 1px visual divider with an 8px grab zone; drags resize the rail (the web
// view takes the rest — the rail never overlays it).
private struct RailResizeHandle: View {
	@Binding var width: Double
	@State private var dragBase: Double?

	var body: some View {
		Rectangle()
			.fill(Color.clear)
			.frame(width: 8)
			.overlay(
				Rectangle()
					.fill(Color.primary.opacity(0.12))
					.frame(width: 1))
			.contentShape(Rectangle())
			.onHover { inside in
				if inside {
					NSCursor.resizeLeftRight.push()
				} else {
					NSCursor.pop()
				}
			}
			.gesture(
				DragGesture(minimumDistance: 1)
					.onChanged { value in
						let base = dragBase ?? width
						dragBase = base
						width = max(220, min(500, base + value.translation.width))
					}
					.onEnded { _ in
						dragBase = nil
					})
	}
}

// Full-size invisible overlay; the palette pops from the exact click point
// via attachmentAnchor (the chip reports viewport coordinates, which match
// this overlay's space). Not a positioned 1x1 view: that could still sit at
// its previous position in the render pass that presents the popover.
private struct PaletteAnchor: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var store: OverlayStore

	var body: some View {
		let anchor = sessions.paletteRequest?.anchor ?? .zero
		Color.clear
			.allowsHitTesting(false)
			.popover(item: $sessions.paletteRequest,
				attachmentAnchor: .rect(.rect(anchor)),
				arrowEdge: .bottom) { request in
				PaletteView(sessions: sessions, store: store, request: request)
			}
	}
}
