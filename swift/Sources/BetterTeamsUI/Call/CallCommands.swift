// CallCommands.swift — the running call's commands (UI-SPEC §8, §9.1
// Call menu). Controls live in the toolbar and the Call menu, never a
// bottom bar: Mute (⇧⌘M), Camera (⇧⌘O), Share Screen (⇧⌘E), Devices
// (popover), Leave (⇧⌘H, the one `.prominent` red trailing item). The
// People | Chat inspector uses the shell's inspector toggle. `show` is
// also the toolbar call item (status item, §5.4 order): duration + a
// menu of Show Call, Mute/Unmute, Leave; it shows while a call runs and
// the stage is not on screen in this window.
import AppKit

public enum CallCommands {
    public static let show: CommandID = "call.show"
    public static let leave: CommandID = "call.leave"
    public static let mute: CommandID = "call.mute"
    public static let camera: CommandID = "call.camera"
    public static let share: CommandID = "call.share"
    public static let devices: CommandID = "call.devices"

    /// Popover name (evidence `popover=devices`).
    public static let devicesPopover = "devices"

    @MainActor
    public static let all: [Command] = [
        Command(show, "Show Call", symbol: "phone.fill", menu: .init(.call, group: 0, order: 2),
                toolbar: .trailing, owner: .call),
        Command(mute, "Mute Microphone", symbol: "mic.fill", key: "m", modifiers: [.command, .shift],
                menu: .init(.call, group: 2, order: 0), toolbar: .detail, owner: .call),
        Command(camera, "Turn Camera On", symbol: "video.slash.fill", key: "o", modifiers: [.command, .shift],
                menu: .init(.call, group: 2, order: 1), toolbar: .detail, owner: .call),
        Command(share, "Share Screen…", symbol: "rectangle.on.rectangle", key: "e", modifiers: [.command, .shift],
                menu: .init(.call, group: 2, order: 2), toolbar: .detail, owner: .call),
        Command(devices, "Devices…", symbol: "slider.horizontal.3",
                menu: .init(.call, group: 2, order: 3), toolbar: .detail, owner: .call),
        Command(leave, "Leave Call", symbol: "phone.down.fill", key: "h", modifiers: [.command, .shift],
                menu: .init(.call, group: 0, order: 9), toolbar: .trailing, owner: .call),
    ]
}
