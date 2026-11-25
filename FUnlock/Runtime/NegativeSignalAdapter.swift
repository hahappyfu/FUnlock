import Foundation
import CoreAudio
import Network

/// 负向快采传感器适配器：监听耳机/默认音频输出设备变更与网络路径变化，
/// 在不开启持续高频扫描的前提下，触发 `NegativeHintSource` 加速 BLE `.activePoll`。
@MainActor
final class NegativeSignalAdapter {
    private let onHint: @MainActor (NegativeHintSource) -> Void
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.funlock.negativeHintMonitor", qos: .utility)
    private var didReceiveInitialPath = false
    private var lastAudioDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var audioListenerBlock: AudioObjectPropertyListenerBlock?
    private let systemAudioObject = AudioObjectID(kAudioObjectSystemObject)
    private var audioPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(onHint: @escaping @MainActor (NegativeHintSource) -> Void) {
        self.onHint = onHint
    }

    func start() {
        startNetworkMonitor()
        startAudioOutputMonitor()
    }

    func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
        didReceiveInitialPath = false
        if let block = audioListenerBlock {
            audioListenerBlock = nil
            AudioObjectRemovePropertyListenerBlock(
                systemAudioObject,
                &audioPropertyAddress,
                DispatchQueue.main,
                block
            )
        }
    }

    func emit(_ source: NegativeHintSource) {
        onHint(source)
    }

    private func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        didReceiveInitialPath = false
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.didReceiveInitialPath {
                    self.didReceiveInitialPath = true
                    return
                }
                self.emit(.networkChanged)
            }
        }
        monitor.start(queue: monitorQueue)
        pathMonitor = monitor
    }

    private func startAudioOutputMonitor() {
        guard audioListenerBlock == nil else { return }
        lastAudioDeviceID = readDefaultOutputDeviceID()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let current = self.readDefaultOutputDeviceID()
                defer { self.lastAudioDeviceID = current }
                if self.lastAudioDeviceID != AudioObjectID(kAudioObjectUnknown) && current != self.lastAudioDeviceID {
                    self.emit(.audioOutputDisconnected)
                }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            systemAudioObject,
            &audioPropertyAddress,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            audioListenerBlock = block
        }
    }

    private func readDefaultOutputDeviceID() -> AudioObjectID {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(systemAudioObject, &audioPropertyAddress, 0, nil, &size, &deviceID)
        return deviceID
    }
}
