import SwiftUI
import WebKit

// Full-width top bar, Chrome-style, visible regardless of rail state.
// Left to right: traffic lights, rail toggle, soft divider, jump-to cluster
// (watch list, favorite video lists, music, favorite music lists), stronger
// divider, back/forward. Tight padding, controls sized to be seen.
struct TopBar: View {
	@ObservedObject var sessions: WebSessionManager
	@AppStorage("railCollapsed") private var collapsed = false

	var body: some View {
		HStack(spacing: 16) {
			Spacer()
				.frame(width: 54)
			IconButton(collapsed ? "sidebar.right" : "sidebar.left",
				help: collapsed ? "Show sessions" : "Hide sessions") {
				collapsed.toggle()
			}
			barDivider(22)
			IconButton("text.badge.star", help: "Current watch list (Phase 4)") {}
				.disabled(true)
			IconButton("star", help: "Favorite video lists (Phase 3)") {}
				.disabled(true)
			IconButton("music.note", help: "Music", active: sessions.active == .music) {
				sessions.showMusic()
			}
			IconButton("star.square.on.square", help: "Favorite music lists (Phase 3)") {}
				.disabled(true)
			barDivider(28)
			NavButtons(sessions: sessions)
				.id(sessions.active)
			Spacer(minLength: 0)
		}
		.padding(.leading, 8)
		.frame(height: 46)
		.frame(maxWidth: .infinity)
		.background(Color(nsColor: .windowBackgroundColor))
	}

	private func barDivider(_ height: CGFloat) -> some View {
		Rectangle()
			.fill(Color.primary.opacity(0.12))
			.frame(width: 1, height: height)
	}
}

struct IconButton: View {
	let systemName: String
	let help: String
	var active = false
	let action: () -> Void

	init(_ systemName: String, help: String, active: Bool = false, action: @escaping () -> Void) {
		self.systemName = systemName
		self.help = help
		self.active = active
		self.action = action
	}

	var body: some View {
		Button(action: action) {
			Image(systemName: systemName)
				.font(.system(size: 22))
				.foregroundStyle(active
					? AnyShapeStyle(Color.accentColor)
					: AnyShapeStyle(Color.primary.opacity(0.85)))
				.frame(width: 30, height: 30)
		}
		.buttonStyle(.borderless)
		.help(help)
	}
}

// Subscribed to the active session's history state; .id(sessions.active) at
// the call site forces a resubscribe when the active session changes.
struct NavButtons: View {
	@ObservedObject var sessions: WebSessionManager
	@State private var canGoBack = false
	@State private var canGoForward = false

	var body: some View {
		HStack(spacing: 16) {
			IconButton("chevron.backward", help: "Back") {
				sessions.activeWebView.goBack()
			}
			.disabled(!canGoBack)
			IconButton("chevron.forward", help: "Forward") {
				sessions.activeWebView.goForward()
			}
			.disabled(!canGoForward)
		}
		.onReceive(sessions.activeWebView.publisher(for: \.canGoBack)) { canGoBack = $0 }
		.onReceive(sessions.activeWebView.publisher(for: \.canGoForward)) { canGoForward = $0 }
	}
}
