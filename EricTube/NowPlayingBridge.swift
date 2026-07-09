import MediaPlayer
import WebKit

// Headphone / media-key control. macOS routes remote commands (AirPods
// squeezes, F8, Control Center) to the app registered as Now Playing —
// Safari and Chrome register their web media, a bare WKWebView app never
// does. This bridge publishes the current video to the system and answers
// the commands by driving the page's <video> with a line of JS.
@MainActor
final class NowPlayingBridge {
	static let shared = NowPlayingBridge()

	private weak var targetWebView: WKWebView?
	private var configured = false

	func configure() {
		guard !configured else { return }
		configured = true
		let center = MPRemoteCommandCenter.shared()
		center.togglePlayPauseCommand.addTarget { _ in
			MainActor.assumeIsolated {
				NowPlayingBridge.shared.run("v.paused ? v.play() : v.pause()")
			}
		}
		center.playCommand.addTarget { _ in
			MainActor.assumeIsolated {
				NowPlayingBridge.shared.run("v.play()")
			}
		}
		center.pauseCommand.addTarget { _ in
			MainActor.assumeIsolated {
				NowPlayingBridge.shared.run("v.pause()")
			}
		}
		center.skipForwardCommand.preferredIntervals = [15]
		center.skipForwardCommand.addTarget { _ in
			MainActor.assumeIsolated {
				NowPlayingBridge.shared.run("v.currentTime += 15")
			}
		}
		center.skipBackwardCommand.preferredIntervals = [15]
		center.skipBackwardCommand.addTarget { _ in
			MainActor.assumeIsolated {
				NowPlayingBridge.shared.run("v.currentTime -= 15")
			}
		}
	}

	func update(title: String, seconds: Double, duration: Double, playing: Bool, webView: WKWebView) {
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
		MPNowPlayingInfoCenter.default().nowPlayingInfo = info
		MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
	}

	private func run(_ action: String) -> MPRemoteCommandHandlerStatus {
		guard let webView = targetWebView else { return .noActionableNowPlayingItem }
		let js = "(function(){const v=document.querySelector('video.html5-main-video')||document.querySelector('video');if(!v){return;}\(action);})();"
		webView.evaluateJavaScript(js, completionHandler: nil)
		return .success
	}
}
