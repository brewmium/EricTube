import Foundation

// Axis 2 of the core data model (CREATION.md sect. 5): when it'll be watched.
enum Tier: String, Codable, CaseIterable, Identifiable {
	case next
	case later
	case maybe

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .next: return "Watch Next"
		case .later: return "Watch Later"
		case .maybe: return "Maybe Someday"
		}
	}

	var icon: String {
		switch self {
		case .next: return "text.line.first.and.arrowtriangle.forward"
		case .later: return "clock"
		case .maybe: return "moon.zzz"
		}
	}
}

// A saved video carries list membership (what it's about), a pipeline tier
// (when), and an archived state (live vs kept reference) independently.
struct SavedVideo: Codable, Identifiable {
	let videoId: String
	var title: String
	var channel: String
	var tier: Tier?
	var listIds: [UUID]
	var archived: Bool
	let addedAt: Date

	var id: String { videoId }
}

// Axis 1 (CREATION.md sect. 5): genre -> list -> sub-list. Sub-lists are
// lists with a parentId. youtubePlaylistId records provenance for the
// per-list mirror-back (hybrid model: organize locally, commit to YouTube
// slowly as lists stabilize).
struct Genre: Codable, Identifiable {
	let id: UUID
	var name: String
	var order: Int
}

struct VideoList: Codable, Identifiable {
	let id: UUID
	var name: String
	var genreId: UUID?
	var parentId: UUID?
	var youtubePlaylistId: String?
}

// EricTube's local overlay on top of YouTube's data (CREATION.md sect. 8).
// Plain JSON in Application Support: transparent, greppable, trivially
// backed up. Archive never means delete (sect. 5) — nothing here removes
// a video outright.
@MainActor
final class OverlayStore: ObservableObject {
	static let shared = OverlayStore()

	@Published private(set) var videos: [SavedVideo] = []
	@Published private(set) var lists: [VideoList] = []
	@Published private(set) var genres: [Genre] = []

	private let fileURL: URL

	private struct Snapshot: Codable {
		var videos: [SavedVideo]
		var lists: [VideoList]
		var genres: [Genre]?
	}

	init() {
		let dir = FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("EricTube", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		fileURL = dir.appendingPathComponent("overlay.json")
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		if let data = try? Data(contentsOf: fileURL),
		   let snapshot = try? decoder.decode(Snapshot.self, from: data) {
			videos = snapshot.videos
			lists = snapshot.lists
			genres = snapshot.genres ?? []
		}
	}

	// External tooling (the import-dissolve script) rewrites overlay.json;
	// this rereads it without a relaunch.
	func reload() {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		guard let data = try? Data(contentsOf: fileURL),
		      let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return }
		videos = snapshot.videos
		lists = snapshot.lists
		genres = snapshot.genres ?? []
	}

	func topLists(inGenre genreId: UUID) -> [VideoList] {
		lists.filter { $0.genreId == genreId && $0.parentId == nil }
	}

	func sublists(of listId: UUID) -> [VideoList] {
		lists.filter { $0.parentId == listId }
	}

	var unfiledLists: [VideoList] {
		lists.filter { $0.genreId == nil && $0.parentId == nil }
	}

	func video(for videoId: String) -> SavedVideo? {
		videos.first { $0.videoId == videoId }
	}

	func inTier(_ tier: Tier) -> [SavedVideo] {
		videos.filter { $0.tier == tier && !$0.archived }
	}

	func inList(_ listId: UUID) -> [SavedVideo] {
		videos.filter { $0.listIds.contains(listId) }
	}

	// Upsert: saving an already-known video updates its tier and revives it
	// from the archive; metadata is fetched once, on first save.
	func save(videoId: String, tier: Tier?) {
		if let index = videos.firstIndex(where: { $0.videoId == videoId }) {
			if let tier {
				videos[index].tier = tier
			}
			videos[index].archived = false
		} else {
			videos.append(SavedVideo(
				videoId: videoId, title: "video \(videoId)", channel: "",
				tier: tier, listIds: [], archived: false, addedAt: Date()))
			fetchMetadata(videoId)
		}
		persist()
	}

