import SwiftUI

// Rail segment: everything imported from the real YouTube account, raw.
// Clicks drive real pages: channels and playlists open as tabs.
struct ImportView: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject private var importer = YouTubeImporter.shared
	@ObservedObject private var auth = GoogleAuth.shared

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			header
			ScrollView {
				VStack(alignment: .leading, spacing: 2) {
					DisclosureGroup {
						ForEach(importer.subscriptions) { channel in
							importRow(title: channel.title, subtitle: nil) {
								sessions.openTab(path: "/channel/\(channel.id)")
							}
						}
					} label: {
						sectionLabel("person.2", "Subscriptions", importer.subscriptions.count)
					}
					.padding(.horizontal, 10)
					DisclosureGroup {
						ForEach(importer.playlists) { playlist in
							DisclosureGroup {
								ForEach(playlist.items) { item in
									importRow(title: item.title, subtitle: item.channelTitle) {
										sessions.openWatchTab(videoId: item.videoId)
									}
								}
							} label: {
								HStack(spacing: 6) {
									sectionLabel("list.bullet", playlist.title, playlist.itemCount)
									Button {
										sessions.openTab(path: "/playlist?list=\(playlist.id)")
									} label: {
										Image(systemName: "arrow.up.right.square")
									}
									.buttonStyle(.borderless)
									.help("Open playlist page")
								}
							}
							.padding(.leading, 8)
						}
					} label: {
						sectionLabel("square.stack", "Playlists", importer.playlists.count)
					}
					.padding(.horizontal, 10)
				}
				.padding(.bottom, 10)
			}
		}
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 6) {
			if !auth.hasClientSecret {
				Text("Drop client_secret*.json into ~/Library/Application Support/EricTube, then hit Import.")
					.font(.system(size: 12))
					.foregroundStyle(.secondary)
			}
			HStack(spacing: 8) {
				Button(importer.playlists.isEmpty ? "Import from YouTube" : "Re-import") {
					GoogleAuth.shared.reloadClient()
					importer.startImport()
				}
				.disabled(importer.isWorking)
				statusText
			}
		}
		.padding(.horizontal, 10)
		.padding(.top, 10)
	}

	@ViewBuilder
	private var statusText: some View {
		switch importer.status {
		case .idle:
			EmptyView()
		case .working(let what):
			HStack(spacing: 6) {
				ProgressView()
					.controlSize(.small)
				Text(what)
					.font(.system(size: 12))
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
		case .done(let date):
			Text(date.formatted(date: .abbreviated, time: .shortened))
				.font(.system(size: 12))
				.foregroundStyle(.tertiary)
		case .failed(let message):
			Text(message)
				.font(.system(size: 12))
				.foregroundStyle(.red)
				.lineLimit(3)
		}
	}

	private func sectionLabel(_ icon: String, _ title: String, _ count: Int) -> some View {
		HStack(spacing: 6) {
			Image(systemName: icon)
			Text(title)
				.lineLimit(1)
			Text("\(count)")
				.foregroundStyle(.tertiary)
		}
		.font(.system(size: 14, weight: .medium))
	}

	private func importRow(title: String, subtitle: String?, open: @escaping () -> Void) -> some View {
		VStack(alignment: .leading, spacing: 1) {
			Text(title)
				.font(.system(size: 13))
				.lineLimit(2)
			if let subtitle, !subtitle.isEmpty {
				Text(subtitle)
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
		}
		.padding(.vertical, 3)
		.padding(.leading, 12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.contentShape(Rectangle())
		.onTapGesture(perform: open)
	}
}
