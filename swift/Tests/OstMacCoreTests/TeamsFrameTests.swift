// TeamsFrameTests.swift — teams-frame FULL: URL allowlist, launch-flag
// parsing, keep-alive/destroy seams, registry, escape matrix, popup /
// download seams, suspend/footprint lifecycle. No live login, no network,
// no live WKWebView — pure config + store lifecycle only.
import WebKit
import XCTest

@testable import OstMacCore

@MainActor
final class TeamsFrameTests: XCTestCase {
    // MARK: - Allowlist

    func testAllowsTeamsHosts() {
        for raw in [
            "https://teams.microsoft.com/",
            "https://teams.microsoft.com/l/entity/abc",
            "https://sub.teams.microsoft.com/x",
            "https://teams.live.com/meet/123",
        ] {
            XCTAssertTrue(
                TeamsFrameConfig.isAllowed(URL(string: raw)!), raw)
        }
    }

    func testAllowsAuthAndContentHosts() {
        for raw in [
            "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            "https://login.live.com/oauth20_authorize.srf",
            "https://contoso.sharepoint.com/sites/x",
            "https://contoso-my.sharepoint.com/personal/y",
            "https://outlook.office.com/owa/",
            "https://res.cdn.office.net/assets/x.js",
        ] {
            XCTAssertTrue(
                TeamsFrameConfig.isAllowed(URL(string: raw)!), raw)
        }
    }

    func testBlocksNonAllowlistedAndSpoofs() {
        for raw in [
            "https://evil.com/teams.microsoft.com",
            "https://teams.microsoft.com.evil.com/",
            "https://notteams-microsoft.com/",
            "https://example.com/",
        ] {
            XCTAssertFalse(
                TeamsFrameConfig.isAllowed(URL(string: raw)!), raw)
        }
    }

    func testAboutBlankAllowedOtherHostlessBlocked() {
        XCTAssertTrue(TeamsFrameConfig.isAllowed(URL(string: "about:blank")!))
        XCTAssertFalse(TeamsFrameConfig.isAllowed(URL(string: "file:///etc/passwd")!))
    }

    func testHostMatchIsCaseInsensitive() {
        XCTAssertTrue(
            TeamsFrameConfig.isAllowed(URL(string: "https://Teams.Microsoft.Com/x")!))
    }

    // MARK: - Launch flags

    func testLaunchURLDefault() {
        XCTAssertEqual(
            TeamsFrameConfig.launchURL(args: ["Better Teams"]),
            "https://teams.microsoft.com")
    }

    func testLaunchURLFromFlag() {
        let deep = "https://teams.microsoft.com/l/entity/abc123?label=App"
        XCTAssertEqual(
            TeamsFrameConfig.launchURL(args: ["Better Teams", "--teams-frame-url", deep]),
            deep)
    }

    func testLaunchURLMissingValueFallsBackToDefault() {
        XCTAssertEqual(
            TeamsFrameConfig.launchURL(args: ["Better Teams", "--teams-frame-url"]),
            "https://teams.microsoft.com")
    }

    func testShouldOpen() {
        XCTAssertFalse(TeamsFrameConfig.shouldOpen(args: ["Better Teams"]))
        XCTAssertTrue(TeamsFrameConfig.shouldOpen(args: ["Better Teams", "--show-teams-frame"]))
        XCTAssertTrue(TeamsFrameConfig.shouldOpen(args: [
            "Better Teams", "--teams-frame-url", "https://teams.microsoft.com",
        ]))
    }

    func testFullFrameFlag() {
        XCTAssertFalse(TeamsFrameConfig.fullFrame(args: ["Better Teams"]))
        XCTAssertTrue(TeamsFrameConfig.fullFrame(args: ["Better Teams", "--teams-frame-full"]))
    }

