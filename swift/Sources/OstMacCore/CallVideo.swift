// CallVideo.swift — group and meeting video (MEETVIDEO): the core's call
// roster, per-source video queues and source subscriptions, the pure tile
// / subscription plan, and the model the call stage observes.
//
// Live: a 1 s off-main poll reads the roster (`ostmac_call_roster`) and
// the video sources that delivered frames (`ostmac_video_sources`); the
// plan picks which camera sources to request (pinned, then the dominant
// speaker, then camera-on people in roster order, capped) and keeps each
// source in its slot across changes; one `LiveVideoModel` per tile
// decodes that source's queue. Demo seeds a fixed roster and never
// touches the core. Diagnostics go to the unified log (category
// `call-video`), which Settings ▸ Advanced ▸ Open Logs Folder exports.
import COstMac
import Combine
import Foundation
import os

// MARK: - core payloads

/// One roster row from the core (`ostmac_call_roster`).
public struct CallRosterParticipant: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let audioMsi: UInt32?
    public let videoMsi: UInt32?
    /// The camera stream is sending (not server-muted).
    public let videoOn: Bool
    public let screenMsi: UInt32?
    public let screenOn: Bool
    public let muted: Bool?
    public let isSelf: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, muted
        case audioMsi = "audio_msi", videoMsi = "video_msi", videoOn = "video_on"
        case screenMsi = "screen_msi", screenOn = "screen_on", isSelf = "is_self"
    }

    public init(id: String, name: String, audioMsi: UInt32? = nil, videoMsi: UInt32? = nil, videoOn: Bool = false,
                screenMsi: UInt32? = nil, screenOn: Bool = false, muted: Bool? = nil, isSelf: Bool = false) {
        self.id = id
        self.name = name
        self.audioMsi = audioMsi
        self.videoMsi = videoMsi
        self.videoOn = videoOn
        self.screenMsi = screenMsi
        self.screenOn = screenOn
        self.muted = muted
        self.isSelf = isSelf
    }
}

/// `ostmac_call_roster`: the active call's roster plus drained diagnostics.
public struct CallRosterPoll: Decodable, Sendable {
    public let ok: Bool
    public let callId: String
    public let updates: Int
    public let participants: [CallRosterParticipant]
    public let dominantMsi: UInt32?
    public let dominantId: String?
    public let log: [String]

    enum CodingKeys: String, CodingKey {
        case ok, updates, participants, log
        case callId = "call_id", dominantMsi = "dominant_msi", dominantId = "dominant_id"
    }
}

/// `ostmac_video_sources`: sources (MSI, or SSRC before the mixer names
/// one) that delivered video this call.
public struct VideoSourcesPoll: Decodable, Sendable {
    public struct Source: Decodable, Sendable, Equatable {
        public let id: UInt32
        public let frames: UInt64
        public let ageMs: UInt64

        enum CodingKeys: String, CodingKey {
            case id, frames
            case ageMs = "age_ms"
        }
    }

    public let ok: Bool
    public let sources: [Source]
}

public struct VideoSubscribeResult: Decodable, Sendable {
    public let ok: Bool
    public let subscribed: [UInt32]?
}

public extension RustCore {
    /// The active call's roster (empty rows when no call is active).
    static func callRoster() throws -> CallRosterPoll {
        try call(ostmac_call_roster(), as: CallRosterPoll.self)
    }

    static func videoSources() throws -> VideoSourcesPoll {
        try call(ostmac_video_sources(), as: VideoSourcesPoll.self)
    }

    /// Requested video sources, slot order (empty = the server picks).
    @discardableResult
    static func videoSubscribe(_ msis: [UInt32]) throws -> VideoSubscribeResult {
        let json = "[" + msis.map(String.init).joined(separator: ",") + "]"
        return try json.withCString { try call(ostmac_video_subscribe($0), as: VideoSubscribeResult.self) }
    }

