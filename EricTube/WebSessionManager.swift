import WebKit

enum SessionKey: Hashable {
	case music
	case watch(UUID)
}

struct WatchSession: Identifiable {
	let id = UUID()
	let webView: WKWebView
}

struct PaletteRequest: Identifiable {
	let id = UUID()
	let videoId: String
	let anchor: CGRect
}

struct DisplayedSession: Identifiable {
	let key: SessionKey
	let webView: WKWebView
	var id: SessionKey { key }
}

// One login everywhere: every web view EricTube ever creates (master, music,
// watch tabs, warm pool) shares this one persistent data store and process
// pool, so the YouTube sign-in done once in any of them applies to all of
// them and survives relaunch (CREATION.md sect. 3).
@MainActor
final class WebSessionManager: ObservableObject {
	static let shared = WebSessionManager()

	let dataStore: WKWebsiteDataStore = .default()
	private let processPool = WKProcessPool()

	// A throwaway until init selects a real session; never matches a session.
	private static let placeholderID = UUID()

	@Published var active: SessionKey = .watch(WebSessionManager.placeholderID) {
		didSet {
			if oldValue != active {
				pauseOnLeave(oldValue)
				playOnEnter(active)
			}
			scheduleSnapshot()
		}
	}

	// The concurrency policy (CREATION.md sect. 9): switching away pauses
	// the session you left, unless background play is on. Music is always
	// exempt — background audio is its entire purpose.
	@Published var playInBackground: Bool =
		UserDefaults.standard.bool(forKey: "playInBackground") {
		didSet { UserDefaults.standard.set(playInBackground, forKey: "playInBackground") }
	}

	// Settings toggles. Theater mode is a preference (default on) rather than
	// a hard rule; changing it re-applies live to every mounted view.
	@Published var preferTheater: Bool =
		UserDefaults.standard.object(forKey: "preferTheater") as? Bool ?? true {
		didSet {
			UserDefaults.standard.set(preferTheater, forKey: "preferTheater")
			let js = Injection.setTheater(preferTheater)
			for entry in displayed { entry.webView.evaluateJavaScript(js, completionHandler: nil) }
			for webView in parked { webView.evaluateJavaScript(js, completionHandler: nil) }
		}
	}

	// When on, activating a session (tapping a tab, or opening a video into a
	// tab from the palette) jumps to it and starts playback.
	@Published var autoplayOnSelect: Bool =
		UserDefaults.standard.bool(forKey: "autoplayOnSelect") {
		didSet { UserDefaults.standard.set(autoplayOnSelect, forKey: "autoplayOnSelect") }
	}
	@Published var paletteRequest: PaletteRequest?
	@Published private(set) var watchSessions: [WatchSession] = []
	@Published private(set) var musicWebView: WKWebView?
	@Published private(set) var audible: Set<ObjectIdentifier> = []
	@Published private(set) var pageZoom: Double =
		UserDefaults.standard.object(forKey: "pageZoom") as? Double ?? 1.0

	// Warm pool: parked web views already sitting on youtube.com, so
	// spawning a watch tab is an SPA hop instead of a cold page load.
	// Capped at one — each live view is its own web content process.
	private var parked: [WKWebView] = []

	private var restoring = false

	// Never-hit safety net for activeWebView (the invariant keeps at least one
	// session alive, so this stays uncreated).
	private lazy var emergencyWebView: WKWebView =
		makeWebView(kind: "watch", url: URL(string: "https://www.youtube.com/"))

	init() {
		NowPlayingBridge.shared.configure()
		restoreSession()
		// Every session is a normal, closable one now — no special home base.
		// Guarantee the list is never empty and the selection resolves.
		if watchSessions.isEmpty {
			openTab(path: "/", activate: true)
		} else if webView(for: active) == nil, let first = watchSessions.first {
			active = .watch(first.id)
		}
	}

	var activeWebView: WKWebView {
		webView(for: active) ?? watchSessions.first?.webView ?? emergencyWebView
	}

	private func webView(for key: SessionKey) -> WKWebView? {
		switch key {
		case .music:
			return musicWebView
		case .watch(let id):
			return watchSessions.first { $0.id == id }?.webView
		}
	}

	private func pauseOnLeave(_ key: SessionKey) {
		guard !restoring, !playInBackground, key != .music else { return }
		webView(for: key)?.evaluateJavaScript(Injection.pauseNow, completionHandler: nil)
	}

