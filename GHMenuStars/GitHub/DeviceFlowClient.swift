import Foundation

struct DeviceCodeResponse: Decodable, Equatable {
    var deviceCode: String
    var userCode: String
    var verificationURI: String
    var expiresIn: Int
    var interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

struct DeviceTokenResponse: Decodable, Equatable {
    var accessToken: String
    var tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
    }
}

final class DeviceFlowClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func requestDeviceCode(clientID: String) async throws -> DeviceCodeResponse {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "scope": "public_repo"
        ])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GitHubError.server((response as? HTTPURLResponse)?.statusCode ?? -1) }
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    func pollForToken(clientID: String, deviceCode: String, interval: Int) async throws -> DeviceTokenResponse {
        while true {
            try await Task.sleep(nanoseconds: UInt64(max(interval, 5)) * 1_000_000_000)
            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_id": clientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GitHubError.server((response as? HTTPURLResponse)?.statusCode ?? -1) }
            if let error = try? JSONDecoder().decode(DeviceFlowErrorResponse.self, from: data) {
                switch error.error {
                case "authorization_pending":
                    continue
                case "slow_down":
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                case "access_denied":
                    throw GitHubError.authDenied
                default:
                    throw GitHubError.unauthorized
                }
            }
            return try JSONDecoder().decode(DeviceTokenResponse.self, from: data)
        }
    }
}

private struct DeviceFlowErrorResponse: Decodable {
    var error: String
}

