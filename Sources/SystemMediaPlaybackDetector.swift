import CoreAudio
import Darwin
import Foundation

final class SystemMediaPlaybackDetector {
    func snapshot() -> ExternalAudioPlaybackSnapshot {
        guard let processes = runningOutputAudioProcesses() else {
            return ExternalAudioPlaybackSnapshot(
                processLabels: [],
                isAvailable: false
            )
        }
        return ExternalAudioPlaybackSnapshot(
            processLabels: Set(processes)
        )
    }

    private func runningOutputAudioProcesses() -> [String]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else {
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else {
            return []
        }

        var processObjects = [AudioObjectID](repeating: 0, count: count)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &processObjects
        )
        guard dataStatus == noErr else {
            return nil
        }

        let currentPID = getpid()
        return processObjects.compactMap { objectID in
            guard readUInt32(
                objectID,
                selector: kAudioProcessPropertyIsRunningOutput
            ) != 0 else {
                return nil
            }
            if readPID(objectID) == currentPID {
                return nil
            }
            return processLabel(objectID)
        }
    }

    private func readUInt32(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        return status == noErr ? value : 0
    }

    private func readPID(_ objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = pid_t(0)
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        return status == noErr ? value : nil
    }

    private func readString(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr,
              let retained = value?.takeRetainedValue() else {
            return nil
        }
        let text = (retained as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func processLabel(_ objectID: AudioObjectID) -> String {
        if let bundleID = readString(
            objectID,
            selector: kAudioProcessPropertyBundleID
        ) {
            return bundleID
        }
        if let pid = readPID(objectID) {
            return "pid:\(pid)"
        }
        return "audio-process:\(objectID)"
    }
}
