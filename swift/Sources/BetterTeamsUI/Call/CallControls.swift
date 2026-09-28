// CallControls.swift — pure pieces of the call controls (UI-SPEC §8):
// the state → toolbar/menu mapping for Mute, Camera and Share Screen,
// the duration text the 1 s ticker feeds, and the participant tiles.
// Both hosts (main-window toolbar and the call window's toolbar) apply
// the same mapping to items with the same identifiers.
import AppKit
import OstMacCore

/// One control's face: symbol, toolbar label, menu title, enablement.
public struct CallControl: Equatable, Sendable {
    public var symbol: String
    public var label: String
    public var menuTitle: String
    public var enabled: Bool
}

/// The controls for one call state. The symbol shows the current state
/// (a muted mic shows `mic.slash.fill`); the label names the action.
public struct CallControlsState: Equatable, Sendable {
    public var joined: Bool
    public var muted: Bool
    public var cameraOn: Bool
    public var sharing: Bool

    public init(joined: Bool, muted: Bool, cameraOn: Bool, sharing: Bool) {
        self.joined = joined
        self.muted = muted
        self.cameraOn = cameraOn
        self.sharing = sharing
    }

    public var mute: CallControl {
        muted
            ? CallControl(symbol: "mic.slash.fill", label: "Unmute", menuTitle: "Unmute Microphone", enabled: true)
            : CallControl(symbol: "mic.fill", label: "Mute", menuTitle: "Mute Microphone", enabled: true)
    }

    public var camera: CallControl {
        cameraOn
            ? CallControl(symbol: "video.fill", label: "Camera Off", menuTitle: "Turn Camera Off", enabled: true)
            : CallControl(symbol: "video.slash.fill", label: "Camera On", menuTitle: "Turn Camera On", enabled: true)
    }

    /// Sharing needs a joined call (nothing to share into before).
    public var share: CallControl {
        sharing
            ? CallControl(symbol: "rectangle.on.rectangle.slash", label: "Stop Sharing", menuTitle: "Stop Sharing",
                          enabled: joined)
            : CallControl(symbol: "rectangle.on.rectangle", label: "Share Screen", menuTitle: "Share Screen…",
                          enabled: joined)
    }

    func control(_ id: CommandID) -> CallControl? {
        switch id {
        case CallCommands.mute: mute
        case CallCommands.camera: camera
        case CallCommands.share: share
        default: nil
        }
    }
}

/// Call duration text (§8: toolbar subtitle, rail item, toolbar call
/// item, Calls row): m:ss under an hour, h:mm:ss after.
public enum CallDuration {
    public static func text(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        let ss = sec < 10 ? "0\(sec)" : "\(sec)"
        if h > 0 {
            let mm = m < 10 ? "0\(m)" : "\(m)"
            return "\(h):\(mm):\(ss)"
        }
        return "\(m):\(ss)"
    }

    /// VoiceOver wording: "Current call, 12 minutes" (§8 rail item).
    public static func accessibility(_ seconds: Int?) -> String {
        guard let seconds else { return "Current call" }
        let m = max(0, seconds) / 60
        if m == 0 { return "Current call, less than a minute" }
        return "Current call, \(m) minute\(m == 1 ? "" : "s")"
    }
}

/// One stage tile.
public struct CallTile: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case person, selfView, share }
    public var id: String
    public var name: String
    public var kind: Kind
    public var speaking: Bool
    public var muted: Bool
    public var cameraOn: Bool
}

public enum CallTiles {
    /// Stage tiles: remote people (roster order, or the called person),
    /// then the self view, then the share tile while sharing. A roster
    /// row for the signed-in user becomes the self view, never a second
    /// tile.
    public static func make(roster: [MeetingParticipant], peer: String?, ownName: String,
                            isOwn: (MeetingParticipant) -> Bool,
                            muted: Bool, cameraOn: Bool, sharing: Bool) -> [CallTile] {
        var out: [CallTile] = []
        var selfSpeaking = false
        for p in roster where p.present {
            if isOwn(p) {
                selfSpeaking = p.speaking
                continue
            }
            out.append(CallTile(id: p.id, name: p.name, kind: .person, speaking: p.speaking,
                                muted: p.muted, cameraOn: false))
        }
        if roster.isEmpty, let peer, !peer.isEmpty {
            out.append(CallTile(id: "peer", name: peer, kind: .person, speaking: false, muted: false, cameraOn: false))
        }
        out.append(CallTile(id: "self", name: ownName, kind: .selfView, speaking: selfSpeaking && !muted,
                            muted: muted, cameraOn: cameraOn))
        if sharing {
            out.append(CallTile(id: "share", name: "Your Screen", kind: .share, speaking: false, muted: false,
                                cameraOn: false))
        }
        return out
    }
}

/// Applies a controls state to a toolbar's call items (main window or
/// call window: same identifiers).
@MainActor
enum CallToolbar {
    static func apply(_ s: CallControlsState, to toolbar: NSToolbar?) {
        guard let toolbar else { return }
        for item in toolbar.items {
            guard let c = s.control(CommandID(item.itemIdentifier.rawValue)) else { continue }
            if item.label != c.label {
                item.label = c.label
                item.toolTip = c.menuTitle
                item.image = NSImage(systemSymbolName: c.symbol, accessibilityDescription: c.label)
            }
        }
    }

    /// The toolbar call item's face (duration + Show/Mute/Leave menu).
    static func applyStatus(_ text: String, accessibility: String, to toolbar: NSToolbar?) {
        guard let toolbar,
              let b = toolbar.items.first(where: { $0.itemIdentifier.rawValue == CallCommands.show.rawValue })?
                  .view as? CallStatusButton else { return }
        if b.title != text {
            b.title = text
            b.invalidateIntrinsicContentSize()
        }
        b.setAccessibilityLabel(accessibility)
    }
}
