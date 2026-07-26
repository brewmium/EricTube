import AppKit

// EricTube icon candidates — drawn with AppKit, no external deps.
// Shipped icon is variant B (E-play mark). To rebuild AppIcon.icns:
//   swift icon_gen.swift out && cd out && mkdir AppIcon.iconset
//   sips -z the b.png master into icon_{16,32,128,256,512}(@2x) sizes,
//   cp b.png AppIcon.iconset/icon_512x512@2x.png
//   iconutil -c icns AppIcon.iconset -o ../EricTube/AppIcon.icns
// Usage: swift icon_gen.swift <outdir>

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
	NSColor(deviceRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
	        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
	        blue: CGFloat(hex & 0xFF) / 255.0, alpha: a)
}

func roundedPoly(_ pts: [CGPoint], radius: CGFloat) -> NSBezierPath {
	let p = NSBezierPath()
	let n = pts.count
	p.move(to: CGPoint(x: (pts[n - 1].x + pts[0].x) / 2, y: (pts[n - 1].y + pts[0].y) / 2))
	for i in 0..<n {
		p.appendArc(from: pts[i], to: pts[(i + 1) % n], radius: radius)
	}
	p.close()
	return p
}

func newRep(_ w: Int, _ h: Int) -> NSBitmapImageRep {
	NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
	                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
	                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

func savePNG(_ rep: NSBitmapImageRep, _ name: String) {
	let data = rep.representation(using: .png, properties: [:])!
	try! data.write(to: URL(fileURLWithPath: outDir + "/" + name))
	print("wrote \(name)")
}

// Standard macOS icon scaffold: 1024 canvas, 824 squircle, baked shadow.
func makeIcon(bgTop: NSColor, bgBottom: NSColor, body: () -> Void) -> NSBitmapImageRep {
	let rep = newRep(1024, 1024)
	let ctx = NSGraphicsContext(bitmapImageRep: rep)!
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = ctx

	let iconRect = NSRect(x: 100, y: 100, width: 824, height: 824)
	let squircle = NSBezierPath(roundedRect: iconRect, xRadius: 186, yRadius: 186)

	NSGraphicsContext.saveGraphicsState()
	let sh = NSShadow()
	sh.shadowOffset = NSSize(width: 0, height: -12)
	sh.shadowBlurRadius = 26
	sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
	sh.set()
	bgBottom.setFill()
	squircle.fill()
	NSGraphicsContext.restoreGraphicsState()

	NSGradient(starting: bgTop, ending: bgBottom)!.draw(in: squircle, angle: -90)

	NSGraphicsContext.saveGraphicsState()
	squircle.addClip()
	body()
	// faint top-edge highlight for depth
	let hl = NSBezierPath(roundedRect: iconRect.insetBy(dx: 3, dy: 3), xRadius: 183, yRadius: 183)
	hl.lineWidth = 6
	rgb(0xFFFFFF, 0.06).setStroke()
	hl.stroke()
	NSGraphicsContext.restoreGraphicsState()

	NSGraphicsContext.restoreGraphicsState()
	return rep
}

func playTriangle(center: CGPoint, height: CGFloat, corner: CGFloat) -> NSBezierPath {
	let w = height * 0.866
	let left = center.x - w * 0.40
	return roundedPoly([
		CGPoint(x: left, y: center.y + height / 2),
		CGPoint(x: left + w, y: center.y),
		CGPoint(x: left, y: center.y - height / 2),
	], radius: corner)
}

let darkTop = rgb(0x2C2C31), darkBottom = rgb(0x0E0E11)
let redTop = rgb(0xFF4438), redBottom = rgb(0xDD1205)

// A — dark squircle, red rounded badge, white play
let repA = makeIcon(bgTop: darkTop, bgBottom: darkBottom) {
	let badge = NSBezierPath(roundedRect: NSRect(x: 212, y: 302, width: 600, height: 420),
	                         xRadius: 102, yRadius: 102)
	NSGraphicsContext.saveGraphicsState()
	let sh = NSShadow()
	sh.shadowOffset = NSSize(width: 0, height: -10)
	sh.shadowBlurRadius = 34
	sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
	sh.set()
	redBottom.setFill()
	badge.fill()
	NSGraphicsContext.restoreGraphicsState()
	NSGradient(starting: redTop, ending: redBottom)!.draw(in: badge, angle: -90)
	rgb(0xFFFFFF).setFill()
	playTriangle(center: CGPoint(x: 512, y: 512), height: 210, corner: 24).fill()
}
savePNG(repA, "a.png")

// B — geometric "E" whose middle bar is a red play triangle
let repB = makeIcon(bgTop: darkTop, bgBottom: darkBottom) {
	// red edge border; 24 @1024 master ≈ 3px at 128px dock render (tuning knob)
	let borderW: CGFloat = 24
	let border = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
	                          xRadius: 186, yRadius: 186)
	border.append(NSBezierPath(roundedRect: NSRect(x: 100 + borderW, y: 100 + borderW,
	                                               width: 824 - 2 * borderW, height: 824 - 2 * borderW),
	                           xRadius: 186 - borderW, yRadius: 186 - borderW))
	border.windingRule = .evenOdd
	NSGradient(starting: redTop, ending: redBottom)!.draw(in: border, angle: -90)
	let white = rgb(0xF5F5F7)
	white.setFill()
	NSBezierPath(roundedRect: NSRect(x: 336, y: 618, width: 350, height: 96), xRadius: 28, yRadius: 28).fill()
	NSBezierPath(roundedRect: NSRect(x: 336, y: 310, width: 350, height: 96), xRadius: 28, yRadius: 28).fill()
	NSBezierPath(roundedRect: NSRect(x: 336, y: 310, width: 96, height: 404), xRadius: 28, yRadius: 28).fill()
	let tri = roundedPoly([
		CGPoint(x: 468, y: 587),
		CGPoint(x: 598, y: 512),
		CGPoint(x: 468, y: 437),
	], radius: 18)
	NSGradient(starting: redTop, ending: redBottom)!.draw(in: tri, angle: -90)
}
savePNG(repB, "b.png")