    /// Drain the newest access unit of one source (same contract as
    /// `videoPollIncoming`).
    internal static func videoPollSource(_ source: UInt32) throws -> IncomingPoll {
        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        var dropped: Int32 = 0
        let rc = ostmac_video_poll_source_bytes(source, &out, &outLen, &dropped)
        guard rc >= 0 else { throw CoreCallError.failed("source poll failed") }
        guard rc == 1, let ptr = out, outLen > 0 else {
            return IncomingPoll(ok: true, au: nil, dropped: Int(dropped))
        }
        let payload = Data(
            bytesNoCopy: ptr, count: outLen,
            deallocator: .custom({ _, _ in ostmac_bytes_free(ptr, outLen) }))
        guard let nals = NalFraming.decode(payload) else {
            throw CoreCallError.failed("source framing corrupt")
        }
        return IncomingPoll(ok: true, au: IncomingAu(nals: nals), dropped: Int(dropped))
    }
}

/// Call threads that are not 1:1: meeting threads and group chats (1:1
/// chat threads end in `@unq.gbl.spaces`). An empty thread is not a group.
public enum CallGroup {
    public static func isGroupThread(_ thread: String) -> Bool {
        guard !thread.isEmpty else { return false }
        return thread.hasPrefix("19:meeting_") || !thread.hasSuffix("@unq.gbl.spaces")
    }
}

/// Unified-log diagnostics for call video (no URLs, no tokens: the core
/// sanitizes its excerpts; host lines carry ids and counts only).
public enum CallVideoLog {
    static let logger = Logger(subsystem: AppIdentity.bundleID, category: "call-video")

    public static func note(_ line: String) {
        logger.notice("\(line, privacy: .public)")
    }
}

// MARK: - plan (pure)

public enum MeetingVideoPlan {
    /// Remote camera tiles with live video at once (core cap: 9).
    public static let maxVideoTiles = 9

    /// One remote tile.
    public struct Tile: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let videoOn: Bool
        public let muted: Bool
        public let speaking: Bool
        /// The source (MSI) whose frames this tile shows.
        public let source: UInt32?
    }

    /// Tile id for a source no roster row claims.
    public static func sourceTileID(_ msi: UInt32) -> String { "msi:\(msi)" }

    /// The core's queue key for someone else's shared screen (the
    /// applicationsharing-video leg; core `SOURCE_SHARE`). Never a camera
    /// source and never subscribed.
    public static let shareSource: UInt32 = 0xFFFF_FFFD

    /// Screen share frames this recent count as a live share.
    public static let shareFreshMs: UInt64 = 10_000

    /// The person presenting: the first other participant whose
    /// applicationsharing-video stream is sending.
    public static func presenter(roster: [CallRosterParticipant]) -> CallRosterParticipant? {
        roster.first { !$0.isSelf && $0.screenOn }
    }

    /// A remote screen share is up: the roster names a presenter; or,
    /// when the roster carries no screen streams at all, share frames
    /// arrived recently (`shareAgeMs`: age of the newest, nil = none).
    public static func shareActive(roster: [CallRosterParticipant], shareAgeMs: UInt64?) -> Bool {
        if presenter(roster: roster) != nil { return true }
        let rosterKnowsScreens = roster.contains { !$0.isSelf && $0.screenMsi != nil }
        guard !rosterKnowsScreens, let age = shareAgeMs else { return false }
        return age < shareFreshMs
    }

    /// Remote tiles: the pinned person first, then roster order (the
    /// signed-in user is the self view, never a remote tile). Sources
    /// that match no roster row (roster missing, or shaped differently)
    /// become their own camera-on tiles, so received video always shows.
    public static func tiles(roster: [CallRosterParticipant], sources: [UInt32], pinned: String?,
                             dominant: String?) -> [Tile] {
        var out: [Tile] = []
        var claimed = Set<UInt32>()
        for p in roster where !p.isSelf {
            if let m = p.videoMsi { claimed.insert(m) }
            if let m = p.audioMsi { claimed.insert(m) }
            out.append(Tile(id: p.id, name: p.name, videoOn: p.videoOn, muted: p.muted ?? false,
                            speaking: p.id == dominant, source: p.videoOn ? p.videoMsi : nil))
        }
        for p in roster where p.isSelf {
            if let m = p.videoMsi { claimed.insert(m) }
            if let m = p.audioMsi { claimed.insert(m) }
        }
        for m in sources where !claimed.contains(m) {
            out.append(Tile(id: sourceTileID(m), name: "Participant", videoOn: true, muted: false,
                            speaking: false, source: m))
        }
        if let pinned, let i = out.firstIndex(where: { $0.id == pinned }), i > 0 {
            out.insert(out.remove(at: i), at: 0)
        }
        return out
    }

    /// Camera sources to request, priority order: pinned, the dominant
    /// speaker, then camera-on people in roster order; capped.
    public static func wanted(roster: [CallRosterParticipant], pinned: String?, dominant: String?,
                              cap: Int = maxVideoTiles) -> [UInt32] {
        var out: [UInt32] = []
        func add(_ p: CallRosterParticipant?) {
            guard let p, !p.isSelf, p.videoOn, let m = p.videoMsi, !out.contains(m), out.count < cap else { return }
            out.append(m)
        }
        add(roster.first { $0.id == pinned })
        add(roster.first { $0.id == dominant })
        for p in roster { add(p) }
        return out
    }

    /// Slot order for `wanted`: sources already requested keep their
    /// slot (no re-request, no decoder restart); new sources fill freed
    /// slots, then append; a remaining hole takes the last slot's source
    /// (one move, never a shift of every slot). `lead` (the pinned
    /// source) takes slot 0, which the core requests at the higher
    /// resolution.
    public static func assignSlots(previous: [UInt32], wanted: [UInt32], lead: UInt32?) -> [UInt32] {
        let want = Set(wanted)
        var slots: [UInt32?] = previous.map { want.contains($0) ? $0 : nil }
        var fresh = wanted.filter { !previous.contains($0) }
        for i in slots.indices where slots[i] == nil && !fresh.isEmpty {
            slots[i] = fresh.removeFirst()
        }
        var i = 0
        while i < slots.count {
            if slots[i] == nil {
                while let last = slots.last, last == nil { slots.removeLast() }
                if i < slots.count { slots[i] = slots.removeLast() }
            }
            i += 1
        }
        var out = slots.compactMap { $0 } + fresh
        if let lead, let j = out.firstIndex(of: lead), j > 0 { out.swapAt(0, j) }
        return out
    }
}

