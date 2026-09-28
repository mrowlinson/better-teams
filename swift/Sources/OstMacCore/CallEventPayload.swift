// CallEventPayload.swift — core-a: caller id from Teams chat call
// events. Calls post a `messagetype: Event/Call` message into the 1:1
// (or group) thread whose content is a Skype partlist:
//   <partlist type="missed" alt=""><part identity="8:orgid:<guid>">
//     <name>Jane Doe</name></part></partlist>
// (`type` is started/ended/missed). Pure; no FFI, no network.
import Foundation

public enum CallEventPayload {
    public struct Part: Equatable, Sendable {
        public let identity: String
        public let name: String
    }

    /// True for chat call events (`Event/Call`, any casing).
    public static func isCallEvent(_ messageType: String?) -> Bool {
        (messageType ?? "").lowercased().hasPrefix("event/call")
    }

    /// `type` attribute of the first `<partlist>` (lowercased), or nil.
    public static func partlistType(_ raw: String) -> String? {
        guard let open = raw.range(of: "<partlist", options: .caseInsensitive),
              let close = raw[open.upperBound...].firstIndex(of: ">")
        else { return nil }
        return attribute("type", in: String(raw[open.upperBound..<close]))?.lowercased()
    }

    /// Every `<part identity=…>` with its `<name>` (blank names → "").
    public static func parts(_ raw: String) -> [Part] {
        var out: [Part] = []
        var cursor = raw.startIndex
        while let open = raw.range(of: "<part ", options: .caseInsensitive, range: cursor..<raw.endIndex) {
            guard let tagEnd = raw[open.upperBound...].firstIndex(of: ">") else { break }
            let tag = String(raw[open.upperBound..<tagEnd])
            let bodyEnd = raw.range(of: "</part>", options: .caseInsensitive, range: tagEnd..<raw.endIndex)
            let body = bodyEnd.map { String(raw[raw.index(after: tagEnd)..<$0.lowerBound]) } ?? ""
            cursor = bodyEnd?.upperBound ?? raw.index(after: tagEnd)
            guard let identity = attribute("identity", in: tag), !identity.isEmpty else { continue }
            out.append(Part(identity: identity, name: element("name", in: body) ?? ""))
        }
        return out
    }

    /// Caller of a missed-call event: the first part that is not the
    /// owner, else the event sender MRI (when not the owner). Nil for
    /// non-missed events or when no caller id is present.
    public static func missedCaller(raw: String, senderID: String?, ownerMRI: String?) -> Part? {
        guard partlistType(raw) == "missed" else { return nil }
        let owner = (ownerMRI ?? "").lowercased()
        let isOwner = { (id: String) in !owner.isEmpty && id.lowercased() == owner }
        if let p = parts(raw).first(where: { !isOwner($0.identity) }) { return p }
        if let s = senderID?.trimmingCharacters(in: .whitespacesAndNewlines),
           Mri.isMri(s), !isOwner(s)
        {
            return Part(identity: s, name: "")
        }
        return nil
    }

    /// `key="value"` / `key='value'` from a tag body, HTML-unescaped.
    static func attribute(_ key: String, in tag: String) -> String? {
        for q in ["\"", "'"] {
            if let r = tag.range(of: "\(key)=\(q)", options: .caseInsensitive),
               let end = tag[r.upperBound...].firstIndex(of: Character(q))
            {
                return unescape(String(tag[r.upperBound..<end])).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func element(_ name: String, in body: String) -> String? {
        guard let o = body.range(of: "<\(name)>", options: .caseInsensitive),
              let c = body.range(of: "</\(name)>", options: .caseInsensitive, range: o.upperBound..<body.endIndex)
        else { return nil }
        return unescape(String(body[o.upperBound..<c.lowerBound])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
