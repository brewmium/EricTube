import SwiftUI

// The per-video action palette, anchored at the click point.
struct PaletteView: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var store: OverlayStore
	let request: PaletteRequest

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			PaletteRow(icon: "play.rectangle.on.rectangle", label: "Open as tab") {
				sessions.openWatchTab(videoId: request.videoId)
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
			if store.lists.isEmpty {
				PaletteRow(icon: "folder", label: "Add to list (make one in Lists)", enabled: false) {}
			} else {
				Menu {
					ForEach(store.lists) { list in
						Button(list.name) {
							store.addToList(request.videoId, listId: list.id)
							sessions.paletteRequest = nil
						}
					}
				} label: {
					HStack(spacing: 8) {
						Image(systemName: "folder")
							.frame(width: 18)
						Text("Add to list")
						Spacer(minLength: 0)
					}
					.contentShape(Rectangle())
					.padding(.vertical, 3)
					.padding(.horizontal, 4)
				}
				.menuStyle(.borderlessButton)
			}
		}
		.padding(10)
		.frame(width: 230)
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