// MARK: - model

/// Group / meeting video state for one call (main actor; the stage
/// observes it). Updates are diffed: rows, sources and decoders are
/// replaced only when they change, and a decoder outlives camera-off so
/// its tile keeps the last frame while it crossfades to the avatar.
@MainActor
public final class MeetingVideoModel: ObservableObject {
    @Published public private(set) var roster: [CallRosterParticipant] = []
    /// Camera sources that delivered frames (MSI / SSRC; never the share).
    @Published public private(set) var sources: [UInt32] = []
    @Published public private(set) var dominantID: String?
    @Published public private(set) var pinnedID: String?
    /// Decoders keyed by tile id (participant MRI, or `msi:<n>`).
    @Published public private(set) var videos: [String: LiveVideoModel] = [:]
    /// Someone else's shared screen while a share is up (live only): the
    /// stage shows it large with the people in a strip.
    @Published public private(set) var shareVideo: LiveVideoModel?
    /// Demo: someone presents (`startDemoPresentation`).
    @Published public private(set) var demoPresenting = false
    /// Age of the newest share frame (nil: none this call).
    private var shareAgeMs: UInt64?
    public let demo: Bool
    public private(set) var running = false
    /// Requested sources in slot order (live only).
    public private(set) var slots: [UInt32] = []
    private let cap: Int
    private var demoTurn = 0
    private var tick = 0
    private nonisolated let loopToken = LiveLoopToken()

    public init(demo: Bool, cap: Int = MeetingVideoPlan.maxVideoTiles) {
        self.demo = demo
        self.cap = cap
    }

    deinit {
        _ = loopToken.next()
    }

    /// The person whose screen `shareVideo` shows (nil until the roster
    /// names one).
    public var presenter: CallRosterParticipant? { MeetingVideoPlan.presenter(roster: roster) }