	// Bringing a session to the front (post-launch) frees its pause hold so it
	// can play; with autoplay-on-select it also starts playing. On launch
	// (restoring) neither fires — restored sessions stay held until the user
	// clicks into them, so nothing autoplays.
	private func playOnEnter(_ key: SessionKey) {
		guard !restoring else { return }
		let webView = webView(for: key)
		webView?.evaluateJavaScript(Injection.releasePause, completionHandler: nil)
		if autoplayOnSelect {
			webView?.evaluateJavaScript(Injection.playNow, completionHandler: nil)
		}
	}

	// Every session that must stay mounted (hidden, not torn down) so
	// playback and page state survive switching away.
	var displayed: [DisplayedSession] {
		var list: [DisplayedSession] = []
		if let musicWebView {
			list.append(DisplayedSession(key: .music, webView: musicWebView))
		}
		for session in watchSessions {
			list.append(DisplayedSession(key: .watch(session.id), webView: session.webView))
		}
		return list
	}

	// The music session presents as a smart list + jump button, but playback
	// needs a persistent page to live in; created on first jump. The landing
	// page is a parking spot until playlist import (Phase 2).
	func showMusic() {
		if musicWebView == nil {
			musicWebView = makeWebView(kind: "music", url: URL(string: "https://www.youtube.com/feed/playlists")!)
		}
		active = .music
	}

	// Called when the palette opens — user intent to spawn a tab is the
	// signal to start warming a view for it.
	func prewarm() {
		guard parked.isEmpty else { return }
		parked.append(makeWebView(kind: "watch", url: URL(string: "https://www.youtube.com/")!))
	}

	// Opening a video with recorded progress resumes where it left off.
	// If the video is already open as a tab, switch to it (or, for a
	// background open, leave it be) instead of spawning a twin.
	func openWatchTab(videoId raw: String, activate: Bool = true) {
		let videoId = raw.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
		guard !videoId.isEmpty else { return }
		if let existing = watchSessions.first(where: { currentVideoId(of: $0.webView) == videoId }) {
			paletteRequest = nil
			if activate {
				active = .watch(existing.id)
			}
			return
		}
		var path = "/watch?v=\(videoId)"
		if let seconds = ProgressStore.shared.resumeSeconds(for: videoId) {
			path += "&t=\(Int(seconds))s"
		}
		openTab(path: path, activate: activate)
	}

	func currentVideoId(of webView: WKWebView) -> String? {
		guard let url = webView.url,
		      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
		      components.path == "/watch" else { return nil }
		return components.queryItems?.first { $0.name == "v" }?.value
	}

	// Any youtube.com path (watch, channel, playlist) as an ephemeral tab,
	// via the warm pool when one is ready. Background opens (activate
	// false) stay on the current session and arm a one-shot pause so the
	// new tab loads ready-but-silent.
	func openTab(path: String, activate: Bool = true) {
		paletteRequest = nil
		let fullURL = URL(string: "https://www.youtube.com\(path)")!
		let webView: WKWebView
		if let recycled = parked.last,
		   !recycled.isLoading, recycled.url?.host?.hasSuffix("youtube.com") == true {
			parked.removeLast()
			if !activate {
				recycled.evaluateJavaScript(Injection.armPause, completionHandler: nil)
			}
			recycled.evaluateJavaScript(Injection.spaNavigate(path: path), completionHandler: nil)
			webView = recycled
		} else {
			// A cold load can't be pause-armed mid-flight, so background
			// opens always get a fresh, pre-armed view.
			webView = makeWebView(kind: "watch", url: fullURL, restorePaused: !activate)
		}

		let session = WatchSession(webView: webView)
		// Newest on top: sessions read newest -> oldest down the list.
		watchSessions.insert(session, at: 0)
		if activate {
			active = .watch(session.id)
		}
		scheduleSnapshot()
	}

	// The "+" in the Sessions header: a fresh youtube.com session, activated.
	func newSession() {
		openTab(path: "/", activate: true)
	}

	// Reorder a session within the list (drag to reorder). If the video isn't
	// an open session, open it (lands on top).
	func moveSession(_ videoId: String, toIndex: Int) {
		guard let from = watchSessions.firstIndex(where: {
			currentVideoId(of: $0.webView) == videoId
		}) else {
			openWatchTab(videoId: videoId)
			return
		}
		let session = watchSessions.remove(at: from)
		var target = toIndex
		if from < target { target -= 1 }
		target = max(0, min(watchSessions.count, target))
		watchSessions.insert(session, at: target)
		scheduleSnapshot()
	}

