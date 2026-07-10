import SwiftUI
import WebKit

// Full-width top bar, Chrome-style, visible regardless of rail state.
// Left to right: traffic lights, rail toggle, soft divider, jump-to cluster
// (watch list, favorite video lists, music, favorite music lists), stronger
// divider, back/forward, background-play toggle, then the active session's
// URL (read-only, selectable) with a copy button at its end, and the
// open-in-browser and settings icons. Session/tab switching lives in the
// rail's Watch segment.
struct TopBar: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var store: OverlayStore
	@AppStorage("railCollapsed") private var collapsed = false
	@AppStorage("railSegment") private var segment = "watch"
	@State private var showSettings = false
	@State private var urlHovering = false

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
			barDivider(22)
			IconButton("speaker.wave.2",
				help: sessions.playInBackground
					? "Background play on: switching tabs keeps playing"
					: "Background play off: switching tabs pauses",
				active: sessions.playInBackground) {
				sessions.playInBackground.toggle()
			}
			barDivider(28)
			HStack(spacing: 4) {
				URLDisplay(sessions: sessions)
					.id(sessions.active)
				CopyURLButton(sessions: sessions)
					.opacity(urlHovering ? 1 : 0)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.onHover { urlHovering = $0 }
			AddToListButton(sessions: sessions, store: store)
				.id(sessions.active)
			IconButton("safari", help: "Open in Browser") {
				guard let url = sessions.activeWebView.url else { return }
				NSWorkspace.shared.open(url)
			}
			IconButton("gearshape", help: "Settings", active: showSettings) {
				showSettings.toggle()
			}
			.popover(isPresented: $showSettings, arrowEdge: .bottom) {
				SettingsView(sessions: sessions)
			}
		}
		.padding(.leading, 8)
		.padding(.trailing, 10)
		.frame(height: 46)
		.frame(maxWidth: .infinity)
		.background(Color(nsColor: .windowBackgroundColor))
		.background(WindowDragArea())
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
		.tooltip(help)
	}
}

// AppKit-backed tooltip: shows for every icon, including disabled ones (where
// SwiftUI's .help stays silent), and reliably under the hidden-titlebar drag
// bar. The overlay passes clicks straight through to the button beneath.
struct TooltipOverlay: NSViewRepresentable {
	let text: String

	func makeNSView(context: Context) -> NSView {
		let view = PassThroughView()
		view.toolTip = text
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		nsView.toolTip = text
	}

	private final class PassThroughView: NSView {
		override func hitTest(_ point: NSPoint) -> NSView? { nil }
	}
}

extension View {
	func tooltip(_ text: String) -> some View {
		overlay(TooltipOverlay(text: text))
	}
}

// The active session's URL: visible and copyable (text selection works),
// deliberately not editable. .id(sessions.active) at the call site forces
// a resubscribe when the active session changes.
struct URLDisplay: View {
	@ObservedObject var sessions: WebSessionManager
	@State private var urlString = ""

	var body: some View {
		Text(urlString)
			.font(.system(size: 17))
			.foregroundStyle(.secondary)
			.lineLimit(1)
			.truncationMode(.middle)
			.textSelection(.enabled)
			.help(urlString)
			.onReceive(sessions.activeWebView.publisher(for: \.url)) { url in
				urlString = url?.absoluteString ?? ""
			}
	}
}

// Always-visible copy button for the active session's URL — sits at the end
// of the URL display, not buried under the three-dot menu.
struct CopyURLButton: View {
	@ObservedObject var sessions: WebSessionManager

	var body: some View {
		Button {
			guard let url = sessions.activeWebView.url else { return }
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(url.absoluteString, forType: .string)
		} label: {
			Image(systemName: "doc.on.doc")
				.font(.system(size: 16))
				.foregroundStyle(Color.primary.opacity(0.85))
				.frame(width: 30, height: 30)
		}
		.buttonStyle(.borderless)
		.tooltip("Copy URL")
	}
}

// Saves the active session's current video into a saved list, via the same
// genre -> list -> sub-list hierarchy picker used everywhere else — so you
// file what you're watching into the real tree, children and all.
struct AddToListButton: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var store: OverlayStore
	@State private var videoId: String?
	@State private var showPicker = false

	var body: some View {
		Button {
			showPicker = true
		} label: {
			Image(systemName: "text.badge.plus")
				.font(.system(size: 20))
				.foregroundStyle(videoId == nil
					? Color.primary.opacity(0.3)
					: Color.primary.opacity(0.85))
				.frame(width: 30, height: 30)
		}
		.buttonStyle(.borderless)
		.disabled(videoId == nil || store.lists.isEmpty)
		.tooltip("Add this video to a list")
		.popover(isPresented: $showPicker, arrowEdge: .bottom) {
			ListPickerView(store: store, allowGenrePick: false) { destination in
				if case .list(let listId) = destination, let videoId {
					store.addToList(videoId, listId: listId)
				}
				showPicker = false
			}
		}
		.onReceive(sessions.activeWebView.publisher(for: \.url)) { _ in
			videoId = sessions.currentVideoId(of: sessions.activeWebView)
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
