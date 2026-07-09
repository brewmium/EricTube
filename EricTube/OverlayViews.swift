import SwiftUI

// Rail segment: the watch pipeline (Axis 2). "Continue" (in-progress
// history) on top, then the three tiers; clicking a row opens it as a
// watch tab, resuming at the recorded position.
struct WatchPipelineView: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var store: OverlayStore
	@ObservedObject private var progress = ProgressStore.shared

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 4) {
				let continuing = progress.inProgress
				if !continuing.isEmpty {
					HStack(spacing: 6) {
						Image(systemName: "memories")
						Text("Continue")
						Text("\(continuing.count)")
							.foregroundStyle(.tertiary)
						Spacer(minLength: 0)
					}
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(.secondary)
					.padding(.top, 10)
					.padding(.horizontal, 10)
					ForEach(continuing) { entry in
						ContinueRow(sessions: sessions, progress: progress, entry: entry)
					}
				}
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

// A half-watched video: title, progress bar, resume on click, x to dismiss
// from the list (the record itself is kept).
struct ContinueRow: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var progress: ProgressStore
	let entry: WatchProgress

	var body: some View {
		HStack(alignment: .center, spacing: 6) {
			VStack(alignment: .leading, spacing: 3) {
				Text(entry.title)
					.font(.system(size: 14))
					.lineLimit(2)
				ProgressView(value: entry.fraction)
					.controlSize(.small)
			}
			Spacer(minLength: 0)
			Button {
				progress.dismiss(entry.videoId)
			} label: {
				Image(systemName: "xmark")
					.font(.system(size: 10, weight: .bold))
			}
			.buttonStyle(.borderless)
			.help("Remove from Continue")
		}
		.padding(.vertical, 4)
		.padding(.horizontal, 10)
		.contentShape(Rectangle())
		.onTapGesture {
			sessions.openWatchTab(videoId: entry.videoId)
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
							GenreDropLabel(store: store, genre: genre, editing: editing) {
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

// Genre header; a drop target for lists in edit mode, with its own hover
// gear (add list, rename, delete) in any mode.
private struct GenreDropLabel: View {
	@ObservedObject var store: OverlayStore
	let genre: Genre
	let editing: Bool
	let onExpand: @MainActor () -> Void
	@State private var hovering = false
	@State private var showingActions = false

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: genre.name == OverlayStore.deletedGenreName ? "trash" : "square.grid.2x2")
			Text(genre.name)
			Text("\(store.topLists(inGenre: genre.id).count)")
				.foregroundStyle(.tertiary)
			Button {
				showingActions = true
			} label: {
				Image(systemName: "gearshape")
					.font(.system(size: 16))
					.foregroundStyle(Color.accentColor)
			}
			.buttonStyle(.borderless)
			.help("Genre actions")
			.opacity(hovering || showingActions ? 1 : 0)
			.allowsHitTesting(hovering || showingActions)
			.popover(isPresented: $showingActions, arrowEdge: .bottom) {
				GenreActionsPopover(store: store, genre: genre, isPresented: $showingActions, onAddedList: onExpand)
			}
			Spacer(minLength: 0)
		}
		.font(.system(size: 17, weight: .semibold))
		.frame(maxWidth: .infinity, alignment: .leading)
		.contentShape(Rectangle())
		.onHover { hovering = $0 }
		.listDropTarget(enabled: editing) { listId in
			store.moveList(listId, toGenre: genre.id)
		}
	}
}

// The per-genre action popover: add list, rename, delete. The Deleted
// genre only offers add — its name is load-bearing and it can't be removed.
private struct GenreActionsPopover: View {
	@ObservedObject var store: OverlayStore
	let genre: Genre
	@Binding var isPresented: Bool
	let onAddedList: @MainActor () -> Void

	private enum Mode {
		case menu, addList, rename
	}

	@State private var mode: Mode = .menu
	@State private var text = ""

	private var isDeletedGenre: Bool {
		genre.name == OverlayStore.deletedGenreName
	}

	var body: some View {
		switch mode {
		case .menu:
			VStack(alignment: .leading, spacing: 2) {
				actionRow(icon: "plus.circle", label: "Add list", color: .primary) {
					text = ""
					mode = .addList
				}
				if !isDeletedGenre {
					actionRow(icon: "pencil", label: "Rename", color: .primary) {
						text = genre.name
						mode = .rename
					}
					Divider()
						.padding(.vertical, 2)
					actionRow(icon: "trash", label: deleteLabel, color: .red) {
						store.deleteGenre(genre.id)
						isPresented = false
					}
				}
			}
			.padding(10)
			.frame(width: 210)
		case .addList:
			nameEntry(placeholder: "List name", confirm: "Create") { name in
				store.createList(named: name, inGenre: genre.id)
				onAddedList()
			}
		case .rename:
			nameEntry(placeholder: "Genre name", confirm: "Rename") { name in
				store.renameGenre(genre.id, to: name)
			}
		}
	}

	private var deleteLabel: String {
		store.topLists(inGenre: genre.id).isEmpty ? "Delete" : "Move lists to Deleted"
	}

	private func actionRow(icon: String, label: String, color: Color, action: @escaping @MainActor () -> Void) -> some View {
		Button(action: action) {
			HStack(spacing: 8) {
				Image(systemName: icon)
					.frame(width: 18)
				Text(label)
				Spacer(minLength: 0)
			}
			.foregroundStyle(color)
			.contentShape(Rectangle())
			.padding(.vertical, 3)
			.padding(.horizontal, 4)
		}
		.buttonStyle(.borderless)
	}

	private func nameEntry(placeholder: String, confirm: String, commit: @escaping @MainActor (String) -> Void) -> some View {
		HStack(spacing: 6) {
			TextField(placeholder, text: $text)
				.textFieldStyle(.roundedBorder)
				.frame(width: 180)
				.onSubmit { submit(commit) }
			Button(confirm) {
				submit(commit)
			}
			.disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
		}
		.padding(10)
	}

	private func submit(_ commit: @escaping @MainActor (String) -> Void) {
		let trimmed = text.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return }
		commit(trimmed)
		isPresented = false
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
	@State private var showingActions = false

	var body: some View {
		let items = store.inList(list.id)
		let children = store.sublists(of: list.id)
		DisclosureGroup(isExpanded: $expanded) {
			ForEach(children) { child in
				ListNodeView(sessions: sessions, store: store, list: child, editing: editing)
			}
			ForEach(items) { video in
				SavedVideoRow(sessions: sessions, store: store, video: video, contextListId: list.id)
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
			actionButton
				.opacity(hovering || showingActions ? 1 : 0)
				.allowsHitTesting(hovering || showingActions)
			Spacer(minLength: 0)
		}
		.font(.system(size: 16, weight: .medium))
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

	// Available in both modes — a click is deliberate, unlike a drag, so
	// only dragging needs the edit-mode gate.
	private var actionButton: some View {
		Button {
			showingActions = true
		} label: {
			Image(systemName: "gearshape")
				.font(.system(size: 16))
				.foregroundStyle(Color.accentColor)
		}
		.buttonStyle(.borderless)
		.help("List actions")
		.popover(isPresented: $showingActions, arrowEdge: .bottom) {
			ListActionsPopover(store: store, list: list, isPresented: $showingActions) {
				expanded = true
			}
		}
	}
}

// The single per-list action popover: add child, rename, move (hierarchy
// picker), delete. Name entry and the picker swap in place of the menu.
private struct ListActionsPopover: View {
	@ObservedObject var store: OverlayStore
	let list: VideoList
	@Binding var isPresented: Bool
	let onAddedChild: @MainActor () -> Void

	private enum Mode {
		case menu, addChild, rename, move, merge
	}

	@State private var mode: Mode = .menu
	@State private var text = ""

	var body: some View {
		switch mode {
		case .menu:
			VStack(alignment: .leading, spacing: 2) {
				actionRow(icon: "plus.circle", label: "Add sub-list", color: .primary) {
					text = ""
					mode = .addChild
				}
				actionRow(icon: "pencil", label: "Rename", color: .primary) {
					text = list.name
					mode = .rename
				}
				actionRow(icon: "arrow.turn.down.right", label: "Move to...", color: .primary) {
					mode = .move
				}
				actionRow(icon: "arrow.triangle.merge", label: "Merge into...", color: .primary) {
					mode = .merge
				}
				Divider()
					.padding(.vertical, 2)
				actionRow(icon: store.isInDeletedGenre(list) ? "trash.fill" : "trash",
					label: deleteLabel, color: .red) {
					if store.isInDeletedGenre(list) {
						store.destroyList(list.id)
					} else {
						store.deleteList(list.id)
					}
					isPresented = false
				}
			}
			.padding(10)
			.frame(width: 200)
		case .addChild:
			nameEntry(placeholder: "Sub-list name", confirm: "Create") { name in
				store.createList(named: name, under: list.id)
				onAddedChild()
			}
		case .rename:
			nameEntry(placeholder: "List name", confirm: "Rename") { name in
				store.renameList(list.id, to: name)
			}
		case .move:
			ListPickerView(store: store, excludeListId: list.id) { destination in
				switch destination {
				case .genre(let genreId):
					store.moveList(list.id, toGenre: genreId)
				case .list(let parentId):
					store.nestList(list.id, under: parentId)
				}
				isPresented = false
			}
		case .merge:
			ListPickerView(store: store, excludeListId: list.id, allowGenrePick: false) { destination in
				if case .list(let targetId) = destination {
					store.mergeList(list.id, into: targetId)
				}
				isPresented = false
			}
		}
	}

	private var deleteLabel: String {
		if store.isInDeletedGenre(list) {
			return "Delete forever"
		}
		return store.inList(list.id).isEmpty && store.sublists(of: list.id).isEmpty
			? "Delete"
			: "Move to Deleted"
	}

	private func actionRow(icon: String, label: String, color: Color, action: @escaping @MainActor () -> Void) -> some View {
		Button(action: action) {
			HStack(spacing: 8) {
				Image(systemName: icon)
					.frame(width: 18)
				Text(label)
				Spacer(minLength: 0)
			}
			.foregroundStyle(color)
			.contentShape(Rectangle())
			.padding(.vertical, 3)
			.padding(.horizontal, 4)
		}
		.buttonStyle(.borderless)
	}

	private func nameEntry(placeholder: String, confirm: String, commit: @escaping @MainActor (String) -> Void) -> some View {
		HStack(spacing: 6) {
			TextField(placeholder, text: $text)
				.textFieldStyle(.roundedBorder)
				.frame(width: 180)
				.onSubmit { submit(commit) }
			Button(confirm) {
				submit(commit)
			}
			.disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
		}
		.padding(10)
	}

	private func submit(_ commit: @escaping @MainActor (String) -> Void) {
		let trimmed = text.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return }
		commit(trimmed)
		isPresented = false
	}
}

enum MoveDestination {
	case genre(UUID?)
	case list(UUID)
}

// The hierarchy picker: the Lists tree as a popover — genres and lists with
// counts, no videos. For list moves genres are pickable destinations; for
// video adds/moves (allowGenrePick false) they render as plain headers,
// since videos belong to lists, not genres.
struct ListPickerView: View {
	@ObservedObject var store: OverlayStore
	var excludeListId: UUID? = nil
	var allowGenrePick = true
	let onPick: @MainActor (MoveDestination) -> Void

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 1) {
				ForEach(store.genres.sorted { $0.order < $1.order }) { genre in
					PickerRow(icon: "square.grid.2x2", name: genre.name, count: nil, depth: 0, emphasized: true,
						action: genrePickAction(.genre(genre.id)))
					ForEach(store.topLists(inGenre: genre.id)) { list in
						PickerNode(store: store, list: list, depth: 1, excludeListId: excludeListId, onPick: onPick)
					}
				}
				if allowGenrePick || !store.unfiledLists.isEmpty {
					PickerRow(icon: "tray", name: "Unfiled", count: nil, depth: 0, emphasized: true,
						action: genrePickAction(.genre(nil)))
				}
				ForEach(store.unfiledLists) { list in
					PickerNode(store: store, list: list, depth: 1, excludeListId: excludeListId, onPick: onPick)
				}
			}
			.padding(8)
		}
		.frame(width: 280, height: 400)
	}

	private func genrePickAction(_ destination: MoveDestination) -> (@MainActor () -> Void)? {
		guard allowGenrePick else { return nil }
		return { onPick(destination) }
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
			PickerRow(icon: "folder", name: list.name, count: store.inList(list.id).count, depth: depth,
				action: { onPick(.list(list.id)) })
			ForEach(store.sublists(of: list.id)) { child in
				PickerNode(store: store, list: child, depth: depth + 1, excludeListId: excludeListId, onPick: onPick)
			}
		}
	}
}

