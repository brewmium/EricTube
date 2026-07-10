import Foundation

// Everything EricTube injects into YouTube pages. Kept deliberately dumb —
// find things, report things — so YouTube markup changes stay a ten-minute
// fix. All app logic lives on the native side.
enum Injection {
	static let messageName = "erictube"

	// Session kind gate for the scripts below; set before page scripts run.
	// Survives SPA navigation (same window object), re-runs on real loads.
	static func kindScript(_ kind: String) -> String {
		"window.__erictubeKind = '\(kind)';"
	}

	// One floating chip, event-delegated over every /watch thumbnail link.
	// Clicking reports the video id plus the chip's viewport rect; the
	// native palette anchors there. No per-node bookkeeping, so YouTube's
	// endless DOM churn needs no MutationObserver.
	static let chipScript = #"""
	(function () {
		if (window.__erictubeChip) { return; }
		const chip = document.createElement('div');
		window.__erictubeChip = chip;
		chip.textContent = '+';
		Object.assign(chip.style, {
			position: 'absolute', zIndex: '99999', display: 'none',
			width: '44px', height: '34px', lineHeight: '34px',
			textAlign: 'center', borderRadius: '8px',
			background: 'rgba(15,15,15,0.88)', color: '#fff',
			font: '600 20px -apple-system', cursor: 'pointer',
			boxShadow: '0 1px 5px rgba(0,0,0,0.45)'
		});
		document.documentElement.appendChild(chip);
		let currentId = null;
		let currentRect = null;

		const LINKS = 'a[href*="/watch?v="], a[href*="/shorts/"]';
		const THUMB_IMGS = 'a[href*="/watch?v="] img, a[href*="/shorts/"] img';
		const TILES = 'ytd-rich-item-renderer, ytd-rich-grid-media, ytd-video-renderer, ytd-compact-video-renderer, ytd-grid-video-renderer, ytd-playlist-video-renderer, ytd-reel-item-renderer, yt-lockup-view-model';

		function videoIdOf(a) {
			try {
				const u = new URL(a.href, location.href);
				const v = u.searchParams.get('v');
				if (v) { return v; }
				const m = u.pathname.match(/\/shorts\/([\w-]+)/);
				if (m) { return m[1]; }
			} catch (err) {}
			return null;
		}

		// A tile has two watch anchors (thumbnail and text block); place
		// the chip on the thumbnail, matched by video id so climbing past
		// the tile can never grab a neighbor's thumb.
		function thumbRectFor(start, id) {
			let node = start;
			for (let i = 0; node && i < 7; i++) {
				if (node.querySelectorAll) {
					for (const img of node.querySelectorAll(THUMB_IMGS)) {
						const link = img.closest('a');
						if (link && videoIdOf(link) === id) {
							const r = link.getBoundingClientRect();
							if (r.width >= 80 && r.height >= 50) { return r; }
						}
					}
				}
				node = node.parentElement;
			}
			return null;
		}

		// Anywhere in a video cell counts: a watch anchor directly, or any
		// element inside a known tile container.
		function resolve(el) {
			if (!el || !el.closest) { return null; }
			const a = el.closest(LINKS);
			if (a) {
				const id = videoIdOf(a);
				if (id) { return { id: id, rect: thumbRectFor(a, id) }; }
			}
			const tile = el.closest(TILES);
			if (tile) {
				for (const link of tile.querySelectorAll(LINKS)) {
					const id = videoIdOf(link);
					if (id) { return { id: id, rect: thumbRectFor(link, id) }; }
				}
			}
			return null;
		}

		function show(id, r) {
			chip.style.left = (window.scrollX + r.left + 8) + 'px';
			chip.style.top = (window.scrollY + r.top + 8) + 'px';
			chip.style.display = 'block';
			currentId = id;
			currentRect = r;
		}

		function hide() {
			chip.style.display = 'none';
			currentId = null;
			currentRect = null;
		}

		document.addEventListener('mouseover', function (e) {
			if (e.target === chip || chip.contains(e.target)) { return; }
			const found = resolve(e.target);
			if (found && found.rect) {
				show(found.id, found.rect);
				return;
			}
			// YouTube's inline preview is a global overlay ON TOP of the
			// thumbnail, outside the tile; hold the chip while the pointer
			// stays within the claimed area instead of flashing away.
			if (currentRect) {
				const pad = 8;
				if (e.clientX >= currentRect.left - pad && e.clientX <= currentRect.right + pad &&
				    e.clientY >= currentRect.top - pad && e.clientY <= currentRect.bottom + pad) {
					return;
				}
			}
			hide();
		}, true);

		window.addEventListener('scroll', hide, true);
		// A click navigates the page under a motionless mouse — no
		// mouseover will fire to clear the chip, so navigation must.
		['yt-navigate-start', 'yt-navigate-finish'].forEach(function (t) {
			document.addEventListener(t, hide);
		});

		chip.addEventListener('click', function (e) {
			e.preventDefault();
			e.stopPropagation();
			if (!currentId) { return; }
			window.webkit.messageHandlers.erictube.postMessage({
				kind: 'chip', videoId: currentId,
				x: e.clientX, y: e.clientY, w: 1, h: 1
			});
		}, true);
	})();
	"""#

	// Watch pages always open in theater mode, in every session — master
	// included. YouTube's own persistence of the preference is unreliable
	// across cold loads; this enforces it whenever a player appears.
	static let theaterScript = #"""
	(function () {
		if (window.__erictubeTheater) { return; }
		window.__erictubeTheater = true;
		function enforce() {
			if (window.__erictubePreferTheater === false) { return; }
			if (location.pathname !== '/watch') { return; }
			let tries = 0;
			const timer = setInterval(function () {
				tries += 1;
				const flexy = document.querySelector('ytd-watch-flexy');
				const btn = document.querySelector('.ytp-size-button');
				if (flexy && btn) {
					clearInterval(timer);
					if (!flexy.hasAttribute('theater')) { btn.click(); }
				} else if (tries > 40) {
					clearInterval(timer);
				}
			}, 250);
		}
		document.addEventListener('yt-navigate-finish', enforce);
		enforce();
	})();
	"""#

	// Reports whether the page is audibly playing (for the tab chips'
	// speaker icon). Tracks unmuted <video> elements only, so YouTube's
	// muted hover-previews don't light tabs up.
	static let mediaScript = #"""
	(function () {
		if (window.__erictubeMedia) { return; }
		window.__erictubeMedia = true;
		const audible = new Set();
		let last = null;
		function report() {
			const playing = audible.size > 0;
			if (playing === last) { return; }
			last = playing;
			try {
				window.webkit.messageHandlers.erictube.postMessage({
					kind: 'media', playing: playing
				});
			} catch (err) {}
		}
		function consider(el) {
			if (!(el instanceof HTMLVideoElement)) { return; }
			if (!el.paused && !el.ended && !el.muted && el.volume > 0) {
				audible.add(el);
			} else {
				audible.delete(el);
			}
			report();
		}
		['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied'].forEach(function (t) {
			document.addEventListener(t, function (e) { consider(e.target); }, true);
		});
	})();
	"""#

	// Reports playback position of the page's main video: every ~5s while
	// playing, and immediately on play/pause/seek/end/navigation. Feeds the
	// progress store (in-progress history, resume) and the Now Playing
	// bridge (headphone / media-key control).
	static let progressScript = #"""
	(function () {
		if (window.__erictubeProgress) { return; }
		window.__erictubeProgress = true;
		let lastSent = 0;

		function videoIdHere() {
			if (location.pathname === '/watch') {
				return new URLSearchParams(location.search).get('v');
			}
			const m = location.pathname.match(/^\/shorts\/([\w-]+)/);
			return m ? m[1] : null;
		}

		// document.title is still literally "YouTube" on fresh paused
		// loads; prefer the watch page's h1 and never report junk.
		function pageTitle() {
			const h1 = document.querySelector('h1.ytd-watch-metadata yt-formatted-string')
				|| document.querySelector('h1 yt-formatted-string.ytd-watch-metadata');
			const fromH1 = h1 && h1.textContent ? h1.textContent.trim() : '';
			if (fromH1) { return fromH1; }
			const fromDoc = document.title || '';
			return fromDoc === 'YouTube' ? '' : fromDoc;
		}

		function report(force) {
			const v = document.querySelector('video.html5-main-video') || document.querySelector('video');
			const id = videoIdHere();
			if (!v || !id) { return; }
			const now = Date.now();
			if (!force && now - lastSent < 5000) { return; }
			lastSent = now;
			try {
				window.webkit.messageHandlers.erictube.postMessage({
					kind: 'progress',
					videoId: id,
					title: pageTitle(),
					seconds: v.currentTime,
					duration: isFinite(v.duration) ? v.duration : 0,
					playing: !v.paused && !v.ended,
					path: location.pathname,
					sessionKind: window.__erictubeKind || ''
				});
			} catch (err) {}
		}

		document.addEventListener('timeupdate', function (e) {
			if (e.target instanceof HTMLVideoElement) { report(false); }
		}, true);
		['play', 'pause', 'ended', 'seeked'].forEach(function (t) {
			document.addEventListener(t, function (e) {
				if (e.target instanceof HTMLVideoElement) { report(true); }
			}, true);
		});
		document.addEventListener('yt-navigate-finish', function () { report(true); });
	})();
	"""#

	// One-shot pause of the next playback attempt. Armed at load for
	// restored views (__erictubeRestorePause flag) and on demand via
	// __erictubeArmPause() for tabs opened in the background.
	static let restorePauseScript = #"""
	(function () {
		if (window.__erictubeArmPause) { return; }
		window.__erictubeArmPause = function () {
			if (window.__erictubePauseArmed) { return; }
			window.__erictubePauseArmed = true;
			function once(e) {
				if (!(e.target instanceof HTMLVideoElement)) { return; }
				document.removeEventListener('playing', once, true);
				// A deliberate play (autoplay-on-select) disarms us first;
				// don't fight it.
				if (window.__erictubePauseArmed) {
					e.target.pause();
					window.__erictubePauseArmed = false;
				}
			}
			document.addEventListener('playing', once, true);
		};
		if (window.__erictubeRestorePause) {
			window.__erictubeArmPause();
		}
	})();
	"""#

	static let armPause = "window.__erictubeArmPause && window.__erictubeArmPause();"

	// Pauses the page's main video if playing (switching away from a
	// session with background play off).
	static let pauseNow = "(function(){const v=document.querySelector('video.html5-main-video')||document.querySelector('video');if(v&&!v.paused){v.pause();}})();"

	// Plays the page's main video (autoplay-on-select). Disarms any pending
	// one-shot pause first, and no-ops off a /watch page so switching to the
	// home feed stays quiet.
	static let playNow = "(function(){if(location.pathname!=='/watch'){return;}window.__erictubePauseArmed=false;const v=document.querySelector('video.html5-main-video')||document.querySelector('video');if(v&&v.paused){v.play();}})();"

	// Live-applies the theater preference to a mounted view: sets the flag and
	// toggles the current watch page's layout to match immediately.
	static func setTheater(_ on: Bool) -> String {
		let want = on ? "true" : "false"
		return """
		(function () {
			window.__erictubePreferTheater = \(want);
			if (location.pathname !== '/watch') { return; }
			// The size button isn't always mounted the instant we toggle (a
			// restored/paused player mounts its controls late), so poll for it.
			let tries = 0;
			const timer = setInterval(function () {
				tries += 1;
				const flexy = document.querySelector('ytd-watch-flexy');
				const btn = document.querySelector('.ytp-size-button');
				if (flexy && btn) {
					clearInterval(timer);
					if (\(want) !== flexy.hasAttribute('theater')) { btn.click(); }
				} else if (tries > 40) {
					clearInterval(timer);
				}
			}, 100);
		})();
		"""
	}

	// Drives YouTube's own SPA router (it intercepts same-origin anchor
	// clicks), so a warm web view hops to the target like an in-page click
	// instead of cold-loading the whole site.
	static func spaNavigate(path: String) -> String {
		#"""
		(function () {
			const a = document.createElement('a');
			a.href = '\#(path)';
			document.body.appendChild(a);
			a.click();
			a.remove();
		})();
		"""#
	}
}
