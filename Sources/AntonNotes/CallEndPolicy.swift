import Foundation

struct CallEndPolicy {
    private var observedCall = false
    private var inactiveSince: Date?

    mutating func shouldStop(recording: Bool, callActive: Bool, now: Date) -> Bool {
        guard recording else { self = Self(); return false }
        if callActive { observedCall = true; inactiveSince = nil; return false }
        guard observedCall else { return false }
        guard let inactiveSince else { self.inactiveSince = now; return false }
        return now.timeIntervalSince(inactiveSince) >= 6
    }
}
