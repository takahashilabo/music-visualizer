import CoreAudio
import Accelerate
import Foundation

enum SystemAudioTapError: Error, CustomStringConvertible {
    case tapCreationFailed(OSStatus)
    case formatQueryFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case startFailed(OSStatus)

    var description: String {
        switch self {
        case .tapCreationFailed(let status): return "AudioHardwareCreateProcessTap failed (\(status))"
        case .formatQueryFailed(let status): return "Reading tap format failed (\(status))"
        case .aggregateCreationFailed(let status): return "AudioHardwareCreateAggregateDevice failed (\(status))"
        case .ioProcCreationFailed(let status): return "AudioDeviceCreateIOProcIDWithBlock failed (\(status))"
        case .startFailed(let status): return "AudioDeviceStart failed (\(status))"
        }
    }
}

/// Captures a stereo mixdown of the Mac's entire system audio output using the
/// Core Audio Process Tap API (macOS 14.2+), with no virtual audio driver.
/// Delivers raw PCM buffers on a dedicated dispatch queue via `onBuffer`.
final class SystemAudioTap {
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "SystemAudioTap.io")

    private(set) var format = AudioStreamBasicDescription()

    /// Called on an internal realtime-ish queue with interleaved/non-interleaved
    /// Float32 buffers exactly as delivered by Core Audio for the tap's format.
    var onBuffer: ((AudioBufferList, AudioStreamBasicDescription) -> Void)?

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "MusicVisualizerSystemTap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID: AudioObjectID = kAudioObjectUnknown
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw SystemAudioTapError.tapCreationFailed(status) }
        tapID = newTapID

        var tapFormat = AudioStreamBasicDescription()
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &tapFormat)
        guard status == noErr else { throw SystemAudioTapError.formatQueryFailed(status) }
        format = tapFormat

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MusicVisualizerAggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr else { throw SystemAudioTapError.aggregateCreationFailed(status) }
        aggregateDeviceID = newAggregateID

        var newProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateDeviceID, ioQueue) { [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            self.onBuffer?(inputData.pointee, self.format)
        }
        guard status == noErr, let procID = newProcID else {
            throw SystemAudioTapError.ioProcCreationFailed(status)
        }
        ioProcID = procID

        status = AudioDeviceStart(aggregateDeviceID, procID)
        guard status == noErr else { throw SystemAudioTapError.startFailed(status) }
    }

    func stop() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    deinit {
        stop()
    }
}
