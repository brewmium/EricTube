import WebKit

enum SessionKey: Hashable {
	case music
	case watch(UUID)
}

// A tab is a record first: where it is, what it's called, where playback
// stood. The web view is optional — only a few tabs are live at once (the
// active one, the kept-live ones, and the one you just left); the rest are
// cold records that load on their next visit. Every live view is its own
// web content process, and 40+ mounted YouTube pages made resizes crawl and
// starved the shared GPU process until playback errored app-wide.
struct WatchSession: Identifiable {
	let id: UUID
	var webView: WKWebView?
	var url: URL
	var title: String
	// Last reported playback spot, paired with the video it belongs to so an
	// SPA hop to another video can't resume that one at this one's time.
	var positionVideoId: String?
	var seconds: Double?
	// The veil level. New sessions are born uncovered (tried born-covered
	// first; it read as broken) — the veil is opt-in per session. Restored
	// sessions carry their saved level.
	var coverAlpha: Double = 0.0
	// Kept live in the background (the row's speaker toggle). Set
	// automatically when you leave a tab while it's playing; survives
	// relaunch (the tab comes back live, but held paused).
	var keepLive = false

	init(id: UUID = UUID(), webView: WKWebView? = nil, url: URL, title: String,
	     positionVideoId: String? = nil, seconds: Double? = nil,
	     coverAlpha: Double = 0.0, keepLive: Bool = false) {
		self.id = id
		self.webView = webView
		self.url = url
		self.title = title
		self.positionVideoId = positionVideoId
		self.seconds = seconds
		self.coverAlpha = coverAlpha
		self.keepLive = keepLive
	}

	var videoId: String? { WebSessionManager.videoId(in: url) }
}

struct PaletteRequest: Identifiable {
	let id = UUID()
	let videoId: String
	let title: String?
	let anchor: CGRect
}

struct DisplayedSession: Identifiable {
	let key: SessionKey
	let webView: WKWebView
	// Keyed by the view, not the session: a tab that went cold and woke
	// again has a new web view, which must mount fresh.
	var id: ObjectIdentifier { ObjectIdentifier(webView) }
}

private struct OEmbedTitle: Decodable {
	let title: String
}

// One login everywhere: every web view EricTube ever creates (master, music,
// watch tabs, warm pool) shares this one persistent data store and process
// pool, so the YouTube sign-in done once in any of them applies to all of
// them and survives relaunch (CREATION.md sect. 3).
@MainActor
final class WebSessionManager: ObservableObject {
	static let shared = WebSessionManager()

	// A row's placeholder title until the page (or oEmbed) names it.
	static let placeholderTitle = "YouTube"

	// How long a paused tab you switched away from stays live before it
	// goes cold — so flipping back and forth doesn't reload every time.
	private static let recentGrace: Duration = .seconds(60)

	let dataStore: WKWebsiteDataStore = .default()
	private let processPool = WKProcessPool()

	// A throwaway until init selects a real session; never matches a session.
	private static let placeholderID = UUID()

