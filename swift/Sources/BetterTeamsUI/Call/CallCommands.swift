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
    public static let showPeople: CommandID = "call.showPeople"
    public static let showChat: CommandID = "call.showChat"
    /// Server-side capture (meetrecord): Record (full flow) and
    /// Transcribe (transcription only), Call menu + call toolbars.
    public static let record: CommandID = "call.record"
    public static let transcribe: CommandID = "call.transcribe"
    /// Teams parity (C8b): a ringing call's answer/decline, the
    /// in-call hand, and opt-in push-to-talk (all confined to the Call
    /// menu, like the D2 call keys).
    public static let accept: CommandID = "call.accept"
    public static let decline: CommandID = "call.decline"
    public static let hand: CommandID = "call.hand"
    public static let pushToTalk: CommandID = "call.pushToTalk"
    /// Breakout rooms sheet (BREAKOUT): Call menu, group meetings only.
    public static let rooms: CommandID = "call.rooms"
    /// Sheet name for the rooms plan (SheetRequest names are strings).
    public static let roomsSheet = "rooms"

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
        Command(record, "Start Recording", symbol: "record.circle",
                menu: .init(.call, group: 2, order: 6), toolbar: .detail, owner: .call),
        Command(transcribe, "Start Transcription", symbol: "captions.bubble",
                menu: .init(.call, group: 2, order: 7), toolbar: .detail, owner: .call),
        Command(leave, "Leave Call", symbol: "phone.down.fill", key: "h", modifiers: [.command, .shift],
                menu: .init(.call, group: 0, order: 9), toolbar: .trailing, owner: .call),
        // The call's People | Chat inspector (SPECFIX-P2 #13): titles
        // flip Show/Hide via validation, like the shell inspector item.
        Command(showPeople, "Show People", symbol: "person.2",
                menu: .init(.call, group: 0, order: 5), owner: .call),
        Command(showChat, "Show Chat", symbol: "bubble.left.and.bubble.right",
                key: "r", modifiers: [.command, .shift],
                menu: .init(.call, group: 0, order: 6), owner: .call),
        Command(accept, "Accept Call", symbol: "phone.fill",
                key: "a", modifiers: [.command, .shift],
                menu: .init(.call, group: 0, order: 7), owner: .call),
        Command(decline, "Decline Call", symbol: "phone.down",
                key: "d", modifiers: [.command, .shift],
                menu: .init(.call, group: 0, order: 8), owner: .call),
        Command(hand, "Raise Hand", symbol: "hand.raised",
                key: "k", modifiers: [.command, .shift],
                menu: .init(.call, group: 2, order: 4), owner: .call),
        Command(pushToTalk, "Push to Talk", symbol: "mic",
                key: " ", modifiers: [.option],
                menu: .init(.call, group: 2, order: 5), owner: .call),
        Command(rooms, "Breakout Rooms…", symbol: "person.3.fill",
                menu: .init(.call, group: 2, order: 8), owner: .call),
    ]
}
