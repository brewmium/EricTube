import Foundation

struct SubChannel: Codable, Identifiable {
	let id: String
	let title: String
}

struct ImportedItem: Codable, Identifiable {
	let videoId: String
	let title: String
	let channelTitle: String

	var id: String { videoId }
}

struct ImportedPlaylist: Codable, Identifiable {
	let id: String
	var title: String
	var itemCount: Int
	var items: [ImportedItem]
}

// Phase 2 (CREATION.md sect. 8): pull everything Eric already has —
// subscriptions, playlists, playlist contents — and keep it raw. The
// list/sub-list design session runs on this data; nothing here interprets.
@MainActor
final class YouTubeImporter: ObservableObject {
	static let shared = YouTubeImporter()

	enum Status: Equatable {
		case idle
		case working(String)
		case done(Date)
		case failed(String)
	}

	@Published private(set) var status: Status = .idle
	@Published private(set) var subscriptions: [SubChannel] = []
	@Published private(set) var playlists: [ImportedPlaylist] = []

	private let fileURL: URL

	private struct Snapshot: Codable {
		var fetchedAt: Date
		var subscriptions: [SubChannel]
		var playlists: [ImportedPlaylist]
	}

	init() {
		fileURL = FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("EricTube", isDirectory: true)
			.appendingPathComponent("imported.json")
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		if let data = try? Data(contentsOf: fileURL),
		   let snapshot = try? decoder.decode(Snapshot.self, from: data) {
			subscriptions = snapshot.subscriptions
			playlists = snapshot.playlists
			status = .done(snapshot.fetchedAt)
		}
	}

	var isWorking: Bool {
		if case .working = status { return true }
		return false
	}

	func startImport() {
		guard !isWorking else { return }
		Task { await run() }
	}

	private func run() async {
		do {
			if !GoogleAuth.shared.isAuthorized {
				status = .working("waiting for Google sign-in in your browser...")
				try await GoogleAuth.shared.authorize()
			}
			status = .working("subscriptions...")
			subscriptions = try await fetchSubscriptions()
			status = .working("playlists...")
			var lists = try await fetchPlaylists()
			for index in lists.indices {
				status = .working("\(lists[index].title) (\(index + 1)/\(lists.count))")
				lists[index].items = try await fetchItems(playlistId: lists[index].id)
			}
			playlists = lists
			persist()
			status = .done(Date())
		} catch {
			status = .failed(error.localizedDescription)
		}
	}

	// MARK: - Data API

	private struct Page<Item: Decodable>: Decodable {
		let items: [Item]?
		let nextPageToken: String?
	}

	private struct SubscriptionItem: Decodable {
		struct Snippet: Decodable {
			struct Resource: Decodable {
				let channelId: String
			}
			let title: String
			let resourceId: Resource
		}
		let snippet: Snippet
	}

	private struct PlaylistItem: Decodable {
		struct Snippet: Decodable {
			let title: String
		}
		struct ContentDetails: Decodable {
			let itemCount: Int
		}
		let id: String
		let snippet: Snippet
		let contentDetails: ContentDetails
	}

	private struct PlaylistEntryItem: Decodable {
		struct Snippet: Decodable {
			let title: String
			let videoOwnerChannelTitle: String?
		}
		struct ContentDetails: Decodable {
			let videoId: String
		}
		let snippet: Snippet
		let contentDetails: ContentDetails
	}

	private func fetchSubscriptions() async throws -> [SubChannel] {
		try await fetchAll("subscriptions", params: ["part": "snippet", "mine": "true"]) {
			(item: SubscriptionItem) in
			SubChannel(id: item.snippet.resourceId.channelId, title: item.snippet.title)
		}
	}

	private func fetchPlaylists() async throws -> [ImportedPlaylist] {
		try await fetchAll("playlists", params: ["part": "snippet,contentDetails", "mine": "true"]) {
			(item: PlaylistItem) in
			ImportedPlaylist(
				id: item.id, title: item.snippet.title,
				itemCount: item.contentDetails.itemCount, items: [])
		}
	}

	private func fetchItems(playlistId: String) async throws -> [ImportedItem] {
		try await fetchAll("playlistItems", params: ["part": "snippet,contentDetails", "playlistId": playlistId]) {
			(item: PlaylistEntryItem) in
			ImportedItem(
				videoId: item.contentDetails.videoId,
				title: item.snippet.title,
				channelTitle: item.snippet.videoOwnerChannelTitle ?? "")
		}
	}

	private func fetchAll<Item: Decodable, Output>(
		_ resource: String,
		params: [String: String],
		transform: (Item) -> Output
	) async throws -> [Output] {
		var results: [Output] = []
		var pageToken: String?
		repeat {
			var query = params
			query["maxResults"] = "50"
			if let pageToken {
				query["pageToken"] = pageToken
			}
			let page: Page<Item> = try await request(resource, params: query)
			results.append(contentsOf: (page.items ?? []).map(transform))
			pageToken = page.nextPageToken
		} while pageToken != nil
		return results
	}

	private func request<Response: Decodable>(_ resource: String, params: [String: String]) async throws -> Response {
		let token = try await GoogleAuth.shared.validAccessToken()
		var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/\(resource)")!
		components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
		var request = URLRequest(url: components.url!)
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		let (data, response) = try await URLSession.shared.data(for: request)
		let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
		guard statusCode == 200 else {
			throw OAuthError.denied("\(resource) HTTP \(statusCode): \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
		}
		return try JSONDecoder().decode(Response.self, from: data)
	}

	private func persist() {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		encoder.dateEncodingStrategy = .iso8601
		let snapshot = Snapshot(fetchedAt: Date(), subscriptions: subscriptions, playlists: playlists)
		if let data = try? encoder.encode(snapshot) {
			try? data.write(to: fileURL, options: .atomic)
		}
	}
}
