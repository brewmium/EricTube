import SwiftUI

// The per-video action palette, anchored at the click point. "Add to list"
// swaps in the hierarchy picker in place.
struct PaletteView: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var store: OverlayStore
	let request: PaletteRequest
	@State private var picking = false

	var body: some View {
		if picking {
			ListPickerView(store: store, allowGenrePick: false) { destination in
				if case .list(let listId) = destination {
					store.addToList(request.videoId, listId: listId)
				}
				sessions.paletteRequest = nil
			}
		} else {
			VStack(alignment: .leading, spacing: 2) {
				// Background, always: adding a tab while browsing must not
				// yank you off the page you're on. Switch to it (and play, if
				// autoplay-on-select is on) by clicking it in the rail.
				PaletteRow(icon: "play.rectangle.on.rectangle", label: "Open as tab") {
					sessions.openWatchTab(videoId: request.videoId, activate: false)
				}
				Divider()
					.padding(.vertical, 2)
				ForEach(Tier.allCases) { tier in
					PaletteRow(icon: tier.icon, label: tier.displayName) {
						store.save(videoId: request.videoId, tier: tier)
						sessions.paletteRequest = nil
					}
				}
				Divider()
					.padding(.vertical, 2)
				PaletteRow(icon: "folder.badge.plus", label: "Add to list...", enabled: !store.lists.isEmpty) {
					picking = true
				}
			}
			.padding(10)
			.frame(width: 230)
		}
	}
}

struct PaletteRow: View {
	let icon: String
	let label: String
	var enabled = true
	let action: () -> Void

	init(icon: String, label: String, enabled: Bool = true, action: @escaping () -> Void) {
		self.icon = icon
		self.label = label
		self.enabled = enabled
		self.action = action
	}

	var body: some View {
		Button(action: action) {
			HStack(spacing: 8) {
				Image(systemName: icon)
					.frame(width: 18)
				Text(label)
				Spacer(minLength: 0)
			}
			.contentShape(Rectangle())
			.padding(.vertical, 3)
			.padding(.horizontal, 4)
		}
		.buttonStyle(.borderless)
		.disabled(!enabled)
	}
}
