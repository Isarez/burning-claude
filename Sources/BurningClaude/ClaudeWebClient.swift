import Foundation

/// Reads Anthropic's own 5-hour and 7-day figures straight from claude.ai,
/// authenticated with a session cookie the user supplies.
///
/// This is the source ClaudeMeter uses, and it is the only way to get a figure
/// **on demand**: the config-directory path can only report what Claude Code
/// last cached, which goes stale the moment you stop running it.
///
/// The trade-offs are real and are why this is opt-in per account rather than
/// the default. It is a private API — undocumented, free to change without
/// notice, and behind Cloudflare. It means handling a credential that grants
/// full access to the account. And ClaudeMeter's own README notes that using it
/// may be at odds with the claude.ai Terms of Service.
enum ClaudeWebClient {

    private static let base = "https://claude.ai/api"

    struct Organization: Decodable, Sendable {
        var uuid: String
        var name: String
    }

    enum Failure: LocalizedError {
        case unauthorized
        case rateLimited
        case forbidden
        case http(Int)
        case noOrganizations
        case malformed
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "claude.ai rejected the session key. Keys expire when you "
                     + "sign out or after a while — copy a fresh one and try again."
            case .rateLimited:
                return "claude.ai is rate-limiting these requests. Try a longer "
                     + "refresh interval in Settings."
            case .forbidden:
                return "claude.ai refused the request (403). This usually means "
                     + "Cloudflare blocked it; opening claude.ai in your browser "
                     + "once and copying a fresh key normally clears it."
            case .http(let code):
                return "claude.ai returned HTTP \(code)."
            case .noOrganizations:
                return "That session key works, but claude.ai lists no "
                     + "organisation for it."
            case .malformed:
                return "claude.ai returned usage in a shape this app does not "
                     + "recognise. The private API it reads may have changed."
            case .transport(let detail):
                return detail
            }
        }
    }

    // MARK: - Endpoints

    static func organizations(key: SessionKey) async throws -> [Organization] {
        try await get([Organization].self, from: "\(base)/organizations", key: key)
    }

    /// The account's live utilization, in the same shape the rest of the app
    /// already speaks — so the gauges, thresholds and notifications need to
    /// know nothing about where a figure came from.
    static func usage(organization: String, key: SessionKey) async throws -> UtilizationSnapshot {
        let response = try await get(
            UsageResponse.self, from: "\(base)/organizations/\(organization)/usage", key: key
        )
        guard response.fiveHour != nil || response.sevenDay != nil else {
            throw Failure.malformed
        }
        return UtilizationSnapshot(
            accountUUID: "session:\(organization)",
            fetchedAt: Date(),
            fiveHour: limit(from: response.fiveHour),
            sevenDay: limit(from: response.sevenDay)
        )
    }

    /// Best-effort email, used only to label the account. Every failure mode
    /// here is uninteresting — the organisation name is a perfectly good
    /// fallback — so this reports `nil` rather than throwing.
    static func email(key: SessionKey) async -> String? {
        guard let data = try? await fetch(url: "\(base)/bootstrap", key: key),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return findEmail(in: json)
    }

    // MARK: - Response shapes

    /// Every field optional: a missing `seven_day_sonnet`, or a new sibling
    /// key appearing, must not fail the fields we do care about.
    private struct UsageResponse: Decodable {
        var fiveHour: Limit?
        var sevenDay: Limit?

        struct Limit: Decodable {
            var utilization: Double?
            var resetsAt: String?

            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private static func limit(from raw: UsageResponse.Limit?) -> UtilizationSnapshot.Limit? {
        guard let raw, let utilization = raw.utilization else { return nil }
        // `resets_at` is nullable. `.distantFuture` is how the rest of the app
        // already spells "in window, but no reset instant published" — it reads
        // as current and suppresses the countdown line.
        let resets = raw.resetsAt.flatMap(ISO8601.date(from:)) ?? .distantFuture
        return UtilizationSnapshot.Limit(percent: Int(utilization.rounded()), resetsAt: resets)
    }

    /// Walks the bootstrap payload for an email rather than pinning a path
    /// through it. The path is undocumented and has moved before; the failure
    /// mode of guessing wrong is a worse label, so a tolerant search is the
    /// better trade than a brittle `account.email_address`.
    private static func findEmail(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            for key in ["email_address", "emailAddress", "email"] {
                if let found = dict[key] as? String, found.contains("@") { return found }
            }
            for nested in dict.values {
                if let found = findEmail(in: nested) { return found }
            }
        }
        if let array = value as? [Any] {
            for element in array {
                if let found = findEmail(in: element) { return found }
            }
        }
        return nil
    }

    // MARK: - Transport

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        // The session key is passed explicitly on every request; letting
        // URLSession keep its own cookie jar would only add a second, invisible
        // source of identity.
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    private static func get<T: Decodable>(_ type: T.Type, from url: String, key: SessionKey) async throws -> T {
        let data = try await fetch(url: url, key: key)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw Failure.malformed
        }
    }

    private static func fetch(url string: String, key: SessionKey) async throws -> Data {
        guard let url = URL(string: string), url.scheme == "https" else {
            throw Failure.transport("Bad URL: \(string)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(key.value)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // claude.ai sits behind Cloudflare, which turns away requests that do
        // not look like the browser the cookie was issued to.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        switch http.statusCode {
        case 200...299: return data
        case 401:       throw Failure.unauthorized
        case 403:       throw Failure.forbidden
        case 429:       throw Failure.rateLimited
        default:        throw Failure.http(http.statusCode)
        }
    }
}
