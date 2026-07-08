import SwiftUI
import WebKit

// Hosts an externally owned WKWebView. The view's lifecycle belongs to
// WebSessionManager, not SwiftUI — this wrapper only mounts it.
struct WebView: NSViewRepresentable {
	let webView: WKWebView

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	func makeNSView(context: Context) -> WKWebView {
		webView.uiDelegate = context.coordinator
		return webView
	}

	func updateNSView(_ nsView: WKWebView, context: Context) {}

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
