import Foundation

struct WatchProgress: Codable, Identifiable {
	let videoId: String
	var title: String
	var seconds: Double
	var duration: Double
	var lastWatchedAt: Date
	var completed: Bool

	var id: String { videoId }

	var fraction: Double {
		duration > 0 ? min(1, seconds / duration) : 0
	}
}

// The true "in progress" history YouTube won't give us: every watch
// position, updated live from the pages, surviving relaunches. Deliberately
// separate from the overlay — progress applies to anything watched, saved
// or not, and churns too much to share a file with the library.
@MainActor
final class ProgressStore: ObservableObject {
	static let shared = ProgressStore()

	@Published private(set) var records: [String: WatchProgress] = [:]

	// A video counts as watched once it's within this many seconds of the end
	// (default 10) — so near-finished videos leave Continue for the history
	// instead of forcing manual cleanup. Tunable in Settings.
	static var watchedThreshold: Double {
		UserDefaults.standard.object(forKey: "watchedThreshold") as? Double ?? 10
	}

	private let fileURL: URL

	init() {
		fileURL = FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("EricTube", isDirectory: true)
			.appendingPathComponent("progress.json")
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		if let data = try? Data(contentsOf: fileURL),
		   let stored = try? decoder.decode([String: WatchProgress].self, from: data) {
			records = stored
		}
	}

	// Excluded by design: music session (endless mixes), shorts, and live
	// streams (duration 0) — they'd flood the list with meaningless rows.
	func record(videoId: String, title: String, seconds: Double, duration: Double, path: String, sessionKind: String) {
		guard sessionKind != "music", duration > 0, !path.hasPrefix("/shorts") else { return }
		guard seconds > 5 else { return }
		// Junk titles ("YouTube", empty) never overwrite a good one; on
		// first sight, borrow the library's title if the video is known.
		let junkTitle = title.isEmpty || title == "YouTube"
		let initialTitle = junkTitle
			? (OverlayStore.shared.video(for: videoId)?.title ?? "(untitled)")
			: title
		var entry = records[videoId] ?? WatchProgress(
			videoId: videoId, title: initialTitle, seconds: seconds,
			duration: duration, lastWatchedAt: Date(), completed: false)
		if !junkTitle {
			entry.title = title
		}
		entry.seconds = seconds
		entry.duration = duration
		entry.lastWatchedAt = Date()
		if entry.duration - entry.seconds <= Self.watchedThreshold {
			entry.completed = true
		}
		records[videoId] = entry
		persist()
	}

	// "Continue" candidates: started, not finished, most recent first.
	var inProgress: [WatchProgress] {
		records.values
			.filter { !$0.completed && $0.seconds > 15 }
			.sorted { $0.lastWatchedAt > $1.lastWatchedAt }
	}

	// The local watch history: finished videos, most recent first.
	var watched: [WatchProgress] {
		records.values
			.filter { $0.completed }
			.sorted { $0.lastWatchedAt > $1.lastWatchedAt }
	}

	func resumeSeconds(for videoId: String) -> Double? {
		guard let entry = records[videoId], !entry.completed, entry.seconds > 15 else { return nil }
		return entry.seconds
	}

	// Dismissed rows leave the Continue list but the record stays (no-loss;
	// someday this is the watch-history view).
	func dismiss(_ videoId: String) {
		guard var entry = records[videoId] else { return }
		entry.completed = true
		records[videoId] = entry
		persist()
	}

	// Hard removal from the watch history (Continue's dismiss only completes).
	func delete(_ videoId: String) {
		records.removeValue(forKey: videoId)
		persist()
	}

	// Clear the done flag so a video resurfaces in Continue (dragged back).
	func uncomplete(_ videoId: String) {
		guard var entry = records[videoId] else { return }
		entry.completed = false
		records[videoId] = entry
		persist()
	}

	private func persist() {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		encoder.dateEncodingStrategy = .iso8601
		if let data = try? encoder.encode(records) {
			try? data.write(to: fileURL, options: .atomic)
		}
	}
}
