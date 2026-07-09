import SwiftUI
import WebKit

// Full-width top bar, Chrome-style, visible regardless of rail state.
// Left to right: traffic lights, rail toggle, soft divider, jump-to cluster
// (watch list, favorite video lists, music, favorite music lists), stronger
// divider, back/forward. Tight padding, controls sized to be seen.
struct TopBar: View {
	@ObservedObject var sessions: WebSessionManager
	@AppStorage("railCollapsed") private var collapsed = false
	@AppStorage("railSegment") private var segment = "sessions"

	var body: some View {
		HStack(spacing: 16) {
			Spacer()
				.frame(width: 54)
			IconButton(collapsed ? "sidebar.right" : "sidebar.left",
				help: collapsed ? "Show side menu" : "Hide side menu") {
				collapsed.toggle()
			}
			barDivider(22)
			IconButton("text.badge.star", help: "Watch pipeline") {
				collapsed = false
				segment = "watch"
			}
			IconButton("star", help: "Favorite video lists (Phase 3)") {}
				.disabled(true)
			IconButton("music.note", help: "Music", active: sessions.active == .music) {
				sessions.showMusic()
			}
			.overlay(alignment: .topTrailing) {
				if sessions.isAudible(sessions.musicWebView) {
					Image(systemName: "speaker.wave.2.fill")
						.font(.system(size: 9))
						.foregroundStyle(Color.accentColor)
						.offset(x: 4, y: -2)
				}
			}
			IconButton("star.square.on.square", help: "Favorite music lists (Phase 3)") {}
				.disabled(true)
			barDivider(28)
			NavButtons(sessions: sessions)
				.id(sessions.active)
			if !sessions.watchSessions.isEmpty {
				barDivider(28)
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 8) {
						ForEach(sessions.watchSessions) { session in
							TabChip(sessions: sessions, session: session)
						}
					}
				}
			}
			Spacer(minLength: 0)
		}
		.padding(.leading, 8)
		.padding(.trailing, 10)
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

// A watch tab up in the top bar, Chrome-style: live title, click to switch,
// x to close (which parks the web view back into the warm pool).
struct TabChip: View {
	@ObservedObject var sessions: WebSessionManager
	let session: WatchSession
	@State private var title = "Loading..."

	private var selected: Bool {
		sessions.active == .watch(session.id)
	}

	var body: some View {
		HStack(spacing: 6) {
			if sessions.isAudible(session.webView) {
				Image(systemName: "speaker.wave.2.fill")
					.font(.system(size: 11))
					.foregroundStyle(Color.accentColor)
			}
			Text(title)
				.font(.system(size: 14))
				.lineLimit(1)
				.truncationMode(.tail)
			Button {
				sessions.closeWatchTab(session)
			} label: {
				Image(systemName: "xmark")
					.font(.system(size: 10, weight: .bold))
			}
			.buttonStyle(.borderless)
			.help("Close tab")
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 6)
		.frame(maxWidth: 180)
		.background(
			RoundedRectangle(cornerRadius: 7)
				.fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
		.contentShape(Rectangle())
		.onTapGesture {
			sessions.active = .watch(session.id)
		}
		.onReceive(session.webView.publisher(for: \.title)) { newTitle in
			if let newTitle, !newTitle.isEmpty {
				title = newTitle.strippedYouTubeSuffix
			}
		}
	}
}

extension String {
	var strippedYouTubeSuffix: String {
		hasSuffix(" - YouTube") ? String(dropLast(10)) : self
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
