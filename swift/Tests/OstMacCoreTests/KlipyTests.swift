// KlipyTests.swift — om-gif-provider-klipy lane: URL builders, payload
// decode, keychain key store, off-state. Fixtures inline; the live test
// runs only with KLIPY_KEY in the environment (no key in repo).
import XCTest

@testable import OstMacCore

final class KlipyTests: XCTestCase {
    // MARK: - URL builders

    func testSearchURLShape() {
        let url = KlipyClient.searchURL(query: "party parrot", apiKey: "K")!
        XCTAssertEqual(url.host, "api.klipy.com")
        XCTAssertEqual(url.path, "/api/v1/K/gifs/search")
        XCTAssertTrue(url.absoluteString.contains("per_page=24"))
        // Query is percent-encoded, never raw.
        XCTAssertTrue(url.absoluteString.contains("q=party%20parrot"))
    }

    func testTrendingURLShape() {
        let url = KlipyClient.trendingURL(apiKey: "K", limit: 10)!
        XCTAssertEqual(url.host, "api.klipy.com")
        XCTAssertEqual(url.path, "/api/v1/K/gifs/trending")
        XCTAssertTrue(url.absoluteString.contains("per_page=10"))
    }

    func testEmptyKeyYieldsNil() {
        XCTAssertNil(KlipyClient.searchURL(query: "x", apiKey: "  "))
        XCTAssertNil(KlipyClient.trendingURL(apiKey: ""))
    }

    func testLimitClamped() {
        XCTAssertTrue(KlipyClient.trendingURL(apiKey: "K", limit: 999)!.absoluteString.contains("per_page=50"))
        XCTAssertTrue(KlipyClient.trendingURL(apiKey: "K", limit: 0)!.absoluteString.contains("per_page=1"))
    }

    func testKeyWithSlashStaysOneSegment() {
        // A hostile key must not escape the path segment.
        let url = KlipyClient.trendingURL(apiKey: "a/b")!
        // NB: url.path decodes %2F; the wire form must keep it encoded.
        XCTAssertTrue(url.absoluteString.contains("/api/v1/a%2Fb/gifs/trending"))
    }

    // MARK: - decode

    func testDecodeSearchPayload() throws {
        let gifs = try KlipyClient.decode(Data(Self.payload.utf8))
        XCTAssertEqual(gifs.count, 2)
        // Numeric id stringified; preview = sm, full = hd.
        XCTAssertEqual(gifs[0].id, "8041071659142944")
        XCTAssertEqual(gifs[0].title, "Party Parrot")
        XCTAssertEqual(gifs[0].previewURL, "https://k/sm1")
        XCTAssertEqual(gifs[0].fullURL, "https://k/hd1")
        // md-only item: preview falls back to the full gif.
        XCTAssertEqual(gifs[1].id, "222")
        XCTAssertEqual(gifs[1].title, "")
        XCTAssertEqual(gifs[1].previewURL, "https://k/md2")
        XCTAssertEqual(gifs[1].fullURL, "https://k/md2")
    }

    func testDecodeSkipsUnplayable() throws {
        // mp4-only variant + empty file map: no gif URL anywhere.
        let json = """
            {"result":true,"data":{"data":[
              {"id":9,"title":"x","slug":"x-9","file":{"md":{"mp4":{"url":"https://k/v"}}}},
              {"id":10,"title":"y","slug":"y-10","file":{}}
            ]}}
            """
        XCTAssertEqual(try KlipyClient.decode(Data(json.utf8)).count, 0)
    }

    func testDecodeEmpty() throws {
        XCTAssertEqual(try KlipyClient.decode(Data(#"{"result":true,"data":{"data":[]}}"#.utf8)).count, 0)
    }

    // MARK: - search (mocked fetcher, no network)

    func testSearchUsesFetcherAndDecodes() async throws {
        let gifs = try await KlipyClient.search(query: "parrot", apiKey: "K") { url in
            XCTAssertTrue(url.absoluteString.contains("q=parrot"))
            XCTAssertTrue(url.path.hasSuffix("/gifs/search"))
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(Self.payload.utf8), resp)
        }
        XCTAssertEqual(gifs.count, 2)
    }

    func testTrendingUsesFetcherAndDecodes() async throws {
        let gifs = try await KlipyClient.trending(apiKey: "K") { url in
            XCTAssertTrue(url.path.hasSuffix("/gifs/trending"))
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(Self.payload.utf8), resp)
        }
        XCTAssertEqual(gifs.count, 2)
    }

    func testSearchWithoutKeyNeverFetches() async {
        let fetched = LockedBox(false)
        do {
            _ = try await KlipyClient.search(query: "parrot", apiKey: "") { _ in
                fetched.value = true
                throw KlipyError.network("unreachable")
            }
            XCTFail("expected missingKey")
        } catch KlipyError.missingKey {
            // Expected: no request without a key.
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertFalse(fetched.value)
    }

    func testHTTPErrorSurfaces() async {
        do {
            _ = try await KlipyClient.trending(apiKey: "BAD") { url in
                let resp = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            }
            XCTFail("expected badResponse")
        } catch KlipyError.badResponse(let m) {
            XCTAssertTrue(m.contains("403"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - key store (memory; never the real keychain)

    func testMemoryKeyStoreRoundTrip() {
        let store = KlipyMemoryKeyStore()
        XCTAssertNil(store.load())
        store.save("K")
        XCTAssertEqual(store.load(), "K")
        store.save("") // empty save clears
        XCTAssertNil(store.load())
        store.save("K2")
        store.clear()
        XCTAssertNil(store.load())
    }

    func testStoredKeyTrimsAndDefaultsEmpty() {
        XCTAssertEqual(KlipyClient.storedKey(store: KlipyMemoryKeyStore()), "")
        XCTAssertEqual(KlipyClient.storedKey(store: KlipyMemoryKeyStore(key: "  K \n")), "K")
    }

    func testSaveKeyTrimsAndClears() {
        let store = KlipyMemoryKeyStore()
        KlipyClient.saveKey("  K ", store: store)
        XCTAssertEqual(store.load(), "K")
        KlipyClient.saveKey("   ", store: store)
        XCTAssertNil(store.load())
    }

    // MARK: - live (opt-in via KLIPY_KEY env; skipped without it)

    func testLiveSearch() async throws {
        guard let key = ProcessInfo.processInfo.environment["KLIPY_KEY"],
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw XCTSkip("KLIPY_KEY not set; live KLIPY check skipped")
        }
        let gifs = try await KlipyClient.search(query: "cat", apiKey: key)
        XCTAssertFalse(gifs.isEmpty, "live search returned no GIFs")
        XCTAssertTrue(gifs[0].fullURL.hasPrefix("https://"))
    }

    // MARK: - composer insert

    func testAppendGIFJoinsWithSpace() {
        XCTAssertEqual(ConversationStore.appendGIF("https://k/g", to: ""), "https://k/g")
        XCTAssertEqual(ConversationStore.appendGIF("https://k/g", to: "look"), "look https://k/g")
    }

    private nonisolated static let payload = """
        {"result":true,"data":{"data":[
          {"id":8041071659142944,"title":"Party Parrot","slug":"party-parrot-1","type":"gif",
           "file":{
             "xs":{"gif":{"url":"https://k/xs1"}},
             "sm":{"gif":{"url":"https://k/sm1"}},
             "md":{"gif":{"url":"https://k/md1"}},
             "hd":{"gif":{"url":"https://k/hd1"}}}},
          {"id":"222","title":"","slug":"s-222","type":"gif",
           "file":{"md":{"gif":{"url":"https://k/md2"}}}}
        ]}}
        """
}
