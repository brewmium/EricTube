import SwiftUI

struct ContentView: View {
	@ObservedObject var sessions: WebSessionManager
	@AppStorage("railCollapsed") private var collapsed = false

	var body: some View {
		VStack(spacing: 0) {
			TopBar(sessions: sessions)
			Divider()
			HStack(spacing: 0) {
				if !collapsed {
					RailView(sessions: sessions)
					Divider()
				}
				ZStack {
					// Every session stays mounted; switching toggles opacity
					// so hidden sessions keep playing and keep their place
					// (music keeps going while browsing elsewhere).
					ForEach(sessions.displayed) { entry in
						WebView(webView: entry.webView)
							.opacity(sessions.active == entry.key ? 1 : 0)
							.allowsHitTesting(sessions.active == entry.key)
					}
				}
				.overlay(alignment: .topLeading) {
					PaletteAnchor(sessions: sessions)
				}
			}
		}
		.ignoresSafeArea()
	}
}

// Full-size invisible overlay; the palette pops from the exact click point
// via attachmentAnchor (the chip reports viewport coordinates, which match
// this overlay's space). Not a positioned 1x1 view: that could still sit at
// its previous position in the render pass that presents the popover.
private struct PaletteAnchor: View {
	@ObservedObject var sessions: WebSessionManager

	var body: some View {
		let anchor = sessions.paletteRequest?.anchor ?? .zero
		Color.clear
			.allowsHitTesting(false)
			.popover(item: $sessions.paletteRequest,
				attachmentAnchor: .rect(.rect(anchor)),
				arrowEdge: .bottom) { request in
				PaletteView(sessions: sessions, request: request)
			}
	}
}
