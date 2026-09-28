// CallIndicators.swift — where a running call shows outside its stage
// (UI-SPEC §8): the rail call item (In Main Window), the toolbar call
// item (status item: duration + Show Call / Mute / Leave menu, green
// `phone.fill`, no background tint), the Devices toolbar button (the
// popover's anchor), and the Calls row's live duration. The session's
// 1 s ticker feeds all of them.
import AppKit
import OstMacCore
import SwiftUI

/// Toolbar item views for call commands (the shell asks once, when
/// NSToolbar creates the item; nil = a standard item).
@MainActor
enum CallToolbarViews {
    static func view(for id: CommandID, model: WindowModel?) -> NSView? {
        switch id {
        case CallCommands.show: CallStatusButton(model: model)
        case CallCommands.devices: CallDevicesButton(model: model)
        default: nil
        }
    }
}

/// Toolbar call item: "12:34" with a green `phone.fill`; click opens
/// Show Call, Mute/Unmute, Leave.
@MainActor
final class CallStatusButton: NSButton {
    private weak var model: WindowModel?

    init(model: WindowModel?) {
        self.model = model
        super.init(frame: .zero)
        title = "Call"
        image = NSImage(systemSymbolName: "phone.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemGreen]))
        imagePosition = .imageLeading
        bezelStyle = .toolbar
        setButtonType(.momentaryPushIn)
        font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        toolTip = "Current Call"
        setAccessibilityLabel("Current call")
        target = self
        action = #selector(clicked(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    @objc private func clicked(_ sender: Any?) {
        guard let s = model?.call, !s.ended else { return }
        let menu = NSMenu(title: "Current Call")
        menu.autoenablesItems = false
        let show = NSMenuItem(title: "Show Call", action: #selector(showCall(_:)), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let mute = NSMenuItem(title: s.controls.muted ? "Unmute" : "Mute", action: #selector(toggleMute(_:)),
                              keyEquivalent: "")
        mute.target = self
        menu.addItem(mute)
        menu.addItem(.separator())
        let leave = NSMenuItem(title: "Leave Call", action: #selector(leaveCall(_:)), keyEquivalent: "")
        leave.target = self
        menu.addItem(leave)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func showCall(_ sender: Any?) { model?.call?.show() }
    @objc private func toggleMute(_ sender: Any?) { model?.call?.toggleMute() }
    @objc private func leaveCall(_ sender: Any?) { model?.call?.leave() }
}

/// Devices toolbar button: anchors the Devices popover.
@MainActor
final class CallDevicesButton: NSButton {
    private weak var model: WindowModel?
    private weak var session: CallSession?

    /// Main-window item (the window's running call).
    init(model: WindowModel?) {
        self.model = model
        super.init(frame: .zero)
        setUp()
    }

    /// Call-window item (that window's call).
    init(session: CallSession) {
        self.session = session
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    private func setUp() {
        title = ""
        image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Devices")
        imagePosition = .imageOnly
        bezelStyle = .toolbar
        setButtonType(.momentaryPushIn)
        toolTip = "Devices"
        target = self
        action = #selector(clicked(_:))
    }

    @objc private func clicked(_ sender: Any?) {
        (session ?? model?.call)?.showDevices(from: self)
    }
}

extension CallToolbar {
    static func devicesButton(in toolbar: NSToolbar?) -> NSView? {
        toolbar?.items.first { $0.itemIdentifier.rawValue == CallCommands.devices.rawValue && !$0.isHidden }?.view
    }
}

/// Rail call item (§8 In Main Window): after the pinned and transient
/// apps, never overflowed; label = duration in monospaced digits.
struct CallRailItem: View {
    let session: CallSession
    let navigator: Navigator
    let current: SectionID?
    let height: CGFloat

    var body: some View {
        let selected = current == .call
        Button {
            navigator.select(section: .call)
        } label: {
            RailButtonLabel(title: session.indicatorText, symbol: session.video ? "video.fill" : "phone.connection.fill",
                            badge: nil)
                .monospacedDigit()
        }
        .buttonStyle(RailButtonStyle(selected: selected, height: height))
        .help("Current Call")
        .accessibilityLabel(CallDuration.accessibility(session.connected ? session.elapsed : nil))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Calls ▸ Current call row detail: call name · live duration.
struct CallDurationText: View {
    let session: CallSession
    var scale: Double = 1

    var body: some View {
        Text(session.connected ? "\(session.title) · \(session.indicatorText)" : session.title)
            .font(AppFont.subheadline(scale))
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}
