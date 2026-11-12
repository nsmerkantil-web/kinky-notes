import Foundation
import CoreAudio

final class CallDetector {
    private var timer: Timer?
    var onChange: ((Set<pid_t>) -> Void)?
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }
    private func poll() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return }
        var active = Set<pid_t>()
        for object in objects {
            var running: UInt32 = 0
            var n = UInt32(MemoryLayout<UInt32>.size)
            address.mSelector = kAudioProcessPropertyIsRunningInput
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &n, &running) == noErr, running != 0 else { continue }
            var pid: pid_t = 0
            n = UInt32(MemoryLayout<pid_t>.size)
            address.mSelector = kAudioProcessPropertyPID
            if AudioObjectGetPropertyData(object, &address, 0, nil, &n, &pid) == noErr { active.insert(pid) }
        }
        onChange?(active)
    }
}
