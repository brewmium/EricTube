import SwiftUI
import WebKit

// A web view that goes fully inert when not the active session: returning nil
// from hitTest keeps AppKit from routing ANY mouse event to it — clicks,
// mouse-moved, and (the visible symptom) WebKit's own hover tooltips. Without
// this, hidden background views leak tooltips and stray clicks release their
// pause hold. SwiftUI's .allowsHitTesting doesn't reach this AppKit layer.
final class SessionWebView: WKWebView {
	var interactive = true

	// Recovery bookkeeping, driven by WebSessionManager's navigation sentry.
	// intendedURL is the URL the app last deliberately drove this view to —
	// unlike `url` it exists before a load commits and survives a load that
	// never does, so snapshots and recovery reloads never depend on WebKit
	// having gotten there. needsRecovery marks a view that must reload before
	// it's usable (dead web content process, exhausted load retries).
	var intendedURL: URL?
	var needsRecovery = false
	var loadRetries = 0

	override func hitTest(_ point: NSPoint) -> NSView? {
		interactive ? super.hitTest(point) : nil
	}
}

// Hosts an externally owned WKWebView. The view's lifecycle belongs to
// WebSessionManager, not SwiftUI — this wrapper only mounts it.
struct WebView: NSViewRepresentable {
	let webView: WKWebView
	var interactive = true

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	func makeNSView(context: Context) -> WKWebView {
		webView.uiDelegate = context.coordinator
		return webView
	}

	func updateNSView(_ nsView: WKWebView, context: Context) {
		(nsView as? SessionWebView)?.interactive = interactive
	}

	@MainActor
	final class Coordinator: NSObject, WKUIDelegate {
		// Sign-in flows may window.open; there are no popup windows in
		// Phase 0, so route them into the same web view instead of
		// silently dropping them.
		func webView(
			_ webView: WKWebView,
			createWebViewWith configuration: WKWebViewConfiguration,
			for navigationAction: WKNavigationAction,
			windowFeatures: WKWindowFeatures
		) -> WKWebView? {
			if let url = navigationAction.request.url {
				webView.load(URLRequest(url: url))
			}
			return nil
		}
	}
}
