// MediaMemoryStore.swift — memory tier for RichMediaCache and
// DecodedImageCache.
//
// `.system` is an NSCache: the OS purges it (and stops retaining new
// entries) while the machine is under memory pressure, which is what
// the app wants. `.pinned` is a plain cost-bounded map the OS never
// touches, so a stored entry stays a hit whatever the machine's memory
// pressure — tests use it so cache-hit assertions are deterministic.
import Foundation

public enum MediaMemoryPolicy: Sendable {
    /// NSCache; purgeable by the OS under memory pressure (app default).
    case system
    /// Never purged by the OS; evicts oldest-first only past the cost limit.
    case pinned
}

/// NSCache-shaped store. Not thread-safe in `.pinned` mode: each owner
/// is an actor that keeps it as isolated state.
final class MediaMemoryStore<Value: AnyObject> {
    private let system: NSCache<NSString, Value>?
    private let costLimit: Int
    private var pinned: [NSString: (value: Value, cost: Int)] = [:]
    private var order: [NSString] = []
    private var pinnedCost = 0

    /// `costLimit` <= 0 means unbounded (NSCache semantics).
    init(policy: MediaMemoryPolicy, costLimit: Int) {
        self.costLimit = costLimit
        switch policy {
        case .system:
            let cache = NSCache<NSString, Value>()
            cache.totalCostLimit = costLimit
            system = cache
        case .pinned:
            system = nil
        }
    }

    func object(forKey key: NSString) -> Value? {
        if let system { return system.object(forKey: key) }
        return pinned[key]?.value
    }

    func setObject(_ value: Value, forKey key: NSString, cost: Int) {
        if let system {
            system.setObject(value, forKey: key, cost: cost)
            return
        }
        if let old = pinned[key] {
            pinnedCost -= old.cost
            order.removeAll { $0 == key }
        }
        pinned[key] = (value, cost)
        order.append(key)
        pinnedCost += cost
        while costLimit > 0, pinnedCost > costLimit, order.count > 1 {
            let oldest = order.removeFirst()
            if let gone = pinned.removeValue(forKey: oldest) {
                pinnedCost -= gone.cost
            }
        }
    }

    func removeAllObjects() {
        if let system {
            system.removeAllObjects()
            return
        }
        pinned.removeAll()
        order.removeAll()
        pinnedCost = 0
    }
}
