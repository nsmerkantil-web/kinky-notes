import Foundation
import Testing
@testable import AntonNotes

@Test func endsRecordingAfterCallHasBeenInactiveForSixSeconds() {
    var policy = CallEndPolicy()
    let now = Date()
    #expect(!{ policy.shouldStop(recording: true, callActive: true, now: now) }())
    #expect(!{ policy.shouldStop(recording: true, callActive: false, now: now) }())
    #expect(!{ policy.shouldStop(recording: true, callActive: false, now: now.addingTimeInterval(4)) }())
    #expect({ policy.shouldStop(recording: true, callActive: false, now: now.addingTimeInterval(6)) }())
    #expect(!{ policy.shouldStop(recording: false, callActive: false, now: now.addingTimeInterval(8)) }())
}

@Test func ignoresManualRecordingAndTemporaryCallDropouts() {
    var policy = CallEndPolicy()
    let now = Date()
    #expect(!{ policy.shouldStop(recording: true, callActive: false, now: now) }())
    #expect(!{ policy.shouldStop(recording: true, callActive: false, now: now.addingTimeInterval(60)) }())
    #expect(!{ policy.shouldStop(recording: true, callActive: true, now: now) }())
    #expect(!{ policy.shouldStop(recording: true, callActive: false, now: now) }())
    #expect(!{ policy.shouldStop(recording: true, callActive: true, now: now.addingTimeInterval(4)) }())
    #expect(!{ policy.shouldStop(recording: true, callActive: false, now: now.addingTimeInterval(8)) }())
    #expect(!{ policy.shouldStop(recording: false, callActive: false, now: now.addingTimeInterval(9)) }())
    #expect(!{ policy.shouldStop(recording: true, callActive: false, now: now.addingTimeInterval(20)) }())
}
