import AuthenticationServices
import Foundation
import UIKit

/// WebAuthn passkeys with the system UI (Face ID / Touch ID / iCloud Keychain).
/// Requires the Associated Domains entitlement `webcredentials:<NAS domain>` and the
/// server serving /.well-known/apple-app-site-association over HTTPS.
@MainActor
public final class PasskeyAuthenticator: NSObject {
    private let api: APIClient
    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    public init(api: APIClient) { self.api = api }

    public func register(name: String) async throws {
        let begin = try await api.rawPost("api/auth/passkeys/register/begin", json: [:], auth: true)
        guard let ceremonyId = begin["ceremonyId"] as? String,
              let options = begin["options"] as? [String: Any],
              let rp = options["rp"] as? [String: Any], let rpId = rp["id"] as? String,
              let user = options["user"] as? [String: Any],
              let challenge = (options["challenge"] as? String).flatMap(Data.init(base64URL:)),
              let userId = (user["id"] as? String).flatMap(Data.init(base64URL:)),
              let userName = user["name"] as? String
        else { throw APIError.http(500, "Opzioni passkey non valide") }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let request = provider.createCredentialRegistrationRequest(challenge: challenge, name: userName, userID: userId)
        let auth = try await perform([request])

        guard let cred = auth.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestation = cred.rawAttestationObject
        else { throw APIError.http(500, "Registrazione passkey annullata") }

        let id = cred.credentialID.base64URLEncoded
        _ = try await api.rawPost("api/auth/passkeys/register/finish", json: [
            "ceremonyId": ceremonyId,
            "name": name,
            "response": [
                "id": id, "rawId": id, "type": "public-key",
                "response": [
                    "attestationObject": attestation.base64URLEncoded,
                    "clientDataJSON": cred.rawClientDataJSON.base64URLEncoded,
                    "transports": ["internal", "hybrid"],
                ],
                "clientExtensionResults": [String: Any](),
            ],
        ], auth: true)
    }

    public func login(username: String?) async throws -> AuthResponse {
        var body: [String: Any] = [:]
        if let username, !username.isEmpty { body["username"] = username }
        let begin = try await api.rawPost("api/auth/passkeys/login/begin", json: body, auth: false)
        guard let ceremonyId = begin["ceremonyId"] as? String,
              let options = begin["options"] as? [String: Any],
              let challenge = (options["challenge"] as? String).flatMap(Data.init(base64URL:)),
              let rpId = options["rpId"] as? String ?? api.baseURL.host
        else { throw APIError.http(500, "Opzioni passkey non valide") }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        if let allowed = options["allowCredentials"] as? [[String: Any]], !allowed.isEmpty {
            request.allowedCredentials = allowed.compactMap { ($0["id"] as? String).flatMap(Data.init(base64URL:)) }
                .map(ASAuthorizationPlatformPublicKeyCredentialDescriptor.init(credentialID:))
        }
        let auth = try await perform([request])
        guard let cred = auth.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion
        else { throw APIError.http(500, "Accesso passkey annullato") }

        let id = cred.credentialID.base64URLEncoded
        let json = try await api.rawPost("api/auth/passkeys/login/finish", json: [
            "ceremonyId": ceremonyId,
            "response": [
                "id": id, "rawId": id, "type": "public-key",
                "response": [
                    "authenticatorData": cred.rawAuthenticatorData.base64URLEncoded,
                    "signature": cred.signature.base64URLEncoded,
                    "clientDataJSON": cred.rawClientDataJSON.base64URLEncoded,
                    "userHandle": cred.userID.base64URLEncoded,
                ],
                "clientExtensionResults": [String: Any](),
            ],
        ], auth: false)
        let data = try JSONSerialization.data(withJSONObject: json)
        return try APIClient.decoder.decode(AuthResponse.self, from: data)
    }

    private func perform(_ requests: [ASAuthorizationRequest]) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let controller = ASAuthorizationController(authorizationRequests: requests)
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }
}

extension PasskeyAuthenticator: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    public nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated { continuation?.resume(returning: authorization); continuation = nil }
    }

    public nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated { continuation?.resume(throwing: error); continuation = nil }
    }

    public nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}

extension Data {
    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }

    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
