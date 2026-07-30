import SwiftUI

// A black veil over the web area for watching-without-watching: music videos
// keep playing, but the picture stops grabbing attention. Alpha 0 = off,
// 1 = blackout, anywhere between = dimmed. State lives in defaults so the
// veil survives relaunch.
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

// The bar control: a chunky pill that is both a slider and three tap targets.
// Drag anywhere to set darkness continuously; a tap (no real movement) snaps
// by zone — left third clears, middle third jumps to the preset working
// level, right third blacks out. The preset lives in defaults
// (coverPresetAlpha) for tuning.
struct CoverSlider: View {
	@AppStorage("coverAlpha") private var alpha = 0.0
	@AppStorage("coverPresetAlpha") private var preset = 0.85
	@State private var dragging = false
	@State private var hovering = false

	private let trackWidth: CGFloat = 96
	private let trackHeight: CGFloat = 22

	var body: some View {
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
		.onHover { hovering = $0 }
		.gesture(
			DragGesture(minimumDistance: 0)
				.onChanged { value in
					if !dragging, abs(value.translation.width) > 3 {
						dragging = true
					}
					if dragging {
						alpha = min(1, max(0, value.location.x / trackWidth))
					}
				}
				.onEnded { value in
					if !dragging {
						let zone = value.location.x / trackWidth
						if zone < 1 / 3 {
							alpha = 0
						} else if zone < 2 / 3 {
							alpha = preset
						} else {
							alpha = 1
						}
					}
					dragging = false
				})
		.tooltip("Video cover — drag to dim; tap: left clears, "
			+ "middle \(Int((preset * 100).rounded()))%, right blacks out")
	}

	private func zoneTick(at fraction: CGFloat) -> some View {
		Rectangle()
			.fill(Color.primary.opacity(0.25))
			.frame(width: 1, height: trackHeight)
			.offset(x: trackWidth * fraction)
	}
}
