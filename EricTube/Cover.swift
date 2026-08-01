import SwiftUI

// A black veil over the web area for watching-without-watching: music videos
// keep playing, but the picture stops grabbing attention. Alpha 0 = off,
// 1 = blackout, anywhere between = dimmed. The level is per session
// (WebSessionManager owns it); new sessions start uncovered.
//
// The veil must be an AppKit view: the WKWebViews are AppKit-backed and draw
// over SwiftUI-rendered siblings, so a plain Rectangle would vanish beneath
// them. Platform view vs platform view respects declaration order, which the
// .overlay placement in ContentView guarantees. hitTest nil keeps the veil
// click-through at every darkness — the video underneath stays controllable.
struct CoverLayer: NSViewRepresentable {
	let alpha: Double

	func makeNSView(context: Context) -> NSView {
		let view = PassThroughView()
		view.wantsLayer = true
		view.layer?.backgroundColor = NSColor.black.cgColor
		view.alphaValue = alpha
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		nsView.alphaValue = alpha
	}

	private final class PassThroughView: NSView {
		override func hitTest(_ point: NSPoint) -> NSView? { nil }
	}
}

// The bar control, always showing the ACTIVE session's veil. A tap (no real
// movement) snaps by zone — left third clears, middle third applies the
// remembered preset, right third blacks out. Dragging fine-tunes this
// session's level from wherever the drag lands; a drag that STARTS in the
// middle zone is also the preset tuner: the level released there becomes the
// new center-tap value (globally, without touching other sessions' levels).
struct CoverSlider: View {
	@ObservedObject var sessions: WebSessionManager
	@AppStorage("coverPresetAlpha") private var preset = 0.85
	@State private var dragging = false
	@State private var hovering = false

	private let trackWidth: CGFloat = 96
	private let trackHeight: CGFloat = 22

	var body: some View {
		let alpha = sessions.activeCoverAlpha
		ZStack(alignment: .leading) {
			Capsule()
				.fill(Color.primary.opacity(0.12))
			Capsule()
				.fill(Color.primary.opacity(0.55))
				.frame(width: max(0, trackWidth * alpha))
			zoneTick(at: 1 / 3)
			zoneTick(at: 2 / 3)
			if dragging || hovering {
				// White + difference inverts against whatever is behind the
				// glyphs, so the readout stays legible over both the filled
				// and empty stretches of the pill in either appearance.
				Text("\(Int((alpha * 100).rounded()))%")
					.font(.system(size: 12, weight: .semibold).monospacedDigit())
					.foregroundStyle(.white)
					.blendMode(.difference)
					.frame(width: trackWidth)
			}
		}
		.clipShape(Capsule())
		.overlay(Capsule().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
		.frame(width: trackWidth, height: trackHeight)
		.frame(height: 30)
		.contentShape(Rectangle())
		.stopsWindowDrag()
		.onHover { hovering = $0 }
		.gesture(
			DragGesture(minimumDistance: 0)
				.onChanged { value in
					if !dragging, abs(value.translation.width) > 3 {
						dragging = true
					}
					if dragging {
						sessions.setActiveCoverAlpha(level(at: value.location.x))
					}
				}
				.onEnded { value in
					if dragging {
						if zone(of: value.startLocation.x) == 1 {
							preset = level(at: value.location.x)
						}
					} else {
						switch zone(of: value.location.x) {
						case 0: sessions.setActiveCoverAlpha(0)
						case 1: sessions.setActiveCoverAlpha(preset)
						default: sessions.setActiveCoverAlpha(1)
						}
					}
					dragging = false
				})
		.tooltip("Video cover for this session — tap: left clears, middle "
			+ "\(Int((preset * 100).rounded()))%, right blacks out. Drag to "
			+ "fine-tune; a drag from the middle also retunes the middle tap.")
	}

	private func level(at x: CGFloat) -> Double {
		min(1, max(0, x / trackWidth))
	}

	private func zone(of x: CGFloat) -> Int {
		x < trackWidth / 3 ? 0 : (x < trackWidth * 2 / 3 ? 1 : 2)
	}

	private func zoneTick(at fraction: CGFloat) -> some View {
		Rectangle()
			.fill(Color.primary.opacity(0.25))
			.frame(width: 1, height: trackHeight)
			.offset(x: trackWidth * fraction)
	}
}
