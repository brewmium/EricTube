import WebKit

enum SessionKey: Hashable {
	case master
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

	@Published var active: SessionKey = .master {
		didSet { scheduleSnapshot() }
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
	private var masterStartURL = URL(string: "https://www.youtube.com/")!

	// Home base (CREATION.md sect. 4): created once, never torn down by
	// SwiftUI view churn, so it never reloads or loses its place.
	private(set) lazy var masterWebView: WKWebView =
		makeWebView(kind: "master", url: masterStartURL)

	init() {
		NowPlayingBridge.shared.configure()
		restoreSession()
	}

	var activeWebView: WKWebView {
		switch active {
		case .master:
			return masterWebView
		case .music:
			return musicWebView ?? masterWebView
		case .watch(let id):
			return watchSessions.first { $0.id == id }?.webView ?? masterWebView
		}
	}

	// Every session that must stay mounted (hidden, not torn down) so
	// playback and page state survive switching away.
	var displayed: [DisplayedSession] {
		var list = [DisplayedSession(key: .master, webView: masterWebView)]
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
	func openWatchTab(videoId raw: String) {
		let videoId = raw.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
		guard !videoId.isEmpty else { return }
		var path = "/watch?v=\(videoId)"
		if let seconds = ProgressStore.shared.resumeSeconds(for: videoId) {
			path += "&t=\(Int(seconds))s"
		}
		openTab(path: path)
	}

	// Any youtube.com path (watch, channel, playlist) as an ephemeral tab,
	// via the warm pool when one is ready.
	func openTab(path: String) {
		paletteRequest = nil
		let webView: WKWebView
		if let recycled = parked.popLast() {
			webView = recycled
		} else {
			webView = makeWebView(kind: "watch", url: nil)
		}
		if !webView.isLoading, webView.url?.host?.hasSuffix("youtube.com") == true {
			webView.evaluateJavaScript(Injection.spaNavigate(path: path), completionHandler: nil)
		} else {
			webView.load(URLRequest(url: URL(string: "https://www.youtube.com\(path)")!))
		}

		let session = WatchSession(webView: webView)
		watchSessions.append(session)
		active = .watch(session.id)
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

	func closeWatchTab(_ session: WatchSession) {
		watchSessions.removeAll { $0.id == session.id }
		audible.remove(ObjectIdentifier(session.webView))
		if active == .watch(session.id) {
			active = .master
		}
		if parked.isEmpty {
			// SPA-hop home: stops playback and keeps the view warm.
			session.webView.evaluateJavaScript(Injection.spaNavigate(path: "/"), completionHandler: nil)
			parked.append(session.webView)
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
		var activeKey = "master"
		switch active {
		case .master:
			activeKey = "master"
		case .music:
			activeKey = "music"
		case .watch(let id):
			if let index = watchSessions.firstIndex(where: { $0.id == id }) {
				activeKey = "tab:\(index)"
			}
		}
		let snapshot = SessionSnapshot(
			masterURL: masterWebView.url?.absoluteString,
			musicURL: musicWebView?.url?.absoluteString,
			tabURLs: watchSessions.compactMap { $0.webView.url?.absoluteString },
			active: activeKey)
		if let data = try? JSONEncoder().encode(snapshot) {
			UserDefaults.standard.set(data, forKey: "sessionSnapshot")
		}
	}

	// Tabs come back at their saved position (t=) but paused — no surprise
	// audio, no Premium stream steal.
	private func restoreSession() {
		guard let data = UserDefaults.standard.data(forKey: "sessionSnapshot"),
		      let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data)
		else { return }
		restoring = true
		defer { restoring = false }

		if let master = snapshot.masterURL, let url = URL(string: master) {
			masterStartURL = url
		}
		if let music = snapshot.musicURL, let url = URL(string: music) {
			musicWebView = makeWebView(kind: "music", url: url)
		}
		for tabURL in snapshot.tabURLs {
			guard var components = URLComponents(string: tabURL) else { continue }
			if components.path == "/watch",
			   let videoId = components.queryItems?.first(where: { $0.name == "v" })?.value,
			   let seconds = ProgressStore.shared.resumeSeconds(for: videoId) {
				var items = components.queryItems ?? []
				items.removeAll { $0.name == "t" }
				items.append(URLQueryItem(name: "t", value: "\(Int(seconds))s"))
				components.queryItems = items
			}
			guard let url = components.url else { continue }
			let webView = makeWebView(kind: "watch", url: url, restorePaused: true)
			watchSessions.append(WatchSession(webView: webView))
		}
		switch snapshot.active {
		case "music" where musicWebView != nil:
			active = .music
		case let key where key.hasPrefix("tab:"):
			if let index = Int(key.dropFirst(4)), watchSessions.indices.contains(index) {
				active = .watch(watchSessions[index].id)
			}
		default:
			active = .master
		}
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
