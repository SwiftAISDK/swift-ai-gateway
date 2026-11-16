import Foundation

/// Shared WebSocket subprotocol contract for AI Gateway realtime, streaming
/// transcription and streaming speech authentication.
///
/// Browser WebSockets cannot set request headers, so the Gateway bearer token
/// rides the `Sec-WebSocket-Protocol` handshake. Clients encode values with the
/// `*Protocols` helpers; a Gateway-compatible server decodes them with
/// ``authToken(fromSecWebSocketProtocol:)`` and
/// ``teamIDOrSlug(fromSecWebSocketProtocol:)``. The auth token is sent as-is,
/// so it must be a valid subprotocol token; team scoping is base64url-encoded.
public enum GatewayRealtimeAuth {
    /// Marker subprotocol offered on every realtime handshake.
    public static let realtimeSubprotocol = "ai-gateway-realtime.v1"
    /// Marker subprotocol for streaming transcription handshakes.
    public static let transcriptionSubprotocol = "ai-gateway-transcription.v1"
    /// Marker subprotocol for streaming speech handshakes.
    public static let speechSubprotocol = "ai-gateway-speech.v1"
    /// Subprotocol prefix that carries the Gateway auth (bearer) token.
    public static let authSubprotocolPrefix = "ai-gateway-auth."
    /// Subprotocol prefix that carries optional Vercel team scoping.
    public static let teamSubprotocolPrefix = "ai-gateway-team."

    /// Subprotocols that carry `token` (and optional team scope) for realtime.
    public static func realtimeProtocols(token: String, teamIDOrSlug: String? = nil) -> [String] {
        protocols(marker: realtimeSubprotocol, token: token, teamIDOrSlug: teamIDOrSlug)
    }

    /// Subprotocols for streaming transcription handshakes.
    public static func transcriptionProtocols(token: String, teamIDOrSlug: String? = nil) -> [String] {
        protocols(marker: transcriptionSubprotocol, token: token, teamIDOrSlug: teamIDOrSlug)
    }

    /// Subprotocols for streaming speech handshakes.
    public static func speechProtocols(token: String, teamIDOrSlug: String? = nil) -> [String] {
        protocols(marker: speechSubprotocol, token: token, teamIDOrSlug: teamIDOrSlug)
    }

    /// Server side: the Gateway auth token from a raw `Sec-WebSocket-Protocol`
    /// header value, or `nil` when absent or empty. Subprotocols are
    /// comma-separated and may carry surrounding whitespace.
    public static func authToken(fromSecWebSocketProtocol header: String?) -> String? {
        guard let value = findProtocol(header, prefix: authSubprotocolPrefix)?
            .dropFirst(authSubprotocolPrefix.count), !value.isEmpty else { return nil }
        return String(value)
    }

    /// Server side: the base64url-decoded Vercel team ID or slug, or `nil`
    /// when absent, empty or malformed.
    public static func teamIDOrSlug(fromSecWebSocketProtocol header: String?) -> String? {
        guard let encoded = findProtocol(header, prefix: teamSubprotocolPrefix)?
            .dropFirst(teamSubprotocolPrefix.count), !encoded.isEmpty else { return nil }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        let decoded = String(decoding: data, as: UTF8.self)
        return decoded.isEmpty ? nil : decoded
    }

    static func encodeSubprotocolValue(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func protocols(marker: String, token: String, teamIDOrSlug: String?) -> [String] {
        var result = [marker, authSubprotocolPrefix + token]
        if let teamIDOrSlug, !teamIDOrSlug.isEmpty {
            result.append(teamSubprotocolPrefix + encodeSubprotocolValue(teamIDOrSlug))
        }
        return result
    }

    private static func findProtocol(_ header: String?, prefix: String) -> String? {
        header?
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix(prefix) }
    }
}
