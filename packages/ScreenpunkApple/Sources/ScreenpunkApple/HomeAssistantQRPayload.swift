import Foundation

struct HomeAssistantQRPayload {
    let origin: String?
    let token: String
    static func parse(_ raw: String) -> Self? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 16384 else { return nil }
        if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard let token = (object["token"] ?? object["access_token"]) as? String, validToken(token),
                  let origin = (object["origin"] ?? object["url"] ?? object["server"]) as? String,
                  let parts = URLComponents(string: origin), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  parts.host != nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  parts.path.isEmpty || parts.path == "/" else { return nil }
            return Self(origin: origin, token: token)
        }
        // Home Assistant long-lived tokens are JWTs. Never treat arbitrary URLs as secrets.
        guard text.split(separator: ".", omittingEmptySubsequences: false).count == 3, validToken(text),
              text.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0) }) else { return nil }
        return Self(origin: nil, token: text)
    }
    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 8192 && !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) })
    }
}