// C — full-bleed red, big white play
let repC = makeIcon(bgTop: rgb(0xFF4A3D), bgBottom: rgb(0xC81104)) {
	rgb(0xFFFFFF).setFill()
	NSGraphicsContext.saveGraphicsState()
	let sh = NSShadow()
	sh.shadowOffset = NSSize(width: 0, height: -8)
	sh.shadowBlurRadius = 24
	sh.shadowColor = NSColor.black.withAlphaComponent(0.25)
	sh.set()
	playTriangle(center: CGPoint(x: 512, y: 512), height: 330, corner: 36).fill()
	NSGraphicsContext.restoreGraphicsState()
}
savePNG(repC, "c.png")

// Contact sheet: big render + dock-dark strip with 128/64/32
let sheet = newRep(1780, 920)
let sctx = NSGraphicsContext(bitmapImageRep: sheet)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = sctx
sctx.imageInterpolation = .high

rgb(0xEDEDF0).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1780, height: 920)).fill()

rgb(0x2B2B2E).setFill()
NSBezierPath(roundedRect: NSRect(x: 40, y: 60, width: 1700, height: 230), xRadius: 24, yRadius: 24).fill()

let names = ["a", "b", "c"]
let labels = ["A — red badge", "B — E-play mark", "C — full red"]
let labelAttrs: [NSAttributedString.Key: Any] = [
	.font: NSFont.systemFont(ofSize: 40, weight: .semibold),
	.foregroundColor: rgb(0x3A3A3E),
]
for (i, name) in names.enumerated() {
	let cx = CGFloat(320 + i * 570)
	let img = NSImage(contentsOfFile: outDir + "/" + name + ".png")!
	img.draw(in: NSRect(x: cx - 256, y: 330, width: 512, height: 512),
	         from: .zero, operation: .sourceOver, fraction: 1)
	for (j, s) in [128, 64, 32].enumerated() {
		let x = cx - 170 + [0, 160, 250][j]
		img.draw(in: NSRect(x: x, y: 110, width: CGFloat(s), height: CGFloat(s)),
		         from: .zero, operation: .sourceOver, fraction: 1)
	}
	let label = NSAttributedString(string: labels[i], attributes: labelAttrs)
	let sz = label.size()
	label.draw(at: NSPoint(x: cx - sz.width / 2, y: 855))
}
NSGraphicsContext.restoreGraphicsState()
savePNG(sheet, "sheet.png")
