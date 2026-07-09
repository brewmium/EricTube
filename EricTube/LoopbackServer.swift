import Foundation
import Network

// Minimal one-shot HTTP listener on 127.0.0.1 that catches Google's OAuth
// loopback redirect, serves a "you can close this tab" page, and hands the
// query parameters back. Ignores stray requests (favicon etc.) that carry
// neither a code nor an error.
final class LoopbackServer: @unchecked Sendable {
	private var listener: NWListener?
	private let queue = DispatchQueue(label: "erictube.oauth.loopback")
	private var pending: CheckedContinuation<[String: String], Never>?

	func start() async throws -> UInt16 {
		for port: UInt16 in [43117, 43118, 43119] {
			guard let nwPort = NWEndpoint.Port(rawValue: port),
			      let candidate = try? NWListener(using: .tcp, on: nwPort) else { continue }
			let ready: Bool = await withCheckedContinuation { cont in
				let once = OneShot()
				candidate.stateUpdateHandler = { state in
					switch state {
					case .ready:
						if once.claim() { cont.resume(returning: true) }
					case .failed, .cancelled:
						if once.claim() { cont.resume(returning: false) }
					default:
						break
					}
				}
				candidate.newConnectionHandler = { [weak self] connection in
					self?.handle(connection)
				}
				candidate.start(queue: queue)
			}
			if ready {
				listener = candidate
				return port
			}
			candidate.cancel()
		}
		throw OAuthError.loopbackBindFailed
	}

	func waitForRedirect() async -> [String: String] {
		await withCheckedContinuation { cont in
			queue.async { self.pending = cont }
		}
	}

	// Idempotent; resolves any waiter with empty params so no task is left
	// hanging on a redirect that will never come.
	func stop() {
		queue.async {
			self.pending?.resume(returning: [:])
			self.pending = nil
			self.listener?.cancel()
			self.listener = nil
		}
	}

	private func handle(_ connection: NWConnection) {
		connection.start(queue: queue)
		receiveRequest(connection, accumulated: Data())
	}

	private func receiveRequest(_ connection: NWConnection, accumulated: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isDone, _ in
			guard let self else { return }
			var buffer = accumulated
			if let data {
				buffer.append(data)
			}
			if let lineEnd = buffer.range(of: Data("\r\n".utf8)),
			   let requestLine = String(data: buffer[..<lineEnd.lowerBound], encoding: .utf8) {
				let params = Self.queryParams(fromRequestLine: requestLine)
				let html = "<html><body style=\"font: 16px -apple-system\">EricTube is authorized. You can close this tab.</body></html>"
				let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
				connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
					connection.cancel()
				})
				if params["code"] != nil || params["error"] != nil, let cont = self.pending {
					self.pending = nil
					cont.resume(returning: params)
				}
			} else if !isDone {
				self.receiveRequest(connection, accumulated: buffer)
			} else {
				connection.cancel()
			}
		}
	}

	private final class OneShot: @unchecked Sendable {
		private let lock = NSLock()
		private var fired = false

		func claim() -> Bool {
			lock.lock()
			defer { lock.unlock() }
			if fired { return false }
			fired = true
			return true
		}
	}

	private static func queryParams(fromRequestLine line: String) -> [String: String] {
		guard let pathPart = line.split(separator: " ").dropFirst().first,
		      let components = URLComponents(string: String(pathPart)) else { return [:] }
		var params: [String: String] = [:]
		for item in components.queryItems ?? [] {
			params[item.name] = item.value
		}
		return params
	}
}
