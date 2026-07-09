import SwiftUI
import WebKit

// The sessions column: Master pinned, watch tabs below. Segments
// (Subscriptions / Library) land in later phases.
struct RailView: View {
	@ObservedObject var sessions: WebSessionManager

	var body: some View {
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
					.font(.system(size: 13))
					.foregroundStyle(.quaternary)
					.padding(.leading, 10)
					.padding(.top, 4)
			}
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 8)
		.padding(.top, 8)
		.frame(width: 280)
		.frame(maxHeight: .infinity, alignment: .top)
		.background(Color(nsColor: .windowBackgroundColor))
	}
}

struct SessionRow: View {
	let icon: String
	let title: String
	let selected: Bool
	let select: () -> Void
	let close: (() -> Void)?

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: icon)
				.frame(width: 24)
			Text(title)
				.lineLimit(1)
				.truncationMode(.tail)
			Spacer(minLength: 0)
			if let close {
				Button(action: close) {
					Image(systemName: "xmark")
						.font(.system(size: 13, weight: .bold))
				}
				.buttonStyle(.borderless)
				.help("Close tab")
			}
		}
		.font(.system(size: 18))
		.padding(.vertical, 7)
		.padding(.horizontal, 10)
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
				title = newTitle.strippedYouTubeSuffix
			}
		}
	}
}
