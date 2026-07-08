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
			width: '28px', height: '22px', lineHeight: '22px',
			textAlign: 'center', borderRadius: '6px',
			background: 'rgba(15,15,15,0.88)', color: '#fff',
			font: '600 14px -apple-system', cursor: 'pointer',
			boxShadow: '0 1px 4px rgba(0,0,0,0.4)'
		});
		document.documentElement.appendChild(chip);
		let currentId = null;

		function anchorFor(el) {
			return el && el.closest ? el.closest('a[href*="/watch?v="]') : null;
		}

		document.addEventListener('mouseover', function (e) {
			const a = anchorFor(e.target);
			if (a) {
				let id = null;
				try {
					id = new URL(a.href, location.href).searchParams.get('v');
				} catch (err) {}
				if (!id) { return; }
				const r = a.getBoundingClientRect();
				if (r.width < 100) { return; }
				chip.style.left = (window.scrollX + r.left + 6) + 'px';
				chip.style.top = (window.scrollY + r.top + 6) + 'px';
				chip.style.display = 'block';
				currentId = id;
			} else if (e.target !== chip && !chip.contains(e.target)) {
				chip.style.display = 'none';
				currentId = null;
			}
		}, true);

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

	// Watch tabs always open in theater mode. YouTube itself persists the
	// preference in the shared session, so this usually no-ops; it exists
	// for the times the preference gets lost. Watch-kind views only.
	static let theaterScript = #"""
	(function () {
		if (window.__erictubeTheater || window.__erictubeKind !== 'watch') { return; }
		window.__erictubeTheater = true;
		function enforce() {
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
