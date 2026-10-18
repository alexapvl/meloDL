import AppKit
import CryptoKit
import Foundation
import Network

/// Spotify Authorization Code + PKCE login through the default browser and a loopback redirect.
@MainActor
enum SpotifyAuthService {
    static let callbackPort: UInt16 = 43821
    static let redirectURI = "http://127.0.0.1:\(callbackPort)/callback"
    static let dashboardURL = URL(string: "https://developer.spotify.com/dashboard")!
    private static let scopes = "playlist-read-private playlist-read-collaborative user-library-read"

    static func isValidClientID(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy(\.isHexDigit)
    }

    /// Returns the connected account's display name.
    static func connect(clientID: String) async throws -> String {
        let verifier = randomURLSafeString(byteCount: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = randomURLSafeString(byteCount: 16)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes)
        ]

        let server = try LoopbackCallbackServer(port: callbackPort)
        defer { server.stop() }
        NSWorkspace.shared.open(components.url!)

        let query = try await server.waitForCallback(timeout: 300)
        if let error = query["error"] {
            throw SpotifyError.authFailed(error == "access_denied" ? "Access was denied." : error)
        }
        guard query["state"] == state, let code = query["code"] else {
            throw SpotifyError.authFailed("Unexpected response from Spotify.")
        }

        let token = try await SpotifyService.tokenRequest(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier
        ])
        guard let refreshToken = token.refreshToken else {
            throw SpotifyError.authFailed("Spotify didn't return a refresh token.")
        }
        return try await SpotifyService.shared.storeConnection(
            clientID: clientID,
            refreshToken: refreshToken,
            accessToken: token.accessToken,
            expiresIn: token.expiresIn
        )
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        Data((0 ..< byteCount).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncoded
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

/// One-shot HTTP listener on 127.0.0.1 that captures the `/callback` query string.
private final class LoopbackCallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.alexapvl.meloDL.spotify-callback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pendingResult: Result<[String: String], Error>?

    init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.finish(.failure(SpotifyError.authFailed("Couldn't listen on port \(port) (\(error.localizedDescription)). Close other apps using it and try again.")))
            }
        }
        listener.start(queue: queue)
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.finish(.failure(SpotifyError.authFailed("Timed out waiting for the browser login.")))
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let pendingResult {
                    lock.unlock()
                    continuation.resume(with: pendingResult)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    func stop() {
        listener.cancel()
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        guard pendingResult == nil else {
            lock.unlock()
            return
        }
        pendingResult = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?
                .components(separatedBy: "\r\n").first ?? ""
            let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let components = URLComponents(string: "http://127.0.0.1\(target)")

            guard components?.path == "/callback" else {
                Self.respond(connection, status: "404 Not Found", body: "Not found")
                return
            }

            var query: [String: String] = [:]
            for item in components?.queryItems ?? [] {
                query[item.name] = item.value
            }
            let succeeded = query["code"] != nil
            Self.respond(
                connection,
                status: "200 OK",
                body: succeeded
                    ? "<h2>Spotify login received.</h2><p>You can close this tab and return to meloDL.</p>"
                    : "<h2>Spotify login didn't complete.</h2><p>Return to meloDL and try again.</p>"
            )
            self?.finish(.success(query))
        }
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>meloDL</title></head><body style=\"font-family: -apple-system; padding: 40px\">\(body)</body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