// action nil renders a plain, non-clickable header row.
private struct PickerRow: View {
	let icon: String
	let name: String
	let count: Int?
	let depth: Int
	var emphasized = false
	let action: (@MainActor () -> Void)?
	@State private var hovering = false

	var body: some View {
		let content = HStack(spacing: 6) {
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
		if let action {
			Button(action: action) {
				content
					.background(
						RoundedRectangle(cornerRadius: 5)
							.fill(hovering ? Color.accentColor.opacity(0.2) : Color.clear))
					.contentShape(Rectangle())
			}
			.buttonStyle(.borderless)
			.onHover { hovering = $0 }
		} else {
			content
				.foregroundStyle(.secondary)
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
	var contextListId: UUID? = nil
	@State private var hovering = false
	@State private var showingActions = false

	var body: some View {
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
		.padding(.vertical, 4)
		.padding(.horizontal, 10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.contentShape(Rectangle())
		// The action button floats over the row's trailing edge on hover
		// instead of permanently costing the title its width.
		.overlay(alignment: .trailing) {
			Button {
				showingActions = true
			} label: {
				Image(systemName: "gearshape")
					.font(.system(size: 16))
					.foregroundStyle(Color.accentColor)
			}
			.buttonStyle(.borderless)
			.frame(width: 26)
			.background(
				RoundedRectangle(cornerRadius: 5)
					.fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
			.padding(.trailing, 8)
			.opacity(hovering || showingActions ? 1 : 0)
			.allowsHitTesting(hovering || showingActions)
			.popover(isPresented: $showingActions, arrowEdge: .bottom) {
				VideoActionsPopover(
					sessions: sessions, store: store, video: video,
					contextListId: contextListId, isPresented: $showingActions)
			}
		}
		.onHover { hovering = $0 }
		.onTapGesture {
			sessions.openWatchTab(videoId: video.videoId)
		}
	}
}

// The per-video action popover: open, tier moves, add/move to list via the
// hierarchy picker, archive. Replaces the old flat "Add to X" menus.
private struct VideoActionsPopover: View {
	@ObservedObject var sessions: WebSessionManager
	@ObservedObject var store: OverlayStore
	let video: SavedVideo
	let contextListId: UUID?
	@Binding var isPresented: Bool

	private enum Mode {
		case menu, addTo, moveTo
	}

	@State private var mode: Mode = .menu

	var body: some View {
		switch mode {
		case .menu:
			VStack(alignment: .leading, spacing: 2) {
				actionRow(icon: "play.rectangle.on.rectangle", label: "Open as tab", color: .primary) {
					sessions.openWatchTab(videoId: video.videoId)
					isPresented = false
				}
				Divider()
					.padding(.vertical, 2)
				ForEach(Tier.allCases) { tier in
					if video.tier != tier {
						actionRow(icon: tier.icon, label: tier.displayName, color: .primary) {
							store.setTier(video.videoId, to: tier)
							isPresented = false
						}
					}
				}
				Divider()
					.padding(.vertical, 2)
				actionRow(icon: "folder.badge.plus", label: "Add to list...", color: .primary) {
					mode = .addTo
				}
				if contextListId != nil {
					actionRow(icon: "arrow.turn.down.right", label: "Move to list...", color: .primary) {
						mode = .moveTo
					}
				}
				Divider()
					.padding(.vertical, 2)
				actionRow(icon: "archivebox", label: "Archive", color: .primary) {
					store.archive(video.videoId)
					isPresented = false
				}
			}
			.padding(10)
			.frame(width: 220)
		case .addTo:
			ListPickerView(store: store, allowGenrePick: false) { destination in
				if case .list(let listId) = destination {
					store.addToList(video.videoId, listId: listId)
				}
				isPresented = false
			}
		case .moveTo:
			ListPickerView(store: store, allowGenrePick: false) { destination in
				if case .list(let listId) = destination, let source = contextListId {
					store.moveVideo(video.videoId, from: source, to: listId)
				}
				isPresented = false
			}
		}
	}

	private func actionRow(icon: String, label: String, color: Color, action: @escaping @MainActor () -> Void) -> some View {
		Button(action: action) {
			HStack(spacing: 8) {
				Image(systemName: icon)
					.frame(width: 18)
				Text(label)
				Spacer(minLength: 0)
			}
			.foregroundStyle(color)
			.contentShape(Rectangle())
			.padding(.vertical, 3)
			.padding(.horizontal, 4)
		}
		.buttonStyle(.borderless)
	}
}
