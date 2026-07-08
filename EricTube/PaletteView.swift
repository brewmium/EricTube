import SwiftUI

// The per-video action palette, anchored at the hover chip. Disabled rows
// show the intended shape; they enable as their phases land.
struct PaletteView: View {
	@ObservedObject var sessions: WebSessionManager
	let request: PaletteRequest

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			PaletteRow(icon: "play.rectangle.on.rectangle", label: "Open as tab") {
				sessions.openWatchTab(videoId: request.videoId)
			}
			Divider()
				.padding(.vertical, 2)
			PaletteRow(icon: "text.line.first.and.arrowtriangle.forward", label: "Watch Next", enabled: false) {}
			PaletteRow(icon: "clock", label: "Watch Later", enabled: false) {}
			PaletteRow(icon: "moon.zzz", label: "Maybe Someday", enabled: false) {}
			Divider()
				.padding(.vertical, 2)
			PaletteRow(icon: "folder", label: "Add to list...", enabled: false) {}
		}
		.padding(10)
		.frame(width: 210)
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
