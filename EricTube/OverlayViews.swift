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
	@State private var expandedGenres: Set<UUID> = []

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
						DisclosureGroup(isExpanded: genreExpanded(genre.id)) {
							ForEach(store.topLists(inGenre: genre.id)) { list in
								ListNodeView(sessions: sessions, store: store, list: list, editing: editing)
							}
						} label: {
							GenreDropLabel(store: store, genre: genre, editing: editing) { name in
								store.createList(named: name, inGenre: genre.id)
								expandedGenres.insert(genre.id)
							}
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

	private func genreExpanded(_ id: UUID) -> Binding<Bool> {
		Binding(
			get: { expandedGenres.contains(id) },
			set: { open in
				if open {
					expandedGenres.insert(id)
				} else {
					expandedGenres.remove(id)
				}
			})
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
// top-level lists (onCreate also expands the genre so the result is seen).
private struct GenreDropLabel: View {
	@ObservedObject var store: OverlayStore
	let genre: Genre
	let editing: Bool
	let onCreate: @MainActor (String) -> Void
	@State private var hovering = false

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: genre.name == OverlayStore.deletedGenreName ? "trash" : "square.grid.2x2")
			Text(genre.name)
			Text("\(store.topLists(inGenre: genre.id).count)")
				.foregroundStyle(.tertiary)
			if editing {
				CreateChildButton(help: "New list in \(genre.name)", create: onCreate)
					.opacity(hovering ? 1 : 0)
					.allowsHitTesting(hovering)
			}
			Spacer(minLength: 0)
		}
		.font(.system(size: 15, weight: .semibold))
		.frame(maxWidth: .infinity, alignment: .leading)
		.contentShape(Rectangle())
		.onHover { hovering = $0 }
		.listDropTarget(enabled: editing) { listId in
			store.moveList(listId, toGenre: genre.id)
		}
	}
}

// One list in the tree, recursing into sub-lists. In edit mode the row
// grows a grip and hover controls — (+) sub-list (which expands the row so
// the child is seen), move-via-picker, delete — becomes draggable, and
// accepts drops (nesting). Delete moves content-bearing lists to the
// Deleted genre; inside Deleted the trash deletes forever.
struct ListNodeView: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var store: OverlayStore
	let list: VideoList
	var editing = false
	@State private var hovering = false
	@State private var expanded = false
	@State private var showingMove = false

	var body: some View {
		let items = store.inList(list.id)
		let children = store.sublists(of: list.id)
		DisclosureGroup(isExpanded: $expanded) {
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
			if editing {
				editControls
					.opacity(hovering || showingMove ? 1 : 0)
					.allowsHitTesting(hovering || showingMove)
			}
			Spacer(minLength: 0)
		}
		.font(.system(size: 14, weight: .medium))
		.frame(maxWidth: .infinity, alignment: .leading)
		.contentShape(Rectangle())
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

	private var editControls: some View {
		HStack(spacing: 8) {
			CreateChildButton(help: "New sub-list under \(list.name)") { name in
				store.createList(named: name, under: list.id)
				expanded = true
			}
			Button {
				showingMove = true
			} label: {
				Image(systemName: "arrow.turn.down.right")
					.foregroundStyle(Color.accentColor)
			}
			.buttonStyle(.borderless)
			.help("Move to...")
			.popover(isPresented: $showingMove, arrowEdge: .bottom) {
				ListPickerView(store: store, excludeListId: list.id) { destination in
					switch destination {
					case .genre(let genreId):
						store.moveList(list.id, toGenre: genreId)
					case .list(let parentId):
						store.nestList(list.id, under: parentId)
					}
					showingMove = false
				}
			}
			Button {
				if store.isInDeletedGenre(list) {
					store.destroyList(list.id)
				} else {
					store.deleteList(list.id)
				}
			} label: {
				Image(systemName: store.isInDeletedGenre(list) ? "trash.fill" : "trash")
					.foregroundStyle(.red)
			}
			.buttonStyle(.borderless)
			.help(store.isInDeletedGenre(list)
				? "Delete forever (videos not in other lists go too)"
				: "Delete: empty lists vanish; others move to Deleted")
		}
	}
}

enum MoveDestination {
	case genre(UUID?)
	case list(UUID)
}

// The hierarchy picker: the Lists tree as a popover — genres and lists with
// counts, no videos. Used for list moves now; the successor to the flat
// "Add to X" menus for videos later.
struct ListPickerView: View {
	@ObservedObject var store: OverlayStore
	var excludeListId: UUID?
	let onPick: @MainActor (MoveDestination) -> Void

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 1) {
				ForEach(store.genres.sorted { $0.order < $1.order }) { genre in
					PickerRow(icon: "square.grid.2x2", name: genre.name, count: nil, depth: 0, emphasized: true) {
						onPick(.genre(genre.id))
					}
					ForEach(store.topLists(inGenre: genre.id)) { list in
						PickerNode(store: store, list: list, depth: 1, excludeListId: excludeListId, onPick: onPick)
					}
				}
				PickerRow(icon: "tray", name: "Unfiled", count: nil, depth: 0, emphasized: true) {
					onPick(.genre(nil))
				}
				ForEach(store.unfiledLists) { list in
					PickerNode(store: store, list: list, depth: 1, excludeListId: excludeListId, onPick: onPick)
				}
			}
			.padding(8)
		}
		.frame(width: 280, height: 400)
	}
}

// Recursive picker rows; the excluded list's whole subtree is omitted (a
// list can't move into itself).
private struct PickerNode: View {
	@ObservedObject var store: OverlayStore
	let list: VideoList
	let depth: Int
	let excludeListId: UUID?
	let onPick: @MainActor (MoveDestination) -> Void

	var body: some View {
		if list.id != excludeListId {
			PickerRow(icon: "folder", name: list.name, count: store.inList(list.id).count, depth: depth) {
				onPick(.list(list.id))
			}
			ForEach(store.sublists(of: list.id)) { child in
				PickerNode(store: store, list: child, depth: depth + 1, excludeListId: excludeListId, onPick: onPick)
			}
		}
	}
}

private struct PickerRow: View {
	let icon: String
	let name: String
	let count: Int?
	let depth: Int
	var emphasized = false
	let action: @MainActor () -> Void
	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				Image(systemName: icon)
				Text(name)
					.lineLimit(1)
				if let count {
					Text("\(count)")
						.foregroundStyle(.tertiary)
				}
				Spacer(minLength: 0)
			}
			.font(.system(size: 13, weight: emphasized ? .semibold : .regular))
			.padding(.vertical, 3)
			.padding(.horizontal, 6)
			.padding(.leading, CGFloat(depth) * 14)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(
				RoundedRectangle(cornerRadius: 5)
					.fill(hovering ? Color.accentColor.opacity(0.2) : Color.clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.borderless)
		.onHover { hovering = $0 }
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
