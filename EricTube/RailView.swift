import SwiftUI
import WebKit

struct RailView: View {
	@ObservedObject var sessions: WebSessionManager
	@AppStorage("railCollapsed") private var collapsed = false

	var body: some View {
		VStack(spacing: 0) {
			if collapsed {
				collapsedStrip
			} else {
				topStrip
				sessionList
			}
			Spacer(minLength: 0)
		}
		.frame(width: collapsed ? 72 : 280)
		.frame(maxHeight: .infinity)
		.background(Color(nsColor: .windowBackgroundColor))
	}

	// Eric's sketch, left to right: traffic lights, collapse, soft divider,
	// jump-to cluster (watch list, favorite video lists, music, favorite
	// music lists), stronger divider, back/forward. Jump-to buttons stub
	// until their phases land.
	private var topStrip: some View {
		HStack(spacing: 8) {
			Spacer()
				.frame(width: 54)
			IconButton("sidebar.left", help: "Collapse rail") { collapsed = true }
			railDivider(14)
			IconButton("text.badge.star", help: "Current watch list (Phase 4)") {}
				.disabled(true)
			IconButton("star", help: "Favorite video lists (Phase 3)") {}
				.disabled(true)
			IconButton("music.note", help: "Music", active: sessions.active == .music) {
				sessions.showMusic()
			}
			IconButton("star.square.on.square", help: "Favorite music lists (Phase 3)") {}
				.disabled(true)
			railDivider(20)
			NavButtons(sessions: sessions)
				.id(sessions.active)
			Spacer(minLength: 0)
		}
		.padding(.leading, 8)
		.frame(height: 38)
	}

	private var collapsedStrip: some View {
		VStack(spacing: 12) {
			Spacer()
				.frame(height: 26)
			IconButton("sidebar.right", help: "Expand rail") { collapsed = false }
			NavButtons(sessions: sessions)
				.id(sessions.active)
		}
	}

	private var sessionList: some View {
		VStack(alignment: .leading, spacing: 2) {
			SessionRow(
				icon: "house", title: "Master",
				selected: sessions.active == .master,
				select: { sessions.active = .master },
				close: nil)
			ForEach(sessions.watchSessions) { session in
				WatchTabRow(sessions: sessions, session: session)
			}
			if sessions.watchSessions.isEmpty {
				Text("watch tabs appear here")
					.font(.caption)
					.foregroundStyle(.quaternary)
					.padding(.leading, 10)
					.padding(.top, 4)
			}
		}
		.padding(.horizontal, 8)
		.padding(.top, 8)
	}

	private func railDivider(_ height: CGFloat) -> some View {
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
				.foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
		}
		.buttonStyle(.borderless)
		.help(help)
	}
}

// Subscribed to the active session's history state; .id(sessions.active) at
// the call sites forces a resubscribe when the active session changes.
struct NavButtons: View {
	@ObservedObject var sessions: WebSessionManager
	@State private var canGoBack = false
	@State private var canGoForward = false

	var body: some View {
		HStack(spacing: 8) {
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

struct SessionRow: View {
	let icon: String
	let title: String
	let selected: Bool
	let select: () -> Void
	let close: (() -> Void)?

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: icon)
				.frame(width: 16)
			Text(title)
				.lineLimit(1)
				.truncationMode(.tail)
			Spacer(minLength: 0)
			if let close {
				Button(action: close) {
					Image(systemName: "xmark")
						.font(.system(size: 9, weight: .bold))
				}
				.buttonStyle(.borderless)
				.help("Close tab")
			}
		}
		.font(.system(size: 12))
		.padding(.vertical, 5)
		.padding(.horizontal, 8)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(
			RoundedRectangle(cornerRadius: 6)
				.fill(selected ? Color.accentColor.opacity(0.22) : Color.clear))
		.contentShape(Rectangle())
		.onTapGesture(perform: select)
	}
}

struct WatchTabRow: View {
	@ObservedObject var sessions: WebSessionManager
	let session: WatchSession
	@State private var title = "Loading..."

	var body: some View {
		SessionRow(
			icon: "play.rectangle", title: title,
			selected: sessions.active == .watch(session.id),
			select: { sessions.active = .watch(session.id) },
			close: { sessions.closeWatchTab(session) })
		.onReceive(session.webView.publisher(for: \.title)) { newTitle in
			if let newTitle, !newTitle.isEmpty {
				title = newTitle.hasSuffix(" - YouTube")
					? String(newTitle.dropLast(10))
					: newTitle
			}
		}
	}
}