    // MARK: - Keep-alive / destroy seams

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "dev.ostmac.teams-frame-tests")!
    }

    override func tearDown() {
        let defaults = freshDefaults()
        defaults.removeObject(forKey: TeamsFrameConfig.keepAliveMinutesKey)
        defaults.removeObject(forKey: TeamsFrameRegistry.appsKey)
        defaults.removeObject(forKey: TeamsFrameRegistry.selectedAppKey)
        defaults.removeObject(forKey: TeamsFrameLibrary.cacheKey)
        super.tearDown()
    }

    func testKeepAliveDefaultIs15() {
        let defaults = freshDefaults()
        defaults.removeObject(forKey: TeamsFrameConfig.keepAliveMinutesKey)
        XCTAssertEqual(TeamsFrameConfig.keepAliveMinutes(defaults: defaults), 15)
    }

    func testKeepAliveZeroMeansInstant() {
        let defaults = freshDefaults()
        defaults.set(0, forKey: TeamsFrameConfig.keepAliveMinutesKey)
        XCTAssertEqual(TeamsFrameConfig.keepAliveMinutes(defaults: defaults), 0)
        let store = TeamsFrameStore(defaults: defaults)
        store.activate()
        XCTAssertTrue(store.alive)
        XCTAssertNotNil(store.dataStore)
        store.deactivate()
        XCTAssertFalse(store.alive)
        XCTAssertNil(store.dataStore)
        XCTAssertFalse(store.keepAliveArmed)
    }

    func testDeactivateArmsTimerWhenPositive() {
        let defaults = freshDefaults()
        defaults.set(15, forKey: TeamsFrameConfig.keepAliveMinutesKey)
        let store = TeamsFrameStore(defaults: defaults)
        store.activate()
        store.deactivate()
        XCTAssertTrue(store.alive)
        XCTAssertTrue(store.keepAliveArmed)
        XCTAssertNotNil(store.dataStore)
        store.destroy() // cleanup: disarm the timer
    }

    func testActivateCancelsArmedTimer() {
        let defaults = freshDefaults()
        defaults.set(15, forKey: TeamsFrameConfig.keepAliveMinutesKey)
        let store = TeamsFrameStore(defaults: defaults)
        store.activate()
        store.deactivate()
        XCTAssertTrue(store.keepAliveArmed)
        store.activate()
        XCTAssertFalse(store.keepAliveArmed)
        XCTAssertTrue(store.alive)
        store.destroy()
    }

    func testDestroyOrphansPoolAndStore() {
        let store = TeamsFrameStore(defaults: freshDefaults())
        store.activate()
        XCTAssertNotNil(store.dataStore)
        store.destroy()
        XCTAssertNil(store.dataStore)
        XCTAssertFalse(store.alive)
    }

    func testReactivateAfterDestroyRebuilds() {
        let store = TeamsFrameStore(defaults: freshDefaults())
        store.activate()
        store.destroy()
        XCTAssertFalse(store.alive)
        store.activate()
        XCTAssertTrue(store.alive)
        XCTAssertNotNil(store.dataStore)
        store.destroy()
    }

    func testUserAgentSuffixCarriesSafariTokens() {
        // Regression: stock WKWebView UA lands on /v2/unsupported-browser.
        XCTAssertTrue(TeamsFrameConfig.userAgentSuffix.contains("Safari/"))
        XCTAssertTrue(TeamsFrameConfig.userAgentSuffix.contains("Version/"))
    }

    func testCropV0HasPositiveInsets() {
        XCTAssertGreaterThan(TeamsFrameCrop.v0.left, 0)
        XCTAssertGreaterThan(TeamsFrameCrop.v0.top, 0)
        XCTAssertEqual(TeamsFrameCrop.none, TeamsFrameCrop(left: 0, top: 0))
    }

    // MARK: - Registry

    func testRegistrySeedsPlaceholderWhenMissing() {
        let defaults = freshDefaults()
        defaults.removeObject(forKey: TeamsFrameRegistry.appsKey)
        let apps = TeamsFrameRegistry.loadApps(defaults: defaults)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].id, "sample-app")
        // No real org URLs in the seed — placeholder entity only.
        XCTAssertTrue(apps[0].entityURL.contains("APP_ENTITY_ID"))
        XCTAssertFalse(apps[0].entityURL.contains("contoso"))
    }

    func testRegistryRoundTrip() {
        let defaults = freshDefaults()
        let apps = [
            TeamsFrameApp(
                id: "a", label: "A",
                entityURL: "https://teams.microsoft.com/l/entity/a",
                crop: TeamsFrameCrop(left: 10, top: 20)),
            TeamsFrameApp(
                id: "b", label: "B",
                entityURL: "https://teams.microsoft.com/l/entity/b"),
        ]
        TeamsFrameRegistry.saveApps(apps, defaults: defaults)
        XCTAssertEqual(TeamsFrameRegistry.loadApps(defaults: defaults), apps)
    }

    func testRegistryCorruptFallsBackToSeed() {
        let defaults = freshDefaults()
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: TeamsFrameRegistry.appsKey)
        XCTAssertEqual(
            TeamsFrameRegistry.loadApps(defaults: defaults),
            TeamsFrameRegistry.seedApps)
    }

    func testRegistryEmptyFallsBackToSeed() {
        let defaults = freshDefaults()
        TeamsFrameRegistry.saveApps([], defaults: defaults)
        XCTAssertEqual(
            TeamsFrameRegistry.loadApps(defaults: defaults),
            TeamsFrameRegistry.seedApps)
    }

    func testCropDefaultsToV0WhenNil() {
        // Missing crop key decodes to nil → v0 default.
        let json = #"{"id":"a","label":"A","entityURL":"https://x"}"#
        let app = try! JSONDecoder().decode(
            TeamsFrameApp.self, from: Data(json.utf8))
        XCTAssertNil(app.crop)
        XCTAssertEqual(app.effectiveCrop, .v0)
        XCTAssertEqual(
            TeamsFrameApp(id: "a", label: "A", entityURL: "https://x").effectiveCrop,
            .v0)
    }

    func testSelectAppPersistsAndClearsCustom() {
        let defaults = freshDefaults()
        TeamsFrameRegistry.saveApps(
            [
                TeamsFrameApp(id: "a", label: "A", entityURL: "https://teams.microsoft.com/a"),
                TeamsFrameApp(
                    id: "b", label: "B", entityURL: "https://teams.microsoft.com/b",
                    crop: TeamsFrameCrop(left: 5, top: 6)),
            ],
            defaults: defaults)
        let store = TeamsFrameStore(defaults: defaults)
        store.loadCustomURL("https://teams.microsoft.com/custom")
        XCTAssertEqual(store.currentURLString, "https://teams.microsoft.com/custom")
        XCTAssertEqual(store.currentCrop, .v0)
        store.selectApp(id: "b")
        XCTAssertNil(store.customURLString)
        XCTAssertEqual(store.currentURLString, "https://teams.microsoft.com/b")
        XCTAssertEqual(store.currentCrop, TeamsFrameCrop(left: 5, top: 6))
        XCTAssertEqual(TeamsFrameRegistry.loadSelectedID(defaults: defaults), "b")
        // Fresh store picks up the persisted selection.
        let store2 = TeamsFrameStore(defaults: defaults)
        XCTAssertEqual(store2.selectedApp?.id, "b")
        store.destroy()
        store2.destroy()
    }

    func testLoadCustomURLRejectsGarbage() {
        let store = TeamsFrameStore(defaults: freshDefaults())
        store.loadCustomURL("   ")
        XCTAssertNil(store.customURLString)
        XCTAssertEqual(store.currentURLString, store.selectedApp?.entityURL)
        store.destroy()
    }

    // MARK: - Escape matrix

    func testEscapeDecisionMatrix() {
        let teams = URL(string: "https://teams.microsoft.com/l/entity/x")!
        let evil = URL(string: "https://evil.com/teams.microsoft.com")!
        XCTAssertEqual(TeamsFrameConfig.escapeDecision(url: teams, isMainFrame: true), .allow)
        XCTAssertEqual(TeamsFrameConfig.escapeDecision(url: teams, isMainFrame: false), .allow)
        XCTAssertEqual(TeamsFrameConfig.escapeDecision(url: evil, isMainFrame: true), .yank)
        XCTAssertEqual(
            TeamsFrameConfig.escapeDecision(url: evil, isMainFrame: false), .allowLogged)
        XCTAssertEqual(
            TeamsFrameConfig.escapeDecision(url: URL(string: "about:blank")!, isMainFrame: true),
            .allow)
    }

    // MARK: - Popup / download seams

    func testPopupInterceptDecision() {
        XCTAssertTrue(TeamsFrameConfig.interceptsPopup(targetFrameIsNil: true))
        XCTAssertFalse(TeamsFrameConfig.interceptsPopup(targetFrameIsNil: false))
    }

    func testStorePopupOpenClose() {
        let store = TeamsFrameStore(defaults: freshDefaults())
        XCTAssertNil(store.popup)
        store.presentPopup(TeamsFramePopup(url: URL(string: "https://login.microsoftonline.com/")))
        XCTAssertNotNil(store.popup)
        XCTAssertEqual(store.popup?.url?.host, "login.microsoftonline.com")
        store.closePopup()
        XCTAssertNil(store.popup)
        store.destroy()
    }

    func testDownloadsDefaultDirectoryIsDownloads() {
        let dir = TeamsFrameDownloads.defaultDirectory()
        XCTAssertEqual(dir.lastPathComponent, "Downloads")
        XCTAssertTrue(dir.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    func testSanitizedFilename() {
        XCTAssertEqual(TeamsFrameDownloads.sanitizedFilename("report.pdf"), "report.pdf")
        XCTAssertEqual(TeamsFrameDownloads.sanitizedFilename("../../etc/passwd"), ".._.._etc_passwd")
        XCTAssertEqual(TeamsFrameDownloads.sanitizedFilename("   "), "download")
    }

    // MARK: - Lifecycle (lazy / suspend / footprint)

    func testLazyNoWebObjectsUntilActivate() {
        let store = TeamsFrameStore(defaults: freshDefaults())
        XCTAssertNil(store.dataStore)
        XCTAssertNil(store.activeWebView)
        XCTAssertFalse(store.suspended)
        store.activate()
        XCTAssertNotNil(store.dataStore)
        store.destroy()
    }

    func testSuspendTransitions() {
        let defaults = freshDefaults()
        defaults.set(15, forKey: TeamsFrameConfig.keepAliveMinutesKey)
        let store = TeamsFrameStore(defaults: defaults)
        store.activate()
        XCTAssertFalse(store.suspended)
        store.deactivate()
        XCTAssertTrue(store.suspended)
        XCTAssertTrue(store.keepAliveArmed)
        store.activate()
        XCTAssertFalse(store.suspended)
        XCTAssertFalse(store.keepAliveArmed)
        store.destroy()
        XCTAssertFalse(store.suspended)
    }

    func testFootprintBestEffort() {
        // Never crashes; nil (unknown) or a positive resident size.
        let mb = TeamsFrameFootprint.residentMB()
        XCTAssertTrue(mb == nil || (mb ?? 0) > 0)
    }

    func testActivateAppliesLaunchURLOnce() {
        let defaults = freshDefaults()
        let deep = "https://teams.microsoft.com/l/entity/abc123?label=App"
        let store = TeamsFrameStore(defaults: defaults)
        store.activate(launchURL: deep)
        XCTAssertEqual(store.customURLString, deep)
        XCTAssertEqual(store.currentURLString, deep)
        // User picks an app; a later appear must not clobber the pick.
        store.selectApp(id: store.apps.first?.id)
        store.activate(launchURL: deep)
        XCTAssertNil(store.customURLString)
        XCTAssertEqual(store.currentURLString, store.selectedApp?.entityURL)
        store.destroy()
    }

    func testPlaceholderURLDetection() {
        XCTAssertTrue(TeamsFrameConfig.isPlaceholderURL(
            TeamsFrameRegistry.seedApps[0].entityURL))
        XCTAssertTrue(TeamsFrameConfig.isPlaceholderURL("https://x/<THING>"))
        XCTAssertFalse(TeamsFrameConfig.isPlaceholderURL("https://teams.microsoft.com"))
        XCTAssertFalse(TeamsFrameConfig.isPlaceholderURL(
            "https://teams.microsoft.com/l/entity/abc123?label=App"))
    }

    // MARK: - Calibrate flag

    func testCalibrateFlag() {
        XCTAssertFalse(TeamsFrameConfig.calibrate(args: ["Better Teams"]))
        XCTAssertTrue(TeamsFrameConfig.calibrate(args: ["Better Teams", "--teams-frame-calibrate"]))
    }

    // MARK: - Measure flag + probe parser

    func testMeasureFlag() {
        XCTAssertFalse(TeamsFrameConfig.measure(args: ["Better Teams"]))
        XCTAssertTrue(TeamsFrameConfig.measure(args: ["Better Teams", "--teams-frame-measure"]))
    }

    func testLibraryOpenFlag() {
        XCTAssertFalse(TeamsFrameConfig.libraryOpen(args: ["Better Teams"]))
        XCTAssertTrue(TeamsFrameConfig.libraryOpen(args: ["Better Teams", "--teams-frame-library"]))
    }

    func testKillAfterFlag() {
        XCTAssertNil(TeamsFrameConfig.killAfter(args: ["Better Teams"]))
        XCTAssertEqual(
            TeamsFrameConfig.killAfter(args: ["Better Teams", "--teams-frame-kill-after", "30"]),
            30)
        XCTAssertEqual(
            TeamsFrameConfig.killAfter(args: ["Better Teams", "--teams-frame-kill-after", "0"]),
            0)
        XCTAssertNil(TeamsFrameConfig.killAfter(args: ["Better Teams", "--teams-frame-kill-after"]))
        XCTAssertNil(
            TeamsFrameConfig.killAfter(args: ["Better Teams", "--teams-frame-kill-after", "soon"]))
        XCTAssertNil(
            TeamsFrameConfig.killAfter(args: ["Better Teams", "--teams-frame-kill-after", "-5"]))
    }

    func testMeasureParsesValidResult() {
        let crop = TeamsFrameMeasure.parseResult(
            #"{"left":68,"top":48,"source":"app-bar+header"}"#)
        XCTAssertEqual(crop, TeamsFrameCrop(left: 68, top: 48))
    }

    func testMeasureRejectsNoMatchAndGarbage() {
        XCTAssertNil(TeamsFrameMeasure.parseResult(
            #"{"left":-1,"top":-1,"source":"error"}"#))
        XCTAssertNil(TeamsFrameMeasure.parseResult(
            #"{"left":0,"top":48,"source":"x"}"#))
        XCTAssertNil(TeamsFrameMeasure.parseResult("not json"))
        XCTAssertNil(TeamsFrameMeasure.parseResult(#"{"left":68}"#))
    }

    func testMeasureRejectsOversizeChrome() {
        // A 500px "rail" is page content, not chrome.
        XCTAssertNil(TeamsFrameMeasure.parseResult(
            #"{"left":500,"top":48,"source":"x"}"#))
        XCTAssertNil(TeamsFrameMeasure.parseResult(
            #"{"left":68,"top":401,"source":"x"}"#))
        XCTAssertNotNil(TeamsFrameMeasure.parseResult(
            #"{"left":400,"top":400,"source":"x"}"#))
    }

    func testMeasureScriptIsSelfContainedIIFE() {
        // Ships verbatim into evaluateJavaScript: JSON out, never throws.
        XCTAssertTrue(TeamsFrameMeasure.script.hasPrefix("(function()"))
        XCTAssertTrue(TeamsFrameMeasure.script.contains("JSON.stringify"))
        XCTAssertTrue(TeamsFrameMeasure.script.contains("catch"))
    }

    // MARK: - SSO bootstrap filter + gate

    func testSSOFilterMatchesMicrosoftHosts() {
        for domain in [
            ".login.microsoftonline.com",
            "login.microsoftonline.com",
            ".teams.microsoft.com",
            "ESTSAUTH.light.microsoft.com",
            ".live.com",
            "outlook.office.com",
            "contoso.sharepoint.com",
        ] {
            XCTAssertTrue(TeamsFrameSSO.shouldCopyCookie(domain: domain), domain)
        }
    }

    func testSSOFilterRejectsNonMicrosoftAndSpoofs() {
        for domain in [
            "",
            ".",
            "evil.com",
            "evil-microsoft.com",
            "microsoft.com.evil.com",
            "teams.microsoft.com.attacker.io",
        ] {
            XCTAssertFalse(TeamsFrameSSO.shouldCopyCookie(domain: domain), domain)
        }
    }

    func testSSOFilterIsCaseInsensitive() {
        XCTAssertTrue(TeamsFrameSSO.shouldCopyCookie(domain: ".LOGIN.MICROSOFTONLINE.COM"))
    }

    func testSSOReadyFlipsAfterActivate() {
        let store = TeamsFrameStore(defaults: freshDefaults())
        XCTAssertFalse(store.ssoReady)
        store.activate()
        let exp = expectation(description: "ssoReady")
        Task { @MainActor in
            for _ in 0..<200 where !store.ssoReady {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        XCTAssertTrue(store.ssoReady)
        store.destroy()
        XCTAssertFalse(store.ssoReady)
        XCTAssertEqual(store.ssoCookieCount, 0)
    }

    func testBootstrapCopiesMatchingCookiesOnly() async throws {
        // Functional: seed the shared default jar, bootstrap a throwaway
        // store, assert the Microsoft cookie lands and evil.com does not.
        let jar = WKWebsiteDataStore.default().httpCookieStore
        func set(domain: String, name: String) async {
            let cookie = HTTPCookie(properties: [
                .domain: domain, .path: "/", .name: name, .value: "1",
            ])!
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                jar.setCookie(cookie) { cont.resume() }
            }
        }
        func all(in store: WKWebsiteDataStore) async -> [HTTPCookie] {
            await withCheckedContinuation { cont in
                store.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
            }
        }
        await set(domain: "login.microsoftonline.com", name: "bt-test-ms")
        await set(domain: "evil.com", name: "bt-test-evil")
        let target = WKWebsiteDataStore.nonPersistent()
        let n = await TeamsFrameSSO.bootstrap(into: target)
        XCTAssertGreaterThanOrEqual(n, 1)
        let got = await all(in: target)
        XCTAssertTrue(got.contains { $0.name == "bt-test-ms" })
        XCTAssertFalse(got.contains { $0.name == "bt-test-evil" })
        // Cleanup: remove the seeds from the shared jar.
        for cookie in await all(in: .default())
            where cookie.name == "bt-test-ms" || cookie.name == "bt-test-evil"
        {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                jar.delete(cookie) { cont.resume() }
            }
        }
    }

    func testBootstrapWithTimeoutCompletesFast() async throws {
        // Healthy store: no timeout, count passes through.
        let result = await TeamsFrameSSO.bootstrapWithTimeout(
            into: .nonPersistent(), seconds: 5)
        XCTAssertFalse(result.timedOut)
        XCTAssertGreaterThanOrEqual(result.copied, 0)
    }

    // MARK: - Registry mutations

    func testAddAppReplacesAndSelects() {
        let defaults = freshDefaults()
        let store = TeamsFrameStore(defaults: defaults)
        let app = TeamsFrameApp(
            id: "a", label: "A", entityURL: "https://teams.microsoft.com/a")
        store.addApp(app)
        store.addApp(TeamsFrameApp(
            id: "a", label: "A2", entityURL: "https://teams.microsoft.com/a2"))
        XCTAssertEqual(store.apps.filter { $0.id == "a" }.count, 1)
        XCTAssertEqual(store.selectedApp?.label, "A2")
        XCTAssertEqual(
            TeamsFrameRegistry.loadApps(defaults: defaults).filter { $0.id == "a" }.count, 1)
        store.destroy()
    }

    func testRemoveAppReseedsWhenLast() {
        let defaults = freshDefaults()
        let store = TeamsFrameStore(defaults: defaults)
        let id = store.apps[0].id
        store.removeApp(id: id)
        XCTAssertEqual(store.apps, TeamsFrameRegistry.seedApps)
        XCTAssertEqual(
            TeamsFrameRegistry.loadApps(defaults: defaults),
            TeamsFrameRegistry.seedApps)
        store.destroy()
    }

    func testRemoveAppKeepsOthersAndClearsSelection() {
        let defaults = freshDefaults()
        TeamsFrameRegistry.saveApps(
            [
                TeamsFrameApp(id: "a", label: "A", entityURL: "https://x/a"),
                TeamsFrameApp(id: "b", label: "B", entityURL: "https://x/b"),
            ],
            defaults: defaults)
        let store = TeamsFrameStore(defaults: defaults)
        store.selectApp(id: "b")
        store.removeApp(id: "b")
        XCTAssertEqual(store.apps.map(\.id), ["a"])
        XCTAssertNil(TeamsFrameRegistry.loadSelectedID(defaults: defaults))
        store.destroy()
    }

    func testUpdateCropSetClearAndUnknown() {
        let defaults = freshDefaults()
        TeamsFrameRegistry.saveApps(
            [TeamsFrameApp(id: "a", label: "A", entityURL: "https://x/a")],
            defaults: defaults)
        let store = TeamsFrameStore(defaults: defaults)
        store.updateCrop(id: "a", crop: TeamsFrameCrop(left: 10, top: 20))
        XCTAssertEqual(store.apps[0].crop, TeamsFrameCrop(left: 10, top: 20))
        XCTAssertEqual(
            TeamsFrameRegistry.loadApps(defaults: defaults)[0].crop,
            TeamsFrameCrop(left: 10, top: 20))
        store.updateCrop(id: "a", crop: nil)
        XCTAssertNil(store.apps[0].crop)
        store.updateCrop(id: "nope", crop: TeamsFrameCrop(left: 1, top: 1))
        XCTAssertEqual(store.apps.count, 1)
        store.destroy()
    }

    // MARK: - Library

    private let tabsAllFixture = """
    === Falcon IT | General | 19:aaa111@thread.tacv2
      Notes                          19038e38-fake-42c5-a437-fakefake0001
        https://onenote.example.com/
      Order Tracker                  6ece32a4-fake-41d8-ba3f-fakefake0002
        https://teams.microsoft.com/l/entity/1c256a65-fake-4b5c-9ccf-fakefake0003/x?label=Order+Tracker
    === Falcon IT | Inventory | 19:bbb222@thread.tacv2
      (no tabs found)
    === Falcon Ops | General | 19:ccc333@thread.skype
      Wiki                           6482e894-fake-42ee-b5bd-fakefake0004
        https://teams.microsoft.com/l/channel/19abc/tab%3a%3a6482e894?label=Wiki
      Bare Tab With No URL           deadbeef-fake-0000-0000-fakefake0005
    === Broken | header
      Orphan                         11111111-fake-0000-0000-fakefake0006
        https://teams.microsoft.com/l/entity/orphan
    """

    func testParseTabsAllSectionsAndRows() {
        let entries = TeamsFrameLibrary.parseTabsAll(tabsAllFixture)
        // Notes + Order Tracker + Wiki. Bare/orphan/malformed skipped.
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].team, "Falcon IT")
        XCTAssertEqual(entries[0].channel, "General")
        XCTAssertEqual(entries[0].label, "Notes")
        XCTAssertEqual(entries[0].url, "https://onenote.example.com/")
        XCTAssertEqual(entries[1].label, "Order Tracker")
        XCTAssertEqual(entries[2].team, "Falcon Ops")
        XCTAssertEqual(entries[2].label, "Wiki")
        // Stable composite ids.
        XCTAssertTrue(entries[0].id.hasPrefix("Falcon IT|General|"))
        XCTAssertNotEqual(entries[0].id, entries[1].id)
    }

    func testParseTabsAllEmptyAndGarbage() {
        XCTAssertEqual(TeamsFrameLibrary.parseTabsAll(""), [])
        XCTAssertEqual(TeamsFrameLibrary.parseTabsAll("hello\nworld\n"), [])
        XCTAssertEqual(
            TeamsFrameLibrary.parseTabsAll("=== Broken | header\n  X y\n"), [])
    }

    func testEntryFrameLoadable() {
        XCTAssertTrue(TeamsFrameLibraryEntry(
            id: "1", team: "T", channel: "C", label: "Files",
            url: "https://teams.microsoft.com/l/entity/abc").frameLoadable)
        XCTAssertFalse(TeamsFrameLibraryEntry(
            id: "2", team: "T", channel: "C", label: "Notes",
            url: "https://www.onenote.com/").frameLoadable)
        XCTAssertFalse(TeamsFrameLibraryEntry(
            id: "3", team: "T", channel: "C", label: "Bad",
            url: "not a url at all").frameLoadable)
    }

    func testAppFromEntry() {
        let app = TeamsFrameLibrary.appFromEntry(TeamsFrameLibraryEntry(
            id: "Falcon IT|General|tab-1", team: "Falcon IT",
            channel: "General", label: "Order Tracker",
            url: "https://teams.microsoft.com/l/entity/x"))
        XCTAssertEqual(app.label, "Order Tracker (General)")
        XCTAssertEqual(app.entityURL, "https://teams.microsoft.com/l/entity/x")
        XCTAssertTrue(app.id.hasPrefix("lib-"))
        XCTAssertFalse(app.id.contains("|"))
        XCTAssertFalse(app.id.contains(" "))
    }

    func testAppFromURLLabelAndFallbacks() {
        let named = TeamsFrameLibrary.appFromURL(
            "https://teams.microsoft.com/l/entity/abc?label=My+App")!
        XCTAssertEqual(named.label, "My App")
        XCTAssertTrue(named.id.hasPrefix("link-"))
        let host = TeamsFrameLibrary.appFromURL("https://teams.microsoft.com/")!
        XCTAssertEqual(host.label, "teams.microsoft.com")
        XCTAssertNil(TeamsFrameLibrary.appFromURL("   "))
        XCTAssertNil(TeamsFrameLibrary.appFromURL("not a url"))
    }

    func testCliCandidatesOrder() {
        let cands = TeamsFrameLibrary.cliCandidates(
            bundleResourcePath: "/A/B.app/Contents/Resources",
            devBuildPath: "/repo/rust/ost/target/release/teams-cli")
        XCTAssertEqual(cands, [
            "/A/B.app/Contents/Resources/teams-cli",
            "/repo/rust/ost/target/release/teams-cli",
        ])
        let bare = TeamsFrameLibrary.cliCandidates(
            bundleResourcePath: nil, devBuildPath: nil)
        XCTAssertEqual(bare, [])
        // Relative paths never become candidates (no cwd/PATH resolution).
        let relative = TeamsFrameLibrary.cliCandidates(
            bundleResourcePath: "Resources", devBuildPath: "teams-cli")
        XCTAssertEqual(relative, [])
        XCTAssertTrue(TeamsFrameLibrary.devBuildCLIPath.hasPrefix("/"))
        XCTAssertTrue(
            TeamsFrameLibrary.devBuildCLIPath.hasSuffix(
                "/rust/ost/target/release/teams-cli"))
    }

    func testFirstExecutableSkipsMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent("teams-cli")
        try "#!/bin/sh\necho hi\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: exe.path)
        XCTAssertEqual(
            TeamsFrameLibrary.firstExecutable(["/nonexistent/x", exe.path]),
            exe.path)
        XCTAssertNil(TeamsFrameLibrary.firstExecutable(["/nonexistent/x"]))
        try? FileManager.default.removeItem(at: dir)
    }

    /// G1: a bare name is never looked up on PATH, even when PATH holds
    /// an executable of that name (`sh` is on every PATH).
    func testFirstExecutableNeverSearchesPath() {
        XCTAssertNil(TeamsFrameLibrary.firstExecutable(["sh", "teams-cli"]))
    }

    func testLibraryCacheRoundTrip() {
        let defaults = freshDefaults()
        XCTAssertEqual(TeamsFrameLibrary.loadCache(defaults: defaults), [])
        let entries = TeamsFrameLibrary.parseTabsAll(tabsAllFixture)
        TeamsFrameLibrary.saveCache(entries, defaults: defaults)
        XCTAssertEqual(TeamsFrameLibrary.loadCache(defaults: defaults), entries)
        defaults.set(Data([0x00]), forKey: TeamsFrameLibrary.cacheKey)
        XCTAssertEqual(TeamsFrameLibrary.loadCache(defaults: defaults), [])
    }
}
