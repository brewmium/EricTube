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
// Edit mode is an explicit toggle: only then do lists drag and grow their
// hover (+) affordances, so normal browsing can't accidentally rearrange
// the tree. Item dragging between lists is a later, separate decision.
struct ListsView: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var store: OverlayStore
	@State private var newListName = ""
	@State private var editing = false

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
				Button {
					editing.toggle()
				} label: {
					Label(editing ? "Done" : "Edit",
						systemImage: editing ? "checkmark.circle.fill" : "pencil")
				}
				.buttonStyle(.bordered)
				.tint(editing ? Color.accentColor : nil)
				.help(editing ? "Done editing" : "Edit mode: drag to rearrange, hover for (+) sub-list")
			}
			.padding(.horizontal, 10)
			.padding(.top, 10)
			if editing {
				Text("drag lists to move or nest; hover a row for (+)")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.padding(.leading, 12)
			}
			ScrollView {
				VStack(alignment: .leading, spacing: 2) {
					ForEach(store.genres.sorted { $0.order < $1.order }) { genre in
						DisclosureGroup {
							ForEach(store.topLists(inGenre: genre.id)) { list in
								ListNodeView(sessions: sessions, store: store, list: list, editing: editing)
							}
						} label: {
							GenreDropLabel(store: store, genre: genre, editing: editing)
						}
						.padding(.horizontal, 10)
					}
					if !store.unfiledLists.isEmpty || editing {
						Text("Unfiled")
							.font(.system(size: 12, weight: .semibold))
							.foregroundStyle(.secondary)
							.padding(.leading, 12)
							.padding(.top, 8)
							.listDropTarget(enabled: editing) { listId in
								store.moveList(listId, toGenre: nil)
							}
						ForEach(store.unfiledLists) { list in
							ListNodeView(sessions: sessions, store: store, list: list, editing: editing)
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

// Hover-revealed (+) that pops a name field and creates a list where it
// was clicked (top-level in a genre, or as a sub-list).
private struct CreateChildButton: View {
	let help: String
	let create: @MainActor (String) -> Void
	@State private var showing = false
	@State private var name = ""

	var body: some View {
		Button {
			showing = true
		} label: {
			Image(systemName: "plus.circle")
				.foregroundStyle(Color.accentColor)
		}
		.buttonStyle(.borderless)
		.help(help)
		.popover(isPresented: $showing, arrowEdge: .bottom) {
			HStack(spacing: 6) {
				TextField("Name", text: $name)
					.textFieldStyle(.roundedBorder)
					.frame(width: 180)
					.onSubmit(submit)
				Button("Create", action: submit)
					.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
			}
			.padding(10)
		}
	}

	private func submit() {
		let trimmed = name.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return }
		create(trimmed)
		name = ""
		showing = false
	}
}

// Genre header; in edit mode a drop target for lists and a source of new
// top-level lists.
private struct GenreDropLabel: View {
	@ObservedObject var store: OverlayStore
	let genre: Genre
	let editing: Bool
	@State private var hovering = false

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "square.grid.2x2")
			Text(genre.name)
			Text("\(store.topLists(inGenre: genre.id).count)")
				.foregroundStyle(.tertiary)
			if editing && hovering {
				CreateChildButton(help: "New list in \(genre.name)") { name in
					store.createList(named: name, inGenre: genre.id)
				}
			}
		}
		.font(.system(size: 15, weight: .semibold))
		.onHover { hovering = $0 }
		.listDropTarget(enabled: editing) { listId in
			store.moveList(listId, toGenre: genre.id)
		}
	}
}

// One list in the tree, recursing into sub-lists. In edit mode the row
// grows a grip and a hover (+), becomes draggable, and accepts drops
// (nesting) — top-level lists nest under other lists the same way.
struct ListNodeView: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var store: OverlayStore
	let list: VideoList
	var editing = false
	@State private var hovering = false

	var body: some View {
		let items = store.inList(list.id)
		let children = store.sublists(of: list.id)
		DisclosureGroup {
			ForEach(children) { child in
				ListNodeView(sessions: sessions, store: store, list: child, editing: editing)
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
			label
		}
		.padding(.leading, 8)
	}

	@ViewBuilder
	private var label: some View {
		let base = HStack(spacing: 6) {
			if editing {
				Image(systemName: "line.3.horizontal")
					.foregroundStyle(.tertiary)
			}
			Image(systemName: "folder")
			Text(list.name)
				.lineLimit(1)
			Text("\(store.inList(list.id).count)")
				.foregroundStyle(.tertiary)
			if editing && hovering {
				CreateChildButton(help: "New sub-list under \(list.name)") { name in
					store.createList(named: name, under: list.id)
				}
			}
		}
		.font(.system(size: 14, weight: .medium))
		.onHover { hovering = $0 }
		if editing {
			base
				.onDrag {
					NSItemProvider(object: list.id.uuidString as NSString)
				}
				.listDropTarget(enabled: true) { draggedId in
					store.nestList(draggedId, under: list.id)
				}
		} else {
			base
		}
	}
}

// Shared drop-target behavior: accepts a dragged list id (plain text),
// highlights while hovered, hands the UUID to the action on main.
private struct ListDropTarget: ViewModifier {
	let enabled: Bool
	let action: @MainActor (UUID) -> Void
	@State private var hovering = false

	func body(content: Content) -> some View {
		if enabled {
			content
				.padding(.vertical, 2)
				.background(
					RoundedRectangle(cornerRadius: 5)
						.fill(hovering ? Color.accentColor.opacity(0.25) : Color.clear))
				.onDrop(of: [.plainText], isTargeted: $hovering) { providers in
					guard let provider = providers.first else { return false }
					_ = provider.loadObject(ofClass: NSString.self) { object, _ in
						guard let string = object as? String,
						      let id = UUID(uuidString: string) else { return }
						Task { @MainActor in
							action(id)
						}
					}
					return true
				}
		} else {
			content
		}
	}
}

private extension View {
	func listDropTarget(enabled: Bool, action: @escaping @MainActor (UUID) -> Void) -> some View {
		modifier(ListDropTarget(enabled: enabled, action: action))
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
