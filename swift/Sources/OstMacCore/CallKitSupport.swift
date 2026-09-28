// CallKitSupport.swift — gap-g4: CallKit verdict + native call routing.
//
// VERDICT: full CallKit provider integration is IMPOSSIBLE on macOS.
// Apple marks the entire provider side API_UNAVAILABLE(macos):
// - CXProvider (CXProvider.h:79, MacOSX27.0.sdk)
// - CXCallController (CXCallController.h:16), CXCallObserver
//   (CXCallObserver.h:15,22), CXProviderDelegate (CXProvider.h:38,40)
// A static CXProvider reference is a compile error on macOS (proven
// by probe, see proof); availability is therefore a compile-time
// gate (CallKitSupport.providerAvailable), never a class lookup.
// There is no native macOS call UI, no system call-answer, no
// system-Recents API for third-party VoIP on the Mac.
//
// CONSEQUENCE: G3 (UNNotification banner + NSSound ring) is not the
// fallback — it is the only path, permanently, on macOS. CallRouting
// pins that rule in one pure function so a future OS that ships
// CXProvider flips one predicate instead of re-plumbing CallStore.
// The G3 hooks (CallStore.onIncomingRing/onRingEnded + ringer) stay
// exactly as-is; G4 only routes THROUGH them and hardens the two
// accept-criteria with a macOS-native answer:
// - system mute: CallRinger consults SystemAudioMute (CoreAudio
//   default-output mute) and never starts a ring into a muted
//   output; the banner still posts (a muted speaker must not eat
//   the visual call too).
// - DND/Focus by OS policy: the call banner carries interruption
//   .active (OmCallInfo.makeContent), so Focus/DND suppress it by
//   system policy — no app-side quiet-hours check, no bypass.
// - recents: no system-Recents API exists on macOS; in-app
//   CallHistory (CallHistory.swift) is the recents surface.
// - system answer: the banner's Accept/Decline actions (G3) are the
//   native macOS answer path; no OS call UI exists to answer from.
import CoreAudio
import Foundation

/// CallKit provider availability: an SDK-CONTRACT gate, not a class
/// probe. A static CXProvider reference does not compile on macOS
/// (API_UNAVAILABLE), so there is no shippable use whatever the
/// runtime says. (Observed: NSClassFromString("CXProvider") resolves
/// under the XCTest harness but not in a plain process — harness
/// image-loading noise; unusable either way with no linkable
/// symbol, hence this compile-time gate instead of a probe.)
public enum CallKitSupport {
    /// True iff the CallKit provider API is usable on this platform
    /// (false on every macOS — the GapG4 test pins it; if a future
    /// SDK marks CXProvider available here, flip this leg and wire
    /// CallRouting.callKit for real).
    public static var providerAvailable: Bool {
#if os(macOS)
        return false
#else
        return NSClassFromString("CXProvider") != nil
#endif
    }
}

/// Where an incoming ring goes. One pure rule, tested both legs.
public enum CallRouting: String, Sendable, Equatable {
    /// Native OS call UI via CXProvider (unreachable on macOS today).
    case callKit
    /// G3 UNNotification banner + NSSound ring (the macOS path).
    case g3Banner

    public static func route(providerAvailable: Bool) -> CallRouting {
        providerAvailable ? .callKit : .g3Banner
    }

    /// Live route on this machine (always .g3Banner on macOS).
    public static var current: CallRouting {
        route(providerAvailable: CallKitSupport.providerAvailable)
    }
}

/// Default-output mute probe (native CoreAudio only). Fails OPEN:
/// any error (no device, unmuted-property missing, non-zero status)
/// reads as unmuted so a broken probe never silences a ring.
public enum SystemAudioMute {
    /// True when the default output device is currently muted.
    public static func isOutputMuted() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &device) == noErr,
            device != kAudioDeviceUnknown
        else { return false }
        var muted: UInt32 = 0
        var msize = UInt32(MemoryLayout<UInt32>.size)
        var maddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            device, &maddr, 0, nil, &msize, &muted) == noErr
        else { return false }
        return muted != 0
    }
}