	func isAudible(_ webView: WKWebView?) -> Bool {
		guard let webView else { return false }
		return audible.contains(ObjectIdentifier(webView))
	}

	// Browser-style zoom, one global level applied to every session,
	// persisted per machine. nil resets to 100%.
	func adjustZoom(by delta: Double?) {
		let zoom = delta.map { max(0.5, min(3.0, pageZoom + $0)) } ?? 1.0
		pageZoom = zoom
		UserDefaults.standard.set(zoom, forKey: "pageZoom")
		for entry in displayed {
			entry.webView.pageZoom = zoom
		}
		for webView in parked {
			webView.pageZoom = zoom
		}
	}

	// Close any open watch tab currently showing this video (used when a
	// video is dragged out of Sessions into a saved tier).
	func closeSession(forVideoId videoId: String) {
		for session in watchSessions where currentVideoId(of: session.webView) == videoId {
			closeWatchTab(session)
		}
	}

	func closeWatchTab(_ session: WatchSession) {
		let wasActive = (active == .watch(session.id))
		watchSessions.removeAll { $0.id == session.id }
		audible.remove(ObjectIdentifier(session.webView))
		if parked.isEmpty {
			// SPA-hop home: stops playback and keeps the view warm.
			session.webView.evaluateJavaScript(Injection.spaNavigate(path: "/"), completionHandler: nil)
			parked.append(session.webView)
		}
		if watchSessions.isEmpty {
			// Never leave the list empty — spawn a fresh generic YouTube
			// session (it becomes active).
			openTab(path: "/", activate: true)
		} else if wasActive {
			// Closing the selected session hands focus to the top one.
			active = .watch(watchSessions[0].id)
		}
		scheduleSnapshot()
	}

	func handleScriptMessage(_ message: WKScriptMessage) {
		guard let body = message.body as? [String: Any],
		      let kind = body["kind"] as? String else { return }
		switch kind {
		case "chip":
			guard let videoId = body["videoId"] as? String,
			      let x = body["x"] as? Double, let y = body["y"] as? Double,
			      let w = body["w"] as? Double, let h = body["h"] as? Double
			else { return }
			prewarm()
			paletteRequest = PaletteRequest(
				videoId: videoId,
				anchor: CGRect(x: x, y: y, width: w, height: h))
		case "media":
			guard let webView = message.webView,
			      let playing = body["playing"] as? Bool else { return }
			if playing {
				audible.insert(ObjectIdentifier(webView))
			} else {
				audible.remove(ObjectIdentifier(webView))
			}
		case "progress":
			guard let webView = message.webView,
			      let videoId = body["videoId"] as? String,
			      let title = body["title"] as? String,
			      let seconds = body["seconds"] as? Double,
			      let duration = body["duration"] as? Double,
			      let playing = body["playing"] as? Bool
			else { return }
			let cleanTitle = title.strippedYouTubeSuffix
			NowPlayingBridge.shared.update(
				title: cleanTitle, seconds: seconds, duration: duration,
				playing: playing, webView: webView)
			ProgressStore.shared.record(
				videoId: videoId, title: cleanTitle, seconds: seconds,
				duration: duration,
				path: body["path"] as? String ?? "",
				sessionKind: body["sessionKind"] as? String ?? "")
			scheduleSnapshot()
		default:
			break
		}
	}

	// MARK: - Session snapshot & restore

	private struct SessionSnapshot: Codable {
		var masterURL: String?
		var musicURL: String?
		var tabURLs: [String]
		var active: String
	}

	// Persisted continuously (tab ops, session switches, progress beats) so
	// a relaunch — deliberate or not — can rebuild the moment.
	private func scheduleSnapshot() {
		guard !restoring else { return }
		var activeKey = "tab:0"
		switch active {
		case .music:
			activeKey = "music"
		case .watch(let id):
			if let index = watchSessions.firstIndex(where: { $0.id == id }) {
				activeKey = "tab:\(index)"
			}
		}
		let snapshot = SessionSnapshot(
			masterURL: nil,   // no special session anymore
			musicURL: musicWebView?.url?.absoluteString,
			tabURLs: watchSessions.compactMap { $0.webView.url?.absoluteString },
			active: activeKey)
		if let data = try? JSONEncoder().encode(snapshot) {
			UserDefaults.standard.set(data, forKey: "sessionSnapshot")
		}
	}

