import AppKit
import CryptoKit

enum OAuthError: LocalizedError {
	case noClientSecret
	case notAuthorized
	case loopbackBindFailed
	case denied(String)
	case badTokenResponse
	case timeout

	var errorDescription: String? {
		switch self {
		case .noClientSecret:
			return "no client_secret*.json in Application Support/EricTube"
		case .notAuthorized:
			return "not signed in to Google yet"
		case .loopbackBindFailed:
			return "could not open a local port for the OAuth redirect"
		case .denied(let detail):
			return "Google sign-in failed: \(detail)"
		case .badTokenResponse:
			return "Google returned no refresh token"
		case .timeout:
			return "sign-in timed out (5 minutes)"
		}
	}
}

// OAuth for the YouTube Data API, desktop-app flow: PKCE + loopback
// redirect, consent happens in the user's regular browser (already signed
// in to Google there). Tokens live next to overlay.json, chmod 600.
@MainActor
final class GoogleAuth: ObservableObject {
	static let shared = GoogleAuth()

	// Full manage scope (read + playlist write) for the hybrid model:
	// organize locally, mirror lists back to YouTube as they stabilize.
	static let scope = "https://www.googleapis.com/auth/youtube"

	@Published private(set) var isAuthorized = false
	@Published private(set) var grantedScope: String?

	// True when tokens predate a scope change (e.g. the readonly grant from
	// before write access) — the UI offers a re-consent.
	var needsScopeUpgrade: Bool {
		isAuthorized && grantedScope != Self.scope
	}

	private struct Client: Codable {
		let client_id: String
		let client_secret: String
		let auth_uri: String
		let token_uri: String
	}

	private struct ClientFile: Codable {
		let installed: Client
	}

	private struct Tokens: Codable {
		var accessToken: String
		var refreshToken: String
		var expiry: Date
		var scope: String?
	}

	private struct TokenResponse: Codable {
		let access_token: String
		let refresh_token: String?
		let expires_in: Double
	}

	private var client: Client?
	private var tokens: Tokens?
	private let dir: URL

	private var tokensURL: URL {
		dir.appendingPathComponent("tokens.json")
	}

	init() {
		dir = FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("EricTube", isDirectory: true)
		client = Self.loadClient(from: dir)
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		if let data = try? Data(contentsOf: tokensURL),
		   let stored = try? decoder.decode(Tokens.self, from: data) {
			tokens = stored
			isAuthorized = true
			grantedScope = stored.scope
		}
	}

	var hasClientSecret: Bool {
		client != nil
	}

	// Rescan so dropping the file in while the app runs is enough.
	func reloadClient() {
		if client == nil {
			client = Self.loadClient(from: dir)
		}
	}

	private static func loadClient(from dir: URL) -> Client? {
		guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
		for file in files
		where file.lastPathComponent.hasPrefix("client_secret") && file.pathExtension == "json" {
			if let data = try? Data(contentsOf: file),
			   let wrapper = try? JSONDecoder().decode(ClientFile.self, from: data) {
				return wrapper.installed
			}
		}
		return nil
	}

	func authorize() async throws {
		reloadClient()
		guard let client else { throw OAuthError.noClientSecret }
		let verifier = Self.randomURLSafe(64)
		let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
		let state = Self.randomURLSafe(24)

		let server = LoopbackServer()
		let port = try await server.start()
		defer { server.stop() }
		let redirect = "http://127.0.0.1:\(port)"

		var components = URLComponents(string: client.auth_uri)!
		components.queryItems = [
			URLQueryItem(name: "client_id", value: client.client_id),
			URLQueryItem(name: "redirect_uri", value: redirect),
			URLQueryItem(name: "response_type", value: "code"),
			URLQueryItem(name: "scope", value: Self.scope),
			URLQueryItem(name: "access_type", value: "offline"),
			URLQueryItem(name: "prompt", value: "consent"),
			URLQueryItem(name: "code_challenge", value: challenge),
			URLQueryItem(name: "code_challenge_method", value: "S256"),
			URLQueryItem(name: "state", value: state),
		]
		NSWorkspace.shared.open(components.url!)

		let params = try await withThrowingTaskGroup(of: [String: String].self) { group in
			group.addTask {
				await server.waitForRedirect()
			}
			group.addTask {
				try await Task.sleep(for: .seconds(300))
				throw OAuthError.timeout
			}
			do {
				guard let first = try await group.next() else { throw OAuthError.timeout }
				group.cancelAll()
				return first
			} catch {
				// Unblocks the redirect-wait child so the group can drain.
				server.stop()
				throw error
			}
		}

		if let error = params["error"] {
			throw OAuthError.denied(error)
		}
		guard let code = params["code"], params["state"] == state else {
			throw OAuthError.denied("missing code or state mismatch")
		}

		let body = Self.formEncode([
			"code": code,
			"client_id": client.client_id,
			"client_secret": client.client_secret,
			"redirect_uri": redirect,
			"grant_type": "authorization_code",
			"code_verifier": verifier,
		])
		let response = try await tokenRequest(body: body, client: client)
		guard let refresh = response.refresh_token else { throw OAuthError.badTokenResponse }
		tokens = Tokens(
			accessToken: response.access_token,
			refreshToken: refresh,
			expiry: Date().addingTimeInterval(response.expires_in - 60),
			scope: Self.scope)
		persistTokens()
		isAuthorized = true
		grantedScope = Self.scope
	}

	func validAccessToken() async throws -> String {
		guard var current = tokens else { throw OAuthError.notAuthorized }
		if current.expiry > Date() {
			return current.accessToken
		}
		guard let client else { throw OAuthError.noClientSecret }
		let body = Self.formEncode([
			"client_id": client.client_id,
			"client_secret": client.client_secret,
			"refresh_token": current.refreshToken,
			"grant_type": "refresh_token",
		])
		let response = try await tokenRequest(body: body, client: client)
		current.accessToken = response.access_token
		current.expiry = Date().addingTimeInterval(response.expires_in - 60)
		if let newRefresh = response.refresh_token {
			current.refreshToken = newRefresh
		}
		tokens = current
		persistTokens()
		return current.accessToken
	}

	private func tokenRequest(body: String, client: Client) async throws -> TokenResponse {
		var request = URLRequest(url: URL(string: client.token_uri)!)
		request.httpMethod = "POST"
		request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
		request.httpBody = Data(body.utf8)
		let (data, response) = try await URLSession.shared.data(for: request)
		guard (response as? HTTPURLResponse)?.statusCode == 200 else {
			throw OAuthError.denied(String(data: data, encoding: .utf8) ?? "token endpoint error")
		}
		return try JSONDecoder().decode(TokenResponse.self, from: data)
	}

	private func persistTokens() {
		guard let tokens else { return }
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		if let data = try? encoder.encode(tokens) {
			try? data.write(to: tokensURL, options: .atomic)
			try? FileManager.default.setAttributes(
				[.posixPermissions: 0o600], ofItemAtPath: tokensURL.path)
		}
	}

	private static func randomURLSafe(_ length: Int) -> String {
		let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
		return String((0..<length).map { _ in chars.randomElement()! })
	}

	private static func formEncode(_ params: [String: String]) -> String {
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-._~")
		return params
			.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
			.joined(separator: "&")
	}
}

private extension Data {
	var base64URLEncoded: String {
		base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}
}
