// Debounce.swift — the one allowed delay (UI-SPEC R7 exception):
// 250 ms search-as-you-type.
import Foundation

@MainActor
final class Debounce {
    private let nanoseconds: UInt64
    private var task: Task<Void, Never>?

    init(milliseconds: UInt64) {
        nanoseconds = milliseconds * 1_000_000
    }

    func schedule(_ work: @escaping @MainActor () -> Void) {
        task?.cancel()
        let ns = nanoseconds
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            work()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