	func setTier(_ videoId: String, to tier: Tier?) {
		guard let index = videos.firstIndex(where: { $0.videoId == videoId }) else { return }
		videos[index].tier = tier
		persist()
	}

	func addToList(_ videoId: String, listId: UUID) {
		save(videoId: videoId, tier: video(for: videoId)?.tier)
		guard let index = videos.firstIndex(where: { $0.videoId == videoId }) else { return }
		if !videos[index].listIds.contains(listId) {
			videos[index].listIds.append(listId)
			persist()
		}
	}

	// Archiving clears the pipeline but keeps list membership — the video
	// stays findable forever.
	func archive(_ videoId: String) {
		guard let index = videos.firstIndex(where: { $0.videoId == videoId }) else { return }
		videos[index].archived = true
		videos[index].tier = nil
		persist()
	}

	// parentId wins over genreId: a sub-list always inherits its parent
	// chain's genre.
	func createList(named name: String, inGenre genreId: UUID? = nil, under parentId: UUID? = nil) {
		let trimmed = name.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return }
		var genre = genreId
		if let parentId {
			genre = lists.first { $0.id == parentId }?.genreId
		}
		lists.append(VideoList(id: UUID(), name: trimmed, genreId: genre, parentId: parentId, youtubePlaylistId: nil))
		persist()
	}

	// Move = leave the source list, join the target (membership elsewhere
	// untouched). Add stays additive; multi-membership is a feature.
	func moveVideo(_ videoId: String, from sourceListId: UUID, to targetListId: UUID) {
		guard let index = videos.firstIndex(where: { $0.videoId == videoId }) else { return }
		videos[index].listIds.removeAll { $0 == sourceListId }
		if !videos[index].listIds.contains(targetListId) {
			videos[index].listIds.append(targetListId)
		}
		persist()
	}

	func renameGenre(_ genreId: UUID, to name: String) {
		let trimmed = name.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty,
		      let index = genres.firstIndex(where: { $0.id == genreId }),
		      genres[index].name != Self.deletedGenreName else { return }
		genres[index].name = trimmed
		persist()
	}

	// Deleting a genre: empty vanishes; otherwise its lists (structure
	// intact) move to Deleted and the genre goes away. Deleted itself is
	// not deletable.
	func deleteGenre(_ genreId: UUID) {
		guard let genre = genres.first(where: { $0.id == genreId }),
		      genre.name != Self.deletedGenreName else { return }
		let hasLists = lists.contains { $0.genreId == genreId }
		if hasLists {
			let deleted = ensureDeletedGenre()
			for index in lists.indices where lists[index].genreId == genreId {
				lists[index].genreId = deleted
			}
		}
		genres.removeAll { $0.id == genreId }
		persist()
	}

	// Merge: every video and sub-list of the source moves into the
	// destination, then the emptied source is removed. For collapsing
	// redundant lists without moving items one by one.
	func mergeList(_ sourceId: UUID, into targetId: UUID) {
		guard sourceId != targetId,
		      lists.contains(where: { $0.id == sourceId }),
		      let target = lists.first(where: { $0.id == targetId }) else { return }
		var cursor: UUID? = target.parentId
		while let current = cursor {
			if current == sourceId { return }
			cursor = lists.first { $0.id == current }?.parentId
		}
		for index in videos.indices where videos[index].listIds.contains(sourceId) {
			videos[index].listIds.removeAll { $0 == sourceId }
			if !videos[index].listIds.contains(targetId) {
				videos[index].listIds.append(targetId)
			}
		}
		for index in lists.indices where lists[index].parentId == sourceId {
			lists[index].parentId = targetId
			lists[index].genreId = target.genreId
			propagateGenre(from: lists[index].id, genreId: target.genreId)
		}
		lists.removeAll { $0.id == sourceId }
		persist()
	}

	func renameList(_ listId: UUID, to name: String) {
		let trimmed = name.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty,
		      let index = lists.firstIndex(where: { $0.id == listId }) else { return }
		lists[index].name = trimmed
		persist()
	}

	// Arrange mode: drop a list on a genre header -> top-level in that
	// genre; drop on another list -> become its sub-list. Sub-lists always
	// inherit the parent chain's genre.
	func moveList(_ listId: UUID, toGenre genreId: UUID?) {
		guard let index = lists.firstIndex(where: { $0.id == listId }) else { return }
		lists[index].genreId = genreId
		lists[index].parentId = nil
		propagateGenre(from: listId, genreId: genreId)
		persist()
	}

	func nestList(_ listId: UUID, under parentId: UUID) {
		guard listId != parentId,
		      let parentIndex = lists.firstIndex(where: { $0.id == parentId }),
		      let index = lists.firstIndex(where: { $0.id == listId }) else { return }
		var cursor: UUID? = parentId
		while let current = cursor {
			if current == listId { return }
			cursor = lists.first { $0.id == current }?.parentId
		}
		lists[index].parentId = parentId
		lists[index].genreId = lists[parentIndex].genreId
		propagateGenre(from: listId, genreId: lists[parentIndex].genreId)
		persist()
	}

	private func propagateGenre(from listId: UUID, genreId: UUID?) {
		for index in lists.indices where lists[index].parentId == listId {
			lists[index].genreId = genreId
			propagateGenre(from: lists[index].id, genreId: genreId)
		}
	}

	// "Deleted" is a special genre pinned to the bottom: deleting a list
	// moves it there with its subtree and videos grouped intact, to be
	// picked away at (or rescued) later. Created on first use.
	static let deletedGenreName = "Deleted"

	func isInDeletedGenre(_ list: VideoList) -> Bool {
		guard let deleted = genres.first(where: { $0.name == Self.deletedGenreName }) else { return false }
		return list.genreId == deleted.id
	}

	private func ensureDeletedGenre() -> UUID {
		if let existing = genres.first(where: { $0.name == Self.deletedGenreName }) {
			return existing.id
		}
		let genre = Genre(id: UUID(), name: Self.deletedGenreName, order: 9999)
		genres.append(genre)
		return genre.id
	}

	// Edit-mode delete: empty lists just vanish; anything with content moves
	// (subtree and all) to the Deleted genre. Nothing loses videos here.
	func deleteList(_ listId: UUID) {
		guard let index = lists.firstIndex(where: { $0.id == listId }) else { return }
		if inList(listId).isEmpty && sublists(of: listId).isEmpty {
			lists.remove(at: index)
		} else {
			let deleted = ensureDeletedGenre()
			lists[index].parentId = nil
			lists[index].genreId = deleted
			propagateGenre(from: listId, genreId: deleted)
		}
		persist()
	}

	// Permanent removal (offered only inside Deleted): the subtree goes,
	// member videos lose those memberships, and records left with no
	// membership and no tier are dropped.
	func destroyList(_ listId: UUID) {
		var doomed: Set<UUID> = []
		func collect(_ id: UUID) {
			doomed.insert(id)
			for child in sublists(of: id) {
				collect(child.id)
			}
		}
		collect(listId)
		lists.removeAll { doomed.contains($0.id) }
		videos = videos.compactMap { video in
			var video = video
			let wasMember = video.listIds.contains { doomed.contains($0) }
			video.listIds.removeAll { doomed.contains($0) }
			if wasMember && video.listIds.isEmpty && video.tier == nil {
				return nil
			}
			return video
		}
		persist()
	}

	private func persist() {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		encoder.dateEncodingStrategy = .iso8601
		if let data = try? encoder.encode(Snapshot(videos: videos, lists: lists, genres: genres)) {
			try? data.write(to: fileURL, options: .atomic)
		}
	}

	// Title/channel via YouTube's public oEmbed endpoint — metadata only,
	// no auth, no page driving.
	private func fetchMetadata(_ videoId: String) {
		struct OEmbed: Codable {
			let title: String
			let author_name: String
		}
		guard let url = URL(string:
			"https://www.youtube.com/oembed?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D\(videoId)&format=json")
		else { return }
		Task { [weak self] in
			guard let (data, _) = try? await URLSession.shared.data(from: url),
			      let meta = try? JSONDecoder().decode(OEmbed.self, from: data),
			      let self,
			      let index = self.videos.firstIndex(where: { $0.videoId == videoId })
			else { return }
			self.videos[index].title = meta.title
			self.videos[index].channel = meta.author_name
			self.persist()
		}
	}
}
