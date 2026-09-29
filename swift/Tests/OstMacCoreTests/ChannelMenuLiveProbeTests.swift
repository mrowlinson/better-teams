// ChannelMenuLiveProbeTests.swift — opt-in live proof for CHANMENU
// (CHANMENU_LIVE=1). Read-only Graph GETs against the joined teams:
// how many channel lists come back, whether General is listed first,
// whether the 09-25 test channel ("verify-" prefix) is gone, and whether
// the team's memberSettings / primaryChannel reads work. Prints counts
// and status codes only — never tokens, names, ids or URLs. Never
// refreshes a token (a stale slot skips the probe).
import Foundation
import XCTest
@testable import OstMacCore

final class ChannelMenuLiveProbeTests: XCTestCase {
    func testLiveChannelReads() throws {
        guard ProcessInfo.processInfo.environment["CHANMENU_LIVE"] == "1" else {
            throw XCTSkip("set CHANMENU_LIVE=1 to run the read-only channel probe")
        }
        let ctx = try CoreReads.production()
        let slots = ctx.store.load(profile: TomlConfig.normalize(CoreLocal.activeProfileID()))
        guard let g = slots.graphToken, !g.isExpired(now: ctx.now()) else {
            print("CHANMENU BLOCKED stored Graph token missing or stale; not refreshing from a probe")
            throw XCTSkip("stored Graph token missing or stale")
        }
        func get(_ path: String) -> (Int, [String: Any]?) {
            guard let url = URL(string: CoreReads.graphBase + path) else { return (-1, nil) }
            guard let r = try? ctx.http.get(url: url, headers: ["Authorization": "Bearer \(g.token)",
                                                               "Accept": "application/json"]) else { return (-2, nil) }
            return (r.status, (try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any])
        }
        let (code, joined) = get("/me/joinedTeams?$select=id")
        print("CHANMENU joinedTeams status=\(code)")
        let ids = ((joined?["value"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        var listed = 0, generalFirst = 0, testChannels = 0, settingsOK = 0, deleteFlag = 0, editFlag = 0, primaryOK = 0
        for id in ids {
            let (cs, ch) = get("/teams/\(id)/channels")
            if cs == 200, let rows = ch?["value"] as? [[String: Any]], !rows.isEmpty {
                listed += 1
                testChannels += rows.filter { (($0["displayName"] as? String) ?? "").hasPrefix("verify-") }.count
                let (ps, p) = get("/teams/\(id)/primaryChannel")
                if ps == 200, let pid = p?["id"] as? String {
                    primaryOK += 1
                    if rows.first?["id"] as? String == pid { generalFirst += 1 }
                }
            }
            let (ts, team) = get("/teams/\(id)")
            if ts == 200, let ms = team?["memberSettings"] as? [String: Any] {
                settingsOK += 1
                if ms["allowDeleteChannels"] is Bool { deleteFlag += 1 }
                if ms["allowCreateUpdateChannels"] is Bool { editFlag += 1 }
            }
        }
        print("CHANMENU teams=\(ids.count) channelListsOK=\(listed) primaryChannelOK=\(primaryOK) "
              + "generalListedFirst=\(generalFirst) verifyChannelsFound=\(testChannels) "
              + "memberSettingsOK=\(settingsOK) allowDeleteReadable=\(deleteFlag) allowEditReadable=\(editFlag)")
    }
}
