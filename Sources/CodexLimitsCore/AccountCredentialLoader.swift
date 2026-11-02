import Foundation

enum AccountCredentialLoader {
    private struct AuthFile: Decodable {
        let tokens: Tokens
    }

    private struct Tokens: Decodable {
        let idToken: String?
        let accountID: String

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accountID = "account_id"
        }
    }

    struct Identity: Sendable, Equatable {
        let email: String
        let accountID: String
    }

    static func identity(data: Data) throws -> Identity {
        let decoded = try JSONDecoder().decode(AuthFile.self, from: data)
        guard let idToken = decoded.tokens.idToken,
              let email = jwtEmail(idToken),
              !email.isEmpty
        else {
            throw CodexClientError.protocolError("Saved ChatGPT credentials do not contain an account email.")
        }
        return Identity(email: email, accountID: decoded.tokens.accountID)
    }

    static func identity(at authFile: URL) throws -> Identity {
        try identity(data: Data(contentsOf: authFile))
    }

    private static func jwtEmail(_ token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = object["email"] as? String
        else { return nil }
        return email
    }
}