	// Everything comes back at its saved position (t=) but paused (the restore
	// hold suppresses autoplay). All sessions are equal — the legacy master
	// URL, if present in an old snapshot, is just restored as the first one.
	private func restoreSession() {
		guard let data = UserDefaults.standard.data(forKey: "sessionSnapshot"),
		      let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data)
		else { return }
		restoring = true
		defer { restoring = false }

		if let music = snapshot.musicURL, let restored = resumeURL(from: music) {
			musicWebView = makeWebView(kind: "music", url: restored.url, restorePaused: restored.isWatch)
		}
		// Legacy master URL (old snapshots) becomes the first session.
		var sessionURLs: [String] = []
		if let master = snapshot.masterURL { sessionURLs.append(master) }
		sessionURLs.append(contentsOf: snapshot.tabURLs)
		for urlString in sessionURLs {
			guard let restored = resumeURL(from: urlString) else { continue }
			let webView = makeWebView(kind: "watch", url: restored.url, restorePaused: true)
			watchSessions.append(WatchSession(webView: webView))
		}
		// Restore the selection. Legacy "tab:N"/"master" indices predate the
		// prepended master session, so offset them by one.
		let legacyOffset = snapshot.masterURL != nil ? 1 : 0
		switch snapshot.active {
		case "music" where musicWebView != nil:
			active = .music
		case "master":
			if let first = watchSessions.first { active = .watch(first.id) }
		case let key where key.hasPrefix("tab:"):
			let index = (Int(key.dropFirst(4)) ?? 0) + legacyOffset
			if watchSessions.indices.contains(index) {
				active = .watch(watchSessions[index].id)
			} else if let first = watchSessions.first {
				active = .watch(first.id)
			}
		default:
			if let first = watchSessions.first { active = .watch(first.id) }
		}
	}

	// Rewrites a /watch URL to resume at the recorded position.
	private func resumeURL(from urlString: String) -> (url: URL, isWatch: Bool)? {
		guard var components = URLComponents(string: urlString) else { return nil }
		let isWatch = components.path == "/watch"
		if isWatch,
		   let videoId = components.queryItems?.first(where: { $0.name == "v" })?.value,
		   let seconds = ProgressStore.shared.resumeSeconds(for: videoId) {
			var items = components.queryItems ?? []
			items.removeAll { $0.name == "t" }
			items.append(URLQueryItem(name: "t", value: "\(Int(seconds))s"))
			components.queryItems = items
		}
		guard let url = components.url else { return nil }
		return (url, isWatch)
	}

	private func makeWebView(kind: String, url: URL?, restorePaused: Bool = false) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.websiteDataStore = dataStore
		config.processPool = processPool
		// accounts.google.com refuses sign-in from web views it doesn't
		// recognize as a real browser; present the stock Safari UA.
		config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
		config.mediaTypesRequiringUserActionForPlayback = []

		let controller = config.userContentController
		controller.add(MessageProxy(manager: self), name: Injection.messageName)
		controller.addUserScript(WKUserScript(
			source: Injection.kindScript(kind), injectionTime: .atDocumentStart, forMainFrameOnly: true))
		controller.addUserScript(WKUserScript(
			source: "window.__erictubePreferTheater = \(preferTheater ? "true" : "false");",
			injectionTime: .atDocumentStart, forMainFrameOnly: true))
		if restorePaused {
			controller.addUserScript(WKUserScript(
				source: "window.__erictubeRestorePause = true;",
				injectionTime: .atDocumentStart, forMainFrameOnly: true))
		}
		controller.addUserScript(WKUserScript(
			source: Injection.chipScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
		controller.addUserScript(WKUserScript(
			source: Injection.theaterScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
		controller.addUserScript(WKUserScript(
			source: Injection.mediaScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
		controller.addUserScript(WKUserScript(
			source: Injection.progressScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
		controller.addUserScript(WKUserScript(
			source: Injection.restorePauseScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

		let webView = WKWebView(frame: .zero, configuration: config)
		webView.allowsBackForwardNavigationGestures = true
		webView.allowsMagnification = true
		webView.isInspectable = true
		webView.pageZoom = pageZoom
		if let url {
			webView.load(URLRequest(url: url))
		}
		return webView
	}
}

// WKUserContentController retains its handlers strongly; this proxy keeps
// the manager out of that cycle.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
	weak var manager: WebSessionManager?

	init(manager: WebSessionManager) {
		self.manager = manager
	}

	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
		MainActor.assumeIsolated {
			manager?.handleScriptMessage(message)
		}
	}
}
