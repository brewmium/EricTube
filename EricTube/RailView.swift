import SwiftUI
import WebKit

// The left menu. Its own tab bar on top switches top-level views: Watch
// (sessions + continue + the pipeline), Lists (the library), Import. Width
// is owned by ContentView (user-resizable).
struct RailView: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var store: OverlayStore
	@AppStorage("railSegment") private var segment = "watch"

	var body: some View {
		VStack(spacing: 0) {
			Picker("", selection: $segment) {
				Text("Watch").tag("watch")
				Text("Lists").tag("lists")
				Text("Import").tag("import")
			}
			.pickerStyle(.segmented)
			.controlSize(.large)
			.labelsHidden()
			.padding(.horizontal, 8)
			.padding(.top, 8)
			switch segment {
			case "lists":
				ListsView(sessions: sessions, store: store)
			case "import":
				ImportView(sessions: sessions)
			default:
				WatchPipelineView(sessions: sessions, store: store)
			}
			Spacer(minLength: 0)
		}
		.frame(maxHeight: .infinity, alignment: .top)
		.background(Color(nsColor: .windowBackgroundColor))
		.onAppear {
			if segment == "sessions" {
				segment = "watch"
			}
		}
	}
}

struct SessionRow: View {
	let icon: String
	let title: String
	let selected: Bool
	var audible = false
	let select: () -> Void
	let close: (() -> Void)?

	var body: some View {
		HStack(spacing: 8) {
			// Leading glyph becomes the blue speaker while audible, so the
			// now-playing state never nudges the title over.
			Image(systemName: audible ? "speaker.wave.2.fill" : icon)
				.foregroundStyle(audible ? Color.accentColor : Color.primary)
				.frame(width: 24)
			Text(title)
				.lineLimit(1)
				.truncationMode(.tail)
			Spacer(minLength: 0)
			if let close {
				Button(action: close) {
					Image(systemName: "xmark")
						.font(.system(size: 13, weight: .bold))
						.frame(width: 26, height: 26)
						.contentShape(Rectangle())
				}
				.buttonStyle(.borderless)
				.help("Close tab")
			}
		}
		.font(.system(size: 14))
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

