import SwiftUI

// Compact settings popover, opened from the top bar's three-dot menu.
// Playback preferences the app reads at runtime; all persist via the manager.
struct SettingsView: View {
	@ObservedObject var sessions: WebSessionManager

	// "Pause hidden tabs" is the user-facing inverse of playInBackground, so
	// it stays in sync with the top bar's background-play toggle.
	private var pauseHidden: Binding<Bool> {
		Binding(
			get: { !sessions.playInBackground },
			set: { sessions.playInBackground = !$0 })
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("Settings")
				.font(.system(size: 15, weight: .semibold))

			settingToggle(
				isOn: $sessions.preferTheater,
				title: "Prefer theater mode",
				detail: "Open watch pages in the wide theater layout.")

			settingToggle(
				isOn: $sessions.autoplayOnSelect,
				title: "Autoplay on select",
				detail: "Selecting a tab — or opening a video into one — jumps to it and plays.")

			settingToggle(
				isOn: pauseHidden,
				title: "Pause hidden tabs",
				detail: "Only the visible tab plays; switching away pauses the last one. Music keeps playing.")
		}
		.padding(18)
		.frame(width: 320)
	}

	private func settingToggle(isOn: Binding<Bool>, title: String, detail: String) -> some View {
		Toggle(isOn: isOn) {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
				Text(detail)
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
			}
		}
		.toggleStyle(.switch)
	}
}
