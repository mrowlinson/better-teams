// Klipy.swift — om-gif-provider-klipy lane: KLIPY GIF search client.
//
// GIF search client (prior provider shut down 2026-06-30; KLIPY is the
// replacement). BYO API key (Settings → GIFs), stored in the
// macOS keychain; no key = picker shows the off-state and no request
// is ever made. Pure URL builders + decoders; the fetcher is
// injectable so tests never touch the network.
//
// API: GET https://api.klipy.com/api/v1/{key}/gifs/search?q=…&per_page=…
//      GET https://api.klipy.com/api/v1/{key}/gifs/trending?per_page=…
// Docs: https://klipy.com/docs (key in path; results under data.data[]).
import Foundation
import Security

/// One GIF hit: thumbnail for the grid, full-size URL sent to the chat.
public struct KlipyGIF: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let previewURL: String
    public let fullURL: String

    public init(id: String, title: String, previewURL: String, fullURL: String) {
        self.id = id
        self.title = title
        self.previewURL = previewURL
        self.fullURL = fullURL
    }
}

public enum KlipyError: Error, Sendable, Equatable {
    case missingKey
    case badResponse(String)
    case network(String)
}

// MARK: - Key storage (mirrors CatchUpKeyStore)

/// API-key persistence seam. Live = macOS keychain; tests inject
/// `KlipyMemoryKeyStore` so they never touch the real keychain.
public protocol KlipyKeyStore: Sendable {
    func load() -> String?
    func save(_ key: String)
    func clear()
}

/// macOS keychain item: service "dev.ostmac.OstMac.klipy", account
/// "klipy-api-key". The key lives here only — never UserDefaults.
public struct KlipySystemKeychain: KlipyKeyStore {
    public static let service = "dev.ostmac.OstMac.klipy"
    public static let account = "klipy-api-key"

    public init() {}

    public func load() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    public func save(_ key: String) {
        guard !key.isEmpty else { clear(); return }
        let data = Data(key.utf8)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        if SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess {
            _ = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = q
            add[kSecValueData as String] = data
            _ = SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func clear() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        _ = SecItemDelete(q as CFDictionary)
    }
}

/// In-memory key store for tests and previews.
public final class KlipyMemoryKeyStore: KlipyKeyStore, @unchecked Sendable {
    private var key: String?

    public init(key: String? = nil) {
        self.key = key
    }

    public func load() -> String? { key }
    public func save(_ key: String) { self.key = key.isEmpty ? nil : key }
    public func clear() { key = nil }
}

public enum KlipyClient {
    /// Stored key, trimmed; empty when the user never set one.
    public static func storedKey(store: KlipyKeyStore = KlipySystemKeychain()) -> String {
        store.load()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Persist a key (trimmed; blank clears). Views call this on edit.
    public static func saveKey(_ key: String, store: KlipyKeyStore = KlipySystemKeychain()) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            store.clear()
        } else {
            store.save(trimmed)
        }
    }

    /// Async bytes fetch; default is a plain URLSession data task.
    public typealias Fetcher = @Sendable (URL) async throws -> (Data, URLResponse)

    public static func liveFetcher(url: URL) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(from: url)
    }

    /// Search URL. Returns nil for an empty key or unencodable query.
    public static func searchURL(query: String, apiKey: String, limit: Int = 24) -> URL? {
        url(path: "search", apiKey: apiKey, limit: limit, extra: [("q", query)])
    }

    /// Trending URL (picker landing page). Nil for an empty key.
    public static func trendingURL(apiKey: String, limit: Int = 24) -> URL? {
        url(path: "trending", apiKey: apiKey, limit: limit, extra: [])
    }

    private static func url(path: String, apiKey: String, limit: Int, extra: [(String, String)]) -> URL? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        // Key is a path segment: encode it as exactly one segment (a raw
        // "/" in the key must not escape into the path).
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard let escaped = key.addingPercentEncoding(withAllowedCharacters: allowed),
              var comps = URLComponents(string: "https://api.klipy.com/api/v1/\(escaped)/gifs/\(path)")
        else { return nil }
        var items = [URLQueryItem(name: "per_page", value: String(max(1, min(limit, 50))))]
        for (k, v) in extra { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items
        return comps.url
    }

    /// Search GIFs. Throws `.missingKey` without a key (no request made).
    public static func search(
        query: String, apiKey: String, limit: Int = 24,
        fetcher: Fetcher = { try await KlipyClient.liveFetcher(url: $0) }
    ) async throws -> [KlipyGIF] {
        guard let url = searchURL(query: query, apiKey: apiKey, limit: limit) else {
            throw KlipyError.missingKey
        }
        return try await fetch(url: url, fetcher: fetcher)
    }

    /// Trending GIFs for the picker landing page.
    public static func trending(
        apiKey: String, limit: Int = 24,
        fetcher: Fetcher = { try await KlipyClient.liveFetcher(url: $0) }
    ) async throws -> [KlipyGIF] {
        guard let url = trendingURL(apiKey: apiKey, limit: limit) else {
            throw KlipyError.missingKey
        }
        return try await fetch(url: url, fetcher: fetcher)
    }

    private static func fetch(url: URL, fetcher: Fetcher) async throws -> [KlipyGIF] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetcher(url)
        } catch {
            throw KlipyError.network(String(describing: error))
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw KlipyError.badResponse("HTTP \(http.statusCode)")
        }
        do {
            return try decode(data)
        } catch {
            throw KlipyError.badResponse(String(describing: error))
        }
    }

    /// Decode a search/trending payload. Results without a playable
    /// gif variant are skipped. Full = hd → md → sm → xs; preview =
    /// sm → xs → full.
    public static func decode(_ data: Data) throws -> [KlipyGIF] {
        let payload = try JSONDecoder().decode(KlipyPayload.self, from: data)
        return payload.items.compactMap { item in
            let file = item.file ?? [:]
            guard let full = file["hd"]?.gif?.url ?? file["md"]?.gif?.url
                ?? file["sm"]?.gif?.url ?? file["xs"]?.gif?.url
            else { return nil }
            let preview = file["sm"]?.gif?.url ?? file["xs"]?.gif?.url ?? full
            return KlipyGIF(id: item.id.string, title: item.title ?? "", previewURL: preview, fullURL: full)
        }
    }
}

// MARK: - Wire format (KLIPY API v1)

/// Top level: `{"result":true,"data":{"data":[...]}}`. `data` is also
/// accepted as a bare array for tolerance.
private struct KlipyPayload: Decodable {
    let items: [KlipyItem]

    private enum CodingKeys: String, CodingKey { case data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let page = try? c.decode(KlipyPage.self, forKey: .data) {
            items = page.data
        } else {
            items = try c.decode([KlipyItem].self, forKey: .data)
        }
    }
}

private struct KlipyPage: Decodable {
    let data: [KlipyItem]
}

private struct KlipyItem: Decodable {
    let id: KlipyID
    let title: String?
    let file: [String: KlipyVariant]?
}

/// KLIPY ids are numbers (int64); accept strings too.
private enum KlipyID: Decodable {
    case int(Int64)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int64.self) {
            self = .int(i)
            return
        }
        self = .string(try c.decode(String.self))
    }

    var string: String {
        switch self {
        case .int(let i): String(i)
        case .string(let s): s
        }
    }
}

/// One size variant (`hd`/`md`/`sm`/`xs`); only the gif rendition is
/// used, other formats (webp/mp4/…) are ignored.
private struct KlipyVariant: Decodable {
    let gif: KlipyFile?
}

private struct KlipyFile: Decodable {
    let url: String
}