	@Published var active: SessionKey = .watch(WebSessionManager.placeholderID) {
		didSet {
			if oldValue != active {
				// Leave before pausing: whether the tab was playing as you
				// left decides if it stays live.
				if !restoring {
					leave(oldValue)
					enter(active)
				}
				pauseOnLeave(oldValue)
				if !restoring { recoverIfNeeded(webView(for: active)) }
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
	// Music's veil; watch sessions carry theirs in WatchSession. Same
	// born-uncovered rule when the music session is created fresh.
	@Published private(set) var musicCoverAlpha = 0.0
	@Published private(set) var audible: Set<ObjectIdentifier> = []
	@Published private(set) var pageZoom: Double =
		UserDefaults.standard.object(forKey: "pageZoom") as? Double ?? 1.0

	// Warm pool: a parked web view already sitting on youtube.com, so "+"
	// is an SPA hop instead of a cold page load. Fed by closed and cold-gone
	// tabs; capped at one — each live view is its own web content process.
	private var parked: [WKWebView] = []

	// The one paused tab you most recently left, still live until its grace
	// runs out or another tab takes the spot.
	private var recentID: UUID?
	private var recentExpiry: Task<Void, Never>?

	// Title/URL observers per live watch session, keyed by session id.
	private var observations: [UUID: [NSKeyValueObservation]] = [:]

	private var restoring = false

	// Retained here because WKWebView only holds its navigationDelegate weakly.
	private lazy var sentry = NavigationSentry(manager: self)

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

	private func index(of id: UUID) -> Int? {
		watchSessions.firstIndex { $0.id == id }
	}

	nonisolated static func videoId(in url: URL) -> String? {
		guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
		      components.path == "/watch" else { return nil }
		return components.queryItems?.first { $0.name == "v" }?.value
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

	// MARK: - Liveness

	// Leaving a tab: if it's still playing (background play on), it keeps
	// playing and is flagged keep-live; otherwise it takes the recent spot.
	private func leave(_ key: SessionKey) {
		guard case .watch(let id) = key, let index = index(of: id),
		      let webView = watchSessions[index].webView else { return }
		if playInBackground && isAudible(webView) {
			watchSessions[index].keepLive = true
		}
		if !watchSessions[index].keepLive {
			makeRecent(id)
		}
	}

	// Entering a tab: it's no longer "recent", and a cold one wakes. A woken
	// tab comes up held unless autoplay-on-select wants it playing.
	private func enter(_ key: SessionKey) {
		guard case .watch(let id) = key else { return }
		if recentID == id {
			recentID = nil
			recentExpiry?.cancel()
		}
		wake(id, held: !autoplayOnSelect)
	}

	// The tab you just left holds the single recent spot; whoever had it
	// goes cold now, and this one goes cold when the grace runs out.
	private func makeRecent(_ id: UUID) {
		if let previous = recentID, previous != id {
			goCold(previous)
		}
		recentID = id
		recentExpiry?.cancel()
		recentExpiry = Task { [weak self] in
			try? await Task.sleep(for: Self.recentGrace)
			guard !Task.isCancelled, let self, self.recentID == id else { return }
			self.recentID = nil
			self.goCold(id)
		}
	}

	// Gives a cold tab a live web view at its saved spot. No-op if live.
	@discardableResult
	private func wake(_ id: UUID, held: Bool, deferLoad: Bool = false) -> WKWebView? {
		guard let index = index(of: id) else { return nil }
		if let live = watchSessions[index].webView { return live }
		let webView = makeWebView(
			kind: "watch", url: resumeURL(for: watchSessions[index]),
			restorePaused: held, deferLoad: deferLoad)
		watchSessions[index].webView = webView
		observe(webView, as: id)
		return webView
	}

	// Drops a background tab's web view; the record stays. Never the active
	// tab, never a kept-live one.
	private func goCold(_ id: UUID) {
		guard let index = index(of: id), let webView = watchSessions[index].webView,
		      active != .watch(id), !watchSessions[index].keepLive else { return }
		if recentID == id {
			recentID = nil
			recentExpiry?.cancel()
		}
		watchSessions[index].webView = nil
		retire(webView, of: id)
		scheduleSnapshot()
	}

	// Silences a view that's leaving a session and either parks it as the
	// warm spare or lets it go (deallocating it ends its process).
	private func retire(_ webView: WKWebView, of id: UUID) {
		audible.remove(ObjectIdentifier(webView))
		observations[id] = nil
		// Kill playback first — unconditionally, whether the view gets parked
		// or dropped. Navigating home alone leaves YouTube's miniplayer
		// running, and a dropped view plays on until it deallocs.
		webView.evaluateJavaScript(Injection.stopAndHold, completionHandler: nil)
		if parked.isEmpty, (webView as? SessionWebView)?.needsRecovery != true {
			// SPA-hop home: keeps the view warm for the next new tab.
			webView.evaluateJavaScript(Injection.spaNavigate(path: "/"), completionHandler: nil)
			parked.append(webView)
		} else {
			webView.configuration.userContentController.removeAllScriptMessageHandlers()
		}
	}

	// The row's speaker toggle. Flagging a background tab keeps it (waking it
	// held if cold); unflagging one quiets it and starts its grace, like a
	// tab you just left paused.
	func toggleKeepLive(_ id: UUID) {
		guard let index = index(of: id) else { return }
		let keep = !watchSessions[index].keepLive
		watchSessions[index].keepLive = keep
		if active != .watch(id) {
			if keep {
				if recentID == id {
					recentID = nil
					recentExpiry?.cancel()
				}
				wake(id, held: true)
			} else {
				watchSessions[index].webView?.evaluateJavaScript(Injection.stopAndHold, completionHandler: nil)
				makeRecent(id)
			}
		}
		scheduleSnapshot()
	}

	// A live tab's record follows its page: URL on every (SPA) navigation,
	// title once it's a real one.
	private func observe(_ webView: WKWebView, as id: UUID) {
		observations[id] = [
			webView.observe(\.url) { [weak self] view, _ in
				MainActor.assumeIsolated { self?.noteURL(view.url, of: id) }
			},
			webView.observe(\.title) { [weak self] view, _ in
				MainActor.assumeIsolated { self?.noteTitle(view.title, url: view.url, of: id) }
			},
		]
	}

	private func noteURL(_ url: URL?, of id: UUID) {
		guard let url, let index = index(of: id), watchSessions[index].url != url else { return }
		watchSessions[index].url = url
		scheduleSnapshot()
	}

	// document.title is literally "YouTube" on a fresh watch load until the
	// page settles — never let that clobber a real title.
	private func noteTitle(_ raw: String?, url: URL?, of id: UUID) {
		guard let raw, !raw.isEmpty, let index = index(of: id) else { return }
		let title = raw.strippedYouTubeSuffix
		if title == Self.placeholderTitle, url?.path == "/watch" { return }
		guard watchSessions[index].title != title else { return }
		watchSessions[index].title = title
		scheduleSnapshot()
	}

	// Shorts carry their id in the path; oEmbed names them like any video.
	private static func titleVideoId(in url: URL) -> String? {
		if let videoId = videoId(in: url) { return videoId }
		let parts = url.pathComponents
		return parts.count >= 3 && parts[1] == "shorts" ? parts[2] : nil
	}

	// Best title we already know for a URL: a video's recorded or saved
	// title, a channel's @handle, else the placeholder.
	private func knownTitle(for url: URL) -> String {
		guard let videoId = Self.titleVideoId(in: url) else {
			let handle = url.pathComponents.dropFirst().first { $0.hasPrefix("@") }
			return handle ?? Self.placeholderTitle
		}
		if let recorded = ProgressStore.shared.records[videoId]?.title,
		   !recorded.isEmpty, recorded != "(untitled)" {
			return recorded
		}
		if let saved = OverlayStore.shared.video(for: videoId)?.title, !saved.isEmpty {
			return saved
		}
		return Self.placeholderTitle
	}

	// Names a cold video row that nothing local could: YouTube's public
	// oEmbed endpoint (metadata only, no page load).
	private func fetchTitle(for id: UUID) {
		guard let index = index(of: id), let videoId = Self.titleVideoId(in: watchSessions[index].url),
		      let url = URL(string:
			"https://www.youtube.com/oembed?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D\(videoId)&format=json")
		else { return }
		Task { [weak self] in
			guard let (data, _) = try? await URLSession.shared.data(from: url),
			      let meta = try? JSONDecoder().decode(OEmbedTitle.self, from: data),
			      let self, let index = self.index(of: id),
			      self.watchSessions[index].title == Self.placeholderTitle
			else { return }
			self.watchSessions[index].title = meta.title
			self.scheduleSnapshot()
		}
	}

	// Every session that must stay mounted (hidden, not torn down) so
	// playback and page state survive switching away. Cold tabs aren't here.
	var displayed: [DisplayedSession] {
		var list: [DisplayedSession] = []
		if let musicWebView {
			list.append(DisplayedSession(key: .music, webView: musicWebView))
		}
		for session in watchSessions {
			if let webView = session.webView {
				list.append(DisplayedSession(key: .watch(session.id), webView: webView))
			}
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

	// Opening a video with recorded progress resumes where it left off.
	// If the video is already open as a tab, switch to it (or, for a
	// background open, leave it be) instead of spawning a twin.
	func openWatchTab(videoId raw: String, title: String? = nil, activate: Bool = true) {
		let videoId = raw.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
		guard !videoId.isEmpty else { return }
		if let existing = watchSessions.first(where: { $0.videoId == videoId }) {
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
		openTab(path: path, title: title, activate: activate)
	}

	func currentVideoId(of webView: WKWebView) -> String? {
		// A restored view has no live URL until its load commits; fall back to
		// where the app pointed it so open-dedupe and drag payloads still work.
		guard let url = webView.url ?? (webView as? SessionWebView)?.intendedURL else { return nil }
		return Self.videoId(in: url)
	}

	// Any youtube.com path (watch, channel, playlist) as a new tab. Activated
	// opens go live at once (via the warm spare when one is parked);
	// background opens are just a record — nothing loads or plays until the
	// tab is first visited.
	func openTab(path: String, title: String? = nil, activate: Bool = true) {
		paletteRequest = nil
		let fullURL = URL(string: "https://www.youtube.com\(path)")!
		let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
		var session = WatchSession(
			url: fullURL,
			title: cleanTitle.flatMap { $0.isEmpty ? nil : $0 } ?? knownTitle(for: fullURL))
		if activate {
			let webView: WKWebView
			if let recycled = parked.last,
			   !recycled.isLoading, recycled.url?.host?.hasSuffix("youtube.com") == true {
				parked.removeLast()
				recycled.evaluateJavaScript(Injection.spaNavigate(path: path), completionHandler: nil)
				(recycled as? SessionWebView)?.intendedURL = fullURL
				webView = recycled
			} else {
				webView = makeWebView(kind: "watch", url: fullURL)
			}
			session.webView = webView
			observe(webView, as: session.id)
		}
		// Newest on top: sessions read newest -> oldest down the list.
		watchSessions.insert(session, at: 0)
		if activate {
			active = .watch(session.id)
		} else if session.title == Self.placeholderTitle {
			fetchTitle(for: session.id)
		}
		scheduleSnapshot()
	}

	// Clicking a session row: switch to it if it isn't current; if it already
	// is, that's a play/pause toggle (not a no-op re-select) — unless the view
	// is dead, in which case the click revives it instead.
	func selectSession(_ key: SessionKey) {
		if active == key {
			let target = webView(for: key)
			if !recoverIfNeeded(target) {
				target?.evaluateJavaScript(Injection.togglePlay, completionHandler: nil)
			}
		} else if case .music = key, musicWebView == nil {
			showMusic()
		} else {
			active = key
		}
	}

	// The "+" in the Sessions header: a fresh youtube.com session, switched
	// to right away.
	func newSession() {
		openTab(path: "/", activate: true)
	}

	// A drag payload is a session UUID (session rows, so reorder works even
	// with no video loaded) or a plain videoId (tier/continue/history rows).
	// Resolve it to a videoId for filing into lists/tiers.
	func videoId(forDragPayload payload: String) -> String? {
		if let uuid = UUID(uuidString: payload),
		   let session = watchSessions.first(where: { $0.id == uuid }) {
			return session.videoId
		}
		return payload.isEmpty ? nil : payload
	}

	// Reorder a session within the list (drag to reorder). A session UUID
	// payload reorders that session; a bare videoId from elsewhere opens it.
	func moveSessionByPayload(_ payload: String, toIndex: Int) {
		if let uuid = UUID(uuidString: payload),
		   let from = watchSessions.firstIndex(where: { $0.id == uuid }) {
			let session = watchSessions.remove(at: from)
			var target = toIndex
			if from < target { target -= 1 }
			target = max(0, min(watchSessions.count, target))
			watchSessions.insert(session, at: target)
			scheduleSnapshot()
		} else if !payload.isEmpty {
			openWatchTab(videoId: payload, activate: false)
		}
	}

	// MARK: - Cover veil (per session)

	var activeCoverAlpha: Double {
		coverAlpha(for: active)
	}

	func coverAlpha(for key: SessionKey) -> Double {
		switch key {
		case .music:
			return musicCoverAlpha
		case .watch(let id):
			return watchSessions.first { $0.id == id }?.coverAlpha ?? 0
		}
	}

	func setActiveCoverAlpha(_ alpha: Double) {
		switch active {
		case .music:
			musicCoverAlpha = alpha
		case .watch(let id):
			guard let index = watchSessions.firstIndex(where: { $0.id == id }) else { return }
			watchSessions[index].coverAlpha = alpha
		}
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
		for session in watchSessions where session.videoId == videoId {
			closeWatchTab(session)
		}
	}

	func closeWatchTab(_ session: WatchSession) {
		guard let index = index(of: session.id) else { return }
		let wasActive = (active == .watch(session.id))
		let webView = watchSessions[index].webView
		watchSessions.remove(at: index)
		if recentID == session.id {
			recentID = nil
			recentExpiry?.cancel()
		}
		if let webView {
			retire(webView, of: session.id)
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
			paletteRequest = PaletteRequest(
				videoId: videoId,
				title: body["title"] as? String,
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
			if let index = watchSessions.firstIndex(where: { $0.webView === webView }) {
				watchSessions[index].positionVideoId = videoId
				watchSessions[index].seconds = seconds
				if !cleanTitle.isEmpty {
					watchSessions[index].title = cleanTitle
				}
			}
			scheduleSnapshot()
		default:
			break
		}
	}

	// MARK: - Session health & recovery

	// WKWebView never recovers on its own: WebKit reclaims hidden views' web
	// content processes under memory pressure (routine with every session
	// mounted at opacity 0), and a load that fails just leaves the view blank
	// forever. The sentry routes both events here. The visible session comes
	// back on the spot; hidden ones are flagged and revived when next shown,
	// so recovery never re-creates the relaunch process storm.
	func handleProcessDeath(_ webView: WKWebView) {
		parked.removeAll { $0 === webView }   // never recycle a corpse
		if webView === self.webView(for: active) {
			recover(webView)
		} else if let sessionView = webView as? SessionWebView {
			sessionView.needsRecovery = true
		}
	}

	func handleLoadFailure(_ webView: WKWebView, error: Error) {
		let nsError = error as NSError
		// YouTube's SPA cancels provisional loads constantly, and policy
		// handoffs interrupt frames; neither means the view is broken.
		if nsError.code == NSURLErrorCancelled { return }
		if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
		guard let sessionView = webView as? SessionWebView else { return }
		sessionView.loadRetries += 1
		if sessionView.loadRetries <= 2 {
			let delay = 1.5 * Double(sessionView.loadRetries)
			Task { @MainActor in
				try? await Task.sleep(for: .seconds(delay))
				self.recover(sessionView)
			}
		} else {
			// Out of retries — stop hammering a network that isn't there and
			// revive on the user's next visit instead.
			sessionView.needsRecovery = true
		}
	}

	func handleCommit(_ webView: WKWebView) {
		guard let sessionView = webView as? SessionWebView else { return }
		sessionView.loadRetries = 0
		sessionView.needsRecovery = false
		sessionView.intendedURL = webView.url ?? sessionView.intendedURL
	}

	private func recover(_ webView: WKWebView) {
		(webView as? SessionWebView)?.needsRecovery = false
		if webView.url != nil {
			webView.reload()
		} else if let intended = (webView as? SessionWebView)?.intendedURL {
			webView.load(URLRequest(url: intended))
		} else {
			webView.load(URLRequest(url: URL(string: "https://www.youtube.com/")!))
		}
	}

	// The activation check: a flagged view, or one that never got a page
	// (nothing committed, nothing in flight), reloads instead of presenting
	// blank. Returns whether a recovery was kicked off.
	@discardableResult
	private func recoverIfNeeded(_ webView: WKWebView?) -> Bool {
		guard let sessionView = webView as? SessionWebView,
		      sessionView.needsRecovery || (sessionView.url == nil && !sessionView.isLoading)
		else { return false }
		recover(sessionView)
		return true
	}

	// MARK: - Session snapshot & restore

	// One saved tab: everything a cold row needs to show itself and resume,
	// with no page load.
	private struct TabRecord: Codable {
		var url: String
		var title: String?
		var alpha: Double
		var keepLive: Bool
		var positionVideoId: String?
		var seconds: Double?
	}

	private struct SessionSnapshot: Codable {
		var masterURL: String?
		var musicURL: String?
		var tabs: [TabRecord]?
		var active: String
		var musicAlpha: Double?
		// Legacy (pre-record snapshots): parallel URL and veil arrays. Read
		// once on upgrade, never written.
		var tabURLs: [String]?
		var tabAlphas: [Double]?
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
			if let index = index(of: id) {
				activeKey = "tab:\(index)"
			}
		}
		let snapshot = SessionSnapshot(
			masterURL: nil,   // no special session anymore
			musicURL: musicWebView.flatMap { ($0.url ?? ($0 as? SessionWebView)?.intendedURL)?.absoluteString },
			tabs: watchSessions.map { session in
				TabRecord(
					url: session.url.absoluteString, title: session.title,
					alpha: session.coverAlpha, keepLive: session.keepLive,
					positionVideoId: session.positionVideoId, seconds: session.seconds)
			},
			active: activeKey,
			musicAlpha: musicWebView != nil ? musicCoverAlpha : nil)
		if let data = try? JSONEncoder().encode(snapshot) {
			UserDefaults.standard.set(data, forKey: "sessionSnapshot")
		}
	}

	// Every tab comes back as its record; only the selected tab, the
	// kept-live tabs and music get web views, and all of them come back
	// held — play state never survives a relaunch. The rest stay cold until
	// visited, so a relaunch never fires a herd of video loads at YouTube
	// (bot-shaped traffic, history pollution, and tabs spinning into error
	// pages).
	private func restoreSession() {
		guard let data = UserDefaults.standard.data(forKey: "sessionSnapshot"),
		      let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data)
		else { return }
		restoring = true
		defer { restoring = false }

		// Sessions saved before the per-session veil inherit the old global
		// veil level, so an upgrade relaunch looks exactly like yesterday.
		let legacyAlpha = UserDefaults.standard.object(forKey: "coverAlpha") as? Double ?? 0

		if let music = snapshot.musicURL, let url = URL(string: music) {
			let isWatch = url.path == "/watch"
			musicWebView = makeWebView(kind: "music", url: resumeURL(url), restorePaused: isWatch, deferLoad: true)
			musicCoverAlpha = snapshot.musicAlpha ?? legacyAlpha
		}
		var records = snapshot.tabs ?? []
		if snapshot.tabs == nil {
			// Legacy master URL (old snapshots) becomes the first session.
			if let master = snapshot.masterURL {
				records.append(TabRecord(url: master, alpha: legacyAlpha, keepLive: false))
			}
			for (index, url) in (snapshot.tabURLs ?? []).enumerated() {
				let alpha = snapshot.tabAlphas.flatMap { $0.indices.contains(index) ? $0[index] : nil }
				records.append(TabRecord(url: url, alpha: alpha ?? legacyAlpha, keepLive: false))
			}
		}
		for record in records {
			guard let url = URL(string: record.url) else { continue }
			let title = record.title.flatMap { $0.isEmpty || $0 == Self.placeholderTitle ? nil : $0 } ?? knownTitle(for: url)
			watchSessions.append(WatchSession(
				url: url, title: title,
				positionVideoId: record.positionVideoId, seconds: record.seconds,
				coverAlpha: record.alpha, keepLive: record.keepLive))
		}
		// Restore the selection. Legacy "tab:N"/"master" indices predate the
		// prepended master session, so offset them by one.
		let legacyOffset = snapshot.tabs == nil && snapshot.masterURL != nil ? 1 : 0
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

		// Load the selected session now; trickle music and the kept-live
		// tabs in behind it.
		var queue: [WKWebView] = []
		if case .watch(let id) = active, let selected = wake(id, held: true, deferLoad: true) {
			startDeferredLoad(selected)
		} else if active == .music, let musicWebView {
			startDeferredLoad(musicWebView)
		}
		if let musicWebView, active != .music { queue.append(musicWebView) }
		for session in watchSessions where session.keepLive && active != .watch(session.id) {
			if let webView = wake(session.id, held: true, deferLoad: true) {
				queue.append(webView)
			}
		}
		for (index, webView) in queue.enumerated() {
			Task { @MainActor in
				try? await Task.sleep(for: .milliseconds(1000 * (index + 1)))
				self.startDeferredLoad(webView)
			}
		}
		for session in watchSessions where session.title == Self.placeholderTitle {
			fetchTitle(for: session.id)
		}
	}

	// Kicks off a deferred restore load — unless something already has (an
	// early activation recovers the view ahead of its slot in the trickle).
	private func startDeferredLoad(_ webView: WKWebView) {
		guard webView.url == nil, !webView.isLoading,
		      let intended = (webView as? SessionWebView)?.intendedURL else { return }
		webView.load(URLRequest(url: intended))
	}

	// Where a cold tab picks back up: its own last reported spot if that was
	// for this video, else the progress store's resume point.
	private func resumeURL(for session: WatchSession) -> URL {
		let seconds = session.positionVideoId == session.videoId ? session.seconds : nil
		return resumeURL(session.url, seconds: seconds)
	}

	// Rewrites a /watch URL to resume at the given (or recorded) position.
	private func resumeURL(_ url: URL, seconds: Double? = nil) -> URL {
		guard let videoId = Self.videoId(in: url),
		      var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
		      let resume = seconds.flatMap({ $0 > 5 ? $0 : nil }) ?? ProgressStore.shared.resumeSeconds(for: videoId)
		else { return url }
		var items = components.queryItems ?? []
		items.removeAll { $0.name == "t" }
		items.append(URLQueryItem(name: "t", value: "\(Int(resume))s"))
		components.queryItems = items
		return components.url ?? url
	}

	private func makeWebView(kind: String, url: URL?, restorePaused: Bool = false, deferLoad: Bool = false) -> WKWebView {
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
		// After the restorePause flag: the mute guard reads it at documentStart.
		controller.addUserScript(WKUserScript(
			source: Injection.muteScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
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

		let webView = SessionWebView(frame: .zero, configuration: config)
		webView.navigationDelegate = sentry
		webView.allowsBackForwardNavigationGestures = true
		webView.allowsMagnification = true
		webView.isInspectable = true
		webView.pageZoom = pageZoom
		webView.intendedURL = url
		if let url, !deferLoad {
			webView.load(URLRequest(url: url))
		}
		return webView
	}
}

// Watches every web view for the two ways it can silently die — web content
// process reclaimed, load failed — and routes them to the manager's recovery.
// Weak back-reference for the same cycle reason as MessageProxy.
private final class NavigationSentry: NSObject, WKNavigationDelegate {
	weak var manager: WebSessionManager?

	init(manager: WebSessionManager) {
		self.manager = manager
	}

	func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
		MainActor.assumeIsolated {
			manager?.handleProcessDeath(webView)
		}
	}

	func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
		MainActor.assumeIsolated {
			manager?.handleCommit(webView)
		}
	}

	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
		MainActor.assumeIsolated {
			manager?.handleLoadFailure(webView, error: error)
		}
	}

	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
		MainActor.assumeIsolated {
			manager?.handleLoadFailure(webView, error: error)
		}
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