    /// Remote tiles in display order.
    public var tiles: [MeetingVideoPlan.Tile] {
        MeetingVideoPlan.tiles(roster: roster, sources: sources, pinned: pinnedID, dominant: dominantID)
    }

    /// Starts the roster/source poll (live) or seeds the demo roster.
    public func start() {
        guard !running else { return }
        running = true
        if demo {
            roster = Self.demoRoster
            dominantID = Self.demoRoster.first?.id
            return
        }
        CallVideoLog.note("meeting video: start")
        let gen = loopToken.next()
        let token = loopToken
        Task.detached(priority: .utility) { [weak self] in
            var n = 0
            while token.alive(gen) {
                let roster = try? RustCore.callRoster()
                let sources = try? RustCore.videoSources()
                let media = n % 5 == 0 ? (try? RustCore.callMedia())?.media : nil
                n += 1
                await MainActor.run { [weak self] in
                    guard let self, token.alive(gen) else { return }
                    self.apply(roster: roster, sources: sources, media: media)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Stops polling and every decoder; clears the core subscription.
    public func stop() {
        _ = loopToken.next()
        guard running else { return }
        running = false
        for v in videos.values { v.stop() }
        shareVideo?.stop()
        guard !demo else { return }
        slots = []
        _ = try? RustCore.videoSubscribe([])
        CallVideoLog.note("meeting video: stop")
    }

    /// Pin (spotlight) a tile, or unpin with nil.
    public func pin(_ id: String?) {
        guard pinnedID != id else { return }
        pinnedID = id
        replan()
    }

    /// Demo: the next unmuted person becomes the active speaker.
    public func advanceDemo() {
        guard demo, running else { return }
        let talkers = roster.filter { !$0.isSelf && $0.muted != true }
        guard !talkers.isEmpty else { return }
        demoTurn = (demoTurn + 1) % talkers.count
        dominantID = talkers[demoTurn].id
    }

    /// Demo: the first person presents their screen (the stage shows a
    /// demo slide with the people in the strip), everyone camera-off.
    public func startDemoPresentation() {
        guard demo, running else { return }
        roster = Self.demoRoster.enumerated().map { i, p in
            CallRosterParticipant(id: p.id, name: p.name, audioMsi: p.audioMsi, videoMsi: p.videoMsi,
                                  videoOn: false, screenMsi: i == 0 ? 13 : nil, screenOn: i == 0, muted: p.muted)
        }
        dominantID = roster.first?.id
        demoPresenting = true
    }

    /// One poll's results (live; internal for tests).
    func apply(roster r: CallRosterPoll?, sources s: VideoSourcesPoll?, media: LiveMediaStats?) {
        tick += 1
        if let r {
            for line in r.log { CallVideoLog.note("core: " + line) }
            if r.participants != roster {
                roster = r.participants
                CallVideoLog.note("roster: updates=\(r.updates) " + roster.map(Self.describe).joined(separator: " "))
            }
            if r.dominantId != dominantID {
                dominantID = r.dominantId
                CallVideoLog.note("dominant: msi=\(r.dominantMsi.map(String.init) ?? "-") tile=\(Self.short(r.dominantId))")
            }
        }
        if let s {
            // The share leg's frames are the stage, never a camera tile.
            let ids = s.sources.map(\.id).filter { $0 != MeetingVideoPlan.shareSource }
            if ids != sources {
                sources = ids
                CallVideoLog.note("sources: " + s.sources.map { "\($0.id)/\($0.frames)f" }.joined(separator: " "))
            }
            shareAgeMs = s.sources.first { $0.id == MeetingVideoPlan.shareSource }?.ageMs
        }
        if let m = media {
            CallVideoLog.note("media: video_sent=\(m.video_sent) video_recv=\(m.video_recv) vsr_sent=\(m.vsr_sent ?? -1)"
                + " vsr_recv=\(m.vsr_recv ?? -1) pli_recv=\(m.pli_recv ?? -1) dsh_recv=\(m.dsh_recv ?? -1)"
                + " pli_sent=\(m.pli_sent ?? -1) share_recv=\(m.share_recv ?? -1)"
                + " recv_dropped=\(m.recv_dropped) ice_video=\(m.ice_video) ice_share=\(m.ice_share ?? "-")")
        }
        if let p = pinnedID, !tiles.contains(where: { $0.id == p }) { pinnedID = nil }
        syncShare()
        replan()
    }

    /// Requests the planned sources (on change only) and matches the
    /// decoders to the tiles.
    private func replan() {
        guard !demo, running else { return }
        let wanted = MeetingVideoPlan.wanted(roster: roster, pinned: pinnedID, dominant: dominantID, cap: cap)
        let lead = pinnedID.flatMap { id in roster.first { $0.id == id && $0.videoOn }?.videoMsi }
        let next = MeetingVideoPlan.assignSlots(previous: slots, wanted: wanted, lead: lead)
        if next != slots {
            slots = next
            // Cheap (a core mutex + JSON): the latest request wins in order.
            _ = try? RustCore.videoSubscribe(next)
            CallVideoLog.note("subscribe: [" + next.map(String.init).joined(separator: ",") + "]")
        }
        syncDecoders()
    }

    /// Starts the share decoder when a remote share comes up and stops it
    /// when the share ends (the stage returns to the grid).
    private func syncShare() {
        guard !demo, running else { return }
        let active = MeetingVideoPlan.shareActive(roster: roster, shareAgeMs: shareAgeMs)
        if active, let v = shareVideo {
            v.start() // idempotent; resumes after a model restart
        } else if active {
            let v = LiveVideoModel(source: MeetingVideoPlan.shareSource)
            v.start()
            shareVideo = v
            CallVideoLog.note("share: start presenter=\(Self.short(presenter?.id))")
        } else if let v = shareVideo {
            v.stop()
            shareVideo = nil
            CallVideoLog.note("share: end")
        }
    }

    private func syncDecoders() {
        let flowing = Set(slots).union(sources)
        let current = tiles
        var next = videos
        var changed = false
        for t in current {
            guard t.videoOn, let src = t.source, flowing.contains(src) else { continue }
            if let v = next[t.id], v.source == src {
                v.start() // idempotent; resumes after camera-off
                continue
            }
            next[t.id]?.stop()
            let v = LiveVideoModel(source: src)
            v.start()
            next[t.id] = v
            changed = true
        }
        let ids = Set(current.map(\.id))
        for (id, v) in next {
            if !ids.contains(id) {
                v.stop()
                next[id] = nil
                changed = true
            } else if current.first(where: { $0.id == id })?.videoOn == false {
                v.stop() // keeps its last frame for the crossfade
            }
        }
        if changed { videos = next }
    }

    private static func short(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "-" }
        return "…" + id.suffix(6)
    }

    private static func describe(_ p: CallRosterParticipant) -> String {
        "\(short(p.id))\(p.isSelf ? "(self)" : "")[a=\(p.audioMsi.map(String.init) ?? "-")"
            + " v=\(p.videoMsi.map(String.init) ?? "-")\(p.videoOn ? "+" : "")"
            + " s=\(p.screenMsi.map(String.init) ?? "-")\(p.screenOn ? "+" : "")"
            + " m=\(p.muted.map { $0 ? "1" : "0" } ?? "-")]"
    }

    /// Demo meeting: fixed people, some cameras on (never the network).
    public static let demoRoster: [CallRosterParticipant] = [
        CallRosterParticipant(id: "8:orgid:ava", name: "Ava Lindqvist", audioMsi: 11, videoMsi: 12, videoOn: true,
                              muted: false),
        CallRosterParticipant(id: "8:orgid:hannah", name: "Hannah Clarke", audioMsi: 21, videoMsi: 22, videoOn: true,
                              muted: true),
        CallRosterParticipant(id: "8:orgid:tom", name: "Tom Becker", audioMsi: 31, videoMsi: 32, videoOn: false,
                              muted: false),
        CallRosterParticipant(id: "8:orgid:megan", name: "Megan Harper", audioMsi: 41, videoMsi: 42, videoOn: true,
                              muted: false),
        CallRosterParticipant(id: "8:orgid:oliver", name: "Oliver Grant", audioMsi: 51, videoMsi: 52,
                              videoOn: false, muted: true),
    ]
}
