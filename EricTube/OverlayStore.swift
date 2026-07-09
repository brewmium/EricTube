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

	func createList(named name: String) {
		let trimmed = name.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return }
		lists.append(VideoList(id: UUID(), name: trimmed, genreId: nil, parentId: nil, youtubePlaylistId: nil))
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
