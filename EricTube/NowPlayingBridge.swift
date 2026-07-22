import MediaPlayer
import WebKit
import os.log

// Headphone / media-key control. macOS routes remote commands (AirPods
// squeezes, F8, Control Center) to the app registered as Now Playing —
// Safari and Chrome register their web media, a bare WKWebView app never
// does. This bridge publishes the current video to the system and answers
// the commands by driving the page's <video> with a line of JS.
@MainActor
final class NowPlayingBridge {
	static let shared = NowPlayingBridge()

	private static let log = Logger(subsystem: "com.brewmium.EricTube", category: "nowplaying")

	private weak var targetWebView: WKWebView?
	private var configured = false

	func configure() {
		guard !configured else { return }
		configured = true
		let center = MPRemoteCommandCenter.shared()
		center.togglePlayPauseCommand.addTarget { _ in
			MainActor.assumeIsolated {
				Self.log.info("command: togglePlayPause")
				return NowPlayingBridge.shared.run("v.paused ? v.play() : v.pause()")
			}
		}
		center.playCommand.addTarget { _ in
			MainActor.assumeIsolated {
				Self.log.info("command: play")
				return NowPlayingBridge.shared.run("v.play()")
			}
		}
		center.pauseCommand.addTarget { _ in
			MainActor.assumeIsolated {
				Self.log.info("command: pause")
				return NowPlayingBridge.shared.run("v.pause()")
			}
		}
		center.skipForwardCommand.preferredIntervals = [15]
		center.skipForwardCommand.addTarget { _ in
			MainActor.assumeIsolated {
				Self.log.info("command: skipForward")
				return NowPlayingBridge.shared.run("v.currentTime += 15")
			}
		}
		center.skipBackwardCommand.preferredIntervals = [15]
		center.skipBackwardCommand.addTarget { _ in
			MainActor.assumeIsolated {
				Self.log.info("command: skipBackward")
				return NowPlayingBridge.shared.run("v.currentTime -= 15")
			}
		}
	}

	func update(title: String, seconds: Double, duration: Double, playing: Bool, webView: WKWebView) {
		// Beats arrive from EVERY web view (restore, pause-arming churn,
		// hidden tabs). Only a playing video may take or re-take the bridge;
		// a paused beat may only update the video already under control.
		// Otherwise hidden-tab churn repoints headphone commands at an
		// invisible video, and restore-time paused beats yank the system
		// Now Playing slot from whatever the user was actually listening to.
		if !playing && webView !== targetWebView { return }
		configure()
		targetWebView = webView
		var info: [String: Any] = [
			MPMediaItemPropertyTitle: title,
			MPNowPlayingInfoPropertyElapsedPlaybackTime: seconds,
			MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
		]
		if duration > 0 {
			info[MPMediaItemPropertyPlaybackDuration] = duration
		}
		let center = MPNowPlayingInfoCenter.default()
		center.nowPlayingInfo = info
		if playing {
			// macOS hands the Now Playing slot (where headphone/media-key
			// commands route) to the most recent playbackState *transition* —
			// re-setting .playing is a no-op, so any later claimant (a Chrome
			// tab event, a hidden view play/pausing during arming) silently
			// steals routing for good. Bounce the state each beat to force a
			// real transition and keep the slot while our video plays.
			center.playbackState = .paused
			center.playbackState = .playing
		} else {
			center.playbackState = .paused
		}
		Self.log.info("claim: \(title, privacy: .public) playing=\(playing) t=\(Int(seconds))")
	}

	private func run(_ action: String) -> MPRemoteCommandHandlerStatus {
		guard let webView = targetWebView else { return .noActionableNowPlayingItem }
		let js = "(function(){const v=document.querySelector('video.html5-main-video')||document.querySelector('video');if(!v){return;}\(action);})();"
		webView.evaluateJavaScript(js, completionHandler: nil)
		return .success
	}
}
