import SwiftUI

// Rail segment: the watch pipeline (Axis 2). Three tiers, promote/demote
// via each row's action menu; clicking a row opens it as a watch tab.
struct WatchPipelineView: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var store: OverlayStore

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 4) {
				ForEach(Tier.allCases) { tier in
					let items = store.inTier(tier)
					HStack(spacing: 6) {
						Image(systemName: tier.icon)
						Text(tier.displayName)
						Text("\(items.count)")
							.foregroundStyle(.tertiary)
						Spacer(minLength: 0)
					}
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(.secondary)
					.padding(.top, 10)
					.padding(.horizontal, 10)
					ForEach(items) { video in
						SavedVideoRow(sessions: sessions, store: store, video: video)
					}
					if items.isEmpty {
						Text("empty")
							.font(.system(size: 12))
							.foregroundStyle(.quaternary)
							.padding(.leading, 12)
					}
				}
			}
			.padding(.bottom, 10)
		}
	}
}

// Rail segment: the library (Axis 1) as genre -> list -> sub-list tree.
struct ListsView: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var store: OverlayStore
	@State private var newListName = ""

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 6) {
				TextField("New list name", text: $newListName)
					.textFieldStyle(.roundedBorder)
					.onSubmit(createList)
				Button(action: createList) {
					Image(systemName: "plus.circle.fill")
						.font(.system(size: 18))
				}
				.buttonStyle(.borderless)
				.disabled(newListName.trimmingCharacters(in: .whitespaces).isEmpty)
			}
			.padding(.horizontal, 10)
			.padding(.top, 10)
			ScrollView {
				VStack(alignment: .leading, spacing: 2) {
					ForEach(store.genres.sorted { $0.order < $1.order }) { genre in
						DisclosureGroup {
							ForEach(store.topLists(inGenre: genre.id)) { list in
								ListNodeView(sessions: sessions, store: store, list: list)
							}
						} label: {
							HStack(spacing: 6) {
								Image(systemName: "square.grid.2x2")
								Text(genre.name)
								Text("\(store.topLists(inGenre: genre.id).count)")
									.foregroundStyle(.tertiary)
							}
							.font(.system(size: 15, weight: .semibold))
						}
						.padding(.horizontal, 10)
					}
					if !store.unfiledLists.isEmpty {
						Text("Unfiled")
							.font(.system(size: 12, weight: .semibold))
							.foregroundStyle(.secondary)
							.padding(.leading, 12)
							.padding(.top, 8)
						ForEach(store.unfiledLists) { list in
							ListNodeView(sessions: sessions, store: store, list: list)
								.padding(.horizontal, 10)
						}
					}
					if store.lists.isEmpty {
						Text("no lists yet")
							.font(.system(size: 12))
							.foregroundStyle(.quaternary)
							.padding(.leading, 12)
							.padding(.top, 6)
					}
				}
				.padding(.bottom, 10)
			}
		}
	}

	private func createList() {
		store.createList(named: newListName)
		newListName = ""
	}
}

// One list in the tree, recursing into sub-lists.
struct ListNodeView: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var store: OverlayStore
	let list: VideoList

	var body: some View {
		let items = store.inList(list.id)
		let children = store.sublists(of: list.id)
		DisclosureGroup {
			ForEach(children) { child in
				ListNodeView(sessions: sessions, store: store, list: child)
			}
			ForEach(items) { video in
				SavedVideoRow(sessions: sessions, store: store, video: video)
			}
			if items.isEmpty && children.isEmpty {
				Text("empty")
					.font(.system(size: 12))
					.foregroundStyle(.quaternary)
					.padding(.leading, 12)
			}
		} label: {
			HStack(spacing: 6) {
				Image(systemName: "folder")
				Text(list.name)
					.lineLimit(1)
				Text("\(items.count)")
					.foregroundStyle(.tertiary)
			}
			.font(.system(size: 14, weight: .medium))
		}
		.padding(.leading, 8)
	}
}

struct SavedVideoRow: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var store: OverlayStore
	let video: SavedVideo

	var body: some View {
		HStack(alignment: .top, spacing: 6) {
			VStack(alignment: .leading, spacing: 1) {
				Text(video.title)
					.font(.system(size: 14))
					.lineLimit(2)
				if !video.channel.isEmpty {
					Text(video.channel)
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}
			Spacer(minLength: 0)
			Menu {
				Button("Open as tab") {
					sessions.openWatchTab(videoId: video.videoId)
				}
				Divider()
				ForEach(Tier.allCases) { tier in
					if video.tier != tier {
						Button(tier.displayName) {
							store.setTier(video.videoId, to: tier)
						}
					}
				}
				if !store.lists.isEmpty {
					Divider()
					ForEach(store.lists) { list in
						if !video.listIds.contains(list.id) {
							Button("Add to \(list.name)") {
								store.addToList(video.videoId, listId: list.id)
							}
						}
					}
				}
				Divider()
				Button("Archive") {
					store.archive(video.videoId)
				}
			} label: {
				Image(systemName: "ellipsis.circle")
					.font(.system(size: 14))
			}
			.menuStyle(.borderlessButton)
			.menuIndicator(.hidden)
			.frame(width: 22)
		}
		.padding(.vertical, 4)
		.padding(.horizontal, 10)
		.contentShape(Rectangle())
		.onTapGesture {
			sessions.openWatchTab(videoId: video.videoId)
		}
	}
}
