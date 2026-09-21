import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

/// What the last capture actually saw. Cheap to collect and the only way to
/// tell, without listening, that both sources really carried signal.
public struct CaptureDiagnostics: Equatable, CustomStringConvertible {
    /// True when the aggregate device was built with a system-audio tap.
    public let systemAudioAvailable: Bool
    /// Sample rate the aggregate device ran at.
    public let sampleRate: Double
    /// Channel count of each input buffer of the aggregate, in the order the
    /// IO proc delivers them. The microphone comes first, the tap after it.
    public let bufferChannelCounts: [Int]
    /// Peak absolute amplitude seen on each input buffer, same order.
    public let sourcePeaks: [Float]
    /// Frames pushed to the encoder.
    public let framesCaptured: Int64
    /// Number of IO cycles.
    public let callbackCount: Int
    /// IO cycles dropped because the encoder could not keep up. Any value above
    /// zero means the recording has gaps.
    public let droppedBuffers: Int

    public var duration: TimeInterval {
        sampleRate > 0 ? TimeInterval(framesCaptured) / sampleRate : 0
    }

    public var description: String {
        """
        systemAudioAvailable=\(systemAudioAvailable) sampleRate=\(sampleRate) \
        buffers=\(bufferChannelCounts.count) channels=\(bufferChannelCounts) \
        peaks=\(sourcePeaks) frames=\(framesCaptured) callbacks=\(callbackCount) \
        dropped=\(droppedBuffers) duration=\(String(format: "%.3f", duration))s
        """
    }
}

/// Microphone and system audio captured through a single private aggregate
/// device, so both sources share one clock and need no drift correction.
public final class CoreAudioCapture: AudioCapture {
    public private(set) var isSystemAudioAvailable = false
    public private(set) var isDeviceWatchArmed = false
    /// Populated by `stop()`, once the IO proc can no longer be running.
    public private(set) var diagnostics: CaptureDiagnostics?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: AudioFileWriter?
    private var stats: CaptureStats?
    private var watcher: DeviceWatcher?
    private var sampleRate: Double = 0
    private var outputURL: URL?

    public init() {}

    deinit {
        releaseCoreAudioObjects()
        _ = writer?.finish()
    }

    public func start() throws -> Date {
        guard outputURL == nil else {
            // Already running: refuse rather than orphan the current capture.
            throw CaptureError.aggregateDeviceFailed(kAudioHardwareIllegalOperationError)
        }
        guard let inputUID = Self.defaultInputDeviceUID() else { throw CaptureError.noInputDevice }

        isDeviceWatchArmed = false
        let tapUID = createTap()
        isSystemAudioAvailable = tapUID != nil

        do {
            aggregateID = try createAggregate(inputUID: inputUID, tapUID: tapUID)
        } catch {
            // The microphone alone is still worth recording, so drop the tap
            // and retry rather than failing the whole capture.
            guard tapUID != nil else { throw error }
            destroyTap()
            isSystemAudioAvailable = false
            aggregateID = try createAggregate(inputUID: inputUID, tapUID: nil)
        }

        var createdFile: URL?
        do {
            let rate = Self.nominalSampleRate(of: aggregateID)
            sampleRate = rate
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: rate,
                                             channels: 1,
                                             interleaved: false) else {
                throw CaptureError.aggregateDeviceFailed(kAudioHardwareUnsupportedOperationError)
            }

            let url = RecordingStorage.newFileURL()
            createdFile = url
            // Every buffer the IO thread will ever need is allocated here, so
            // the audio thread itself never reaches the allocator.
            let slotFrames = AVAudioFrameCount(max(Self.bufferFrameSize(of: aggregateID) * 2, 2048))
            let writer = try AudioFileWriter(format: format,
                                             url: url,
                                             slotFrames: slotFrames,
                                             settings: [
                                                AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                AVSampleRateKey: rate,
                                                AVNumberOfChannelsKey: 1,
                                                AVEncoderBitRateKey: 64_000
                                             ])
            let stats = CaptureStats()
            self.writer = writer
            self.stats = stats
            outputURL = url

            var procID: AudioDeviceIOProcID?
            let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
                _, inputData, _, _, _ in
                CoreAudioCapture.mix(inputData, writer: writer, stats: stats)
            }
            guard status == noErr, let procID else {
                throw CaptureError.aggregateDeviceFailed(status == noErr ? kAudio_ParamError : status)
            }
            ioProcID = procID

            let startStatus = AudioDeviceStart(aggregateID, procID)
            guard startStatus == noErr else {
                throw CaptureError.aggregateDeviceFailed(startStatus)
            }

            // Watch for the device dying or changing rate under us. Registered
            // only once the device is running, so the first reading is healthy.
            let watcher = DeviceWatcher(device: aggregateID, baselineSampleRate: rate)
            isDeviceWatchArmed = watcher.start()
            self.watcher = watcher

            // Frames only start flowing once AudioDeviceStart has returned, so
            // this — not the entry of start() — is the meeting's recordedAt.
            return Date()
        } catch {
            teardown()
            // Nothing was captured, so the stub file left by the encoder would
            // only pollute the recordings folder.
            if let createdFile { try? FileManager.default.removeItem(at: createdFile) }
            throw error
        }
    }

    public func stop() throws -> URL {
        guard let url = outputURL else { throw CaptureError.notRecording }
        if let failure = teardown() {
            // The file exists but is not a recording. Refusing to return it is
            // what stops the upload flow from shipping a truncated meeting and
            // then deleting the local copy.
            throw failure
        }
        return url
    }

    /// Releases every CoreAudio object and closes the file, in the only order
    /// that is safe: the IO proc first, so nothing can touch the writer after.
    /// Returns the reason the recording must be rejected, or nil when it is
    /// sound.
    @discardableResult
    private func teardown() -> CaptureError? {
        releaseCoreAudioObjects()

        let deviceChanged = watcher?.didChange ?? false
        watcher = nil

        // Drains what is still queued, closes the file, and reports the first
        // encoder error if there was one.
        let writeError = writer?.finish()
        writer = nil

        let partialFile = outputURL?.path ?? ""
        let framesCaptured = stats?.framesCaptured ?? 0

        if let stats {
            diagnostics = CaptureDiagnostics(
                systemAudioAvailable: isSystemAudioAvailable,
                sampleRate: sampleRate,
                bufferChannelCounts: Array(stats.bufferChannelCounts.prefix(stats.sourceCount)),
                sourcePeaks: Array(stats.sourcePeaks.prefix(stats.sourceCount)),
                framesCaptured: stats.framesCaptured,
                callbackCount: stats.callbackCount,
                droppedBuffers: stats.droppedBuffers)
        }
        stats = nil
        outputURL = nil
        sampleRate = 0

        if let writeError {
            return .writeFailed(reason: String(describing: writeError), partialFile: partialFile)
        }
        if deviceChanged { return .deviceChanged(partialFile: partialFile) }
        if framesCaptured == 0 { return .nothingCaptured(partialFile: partialFile) }
        return nil
    }

    /// Safe to call twice, and safe to call from a failure path where only
    /// some of the objects exist.
    private func releaseCoreAudioObjects() {
        // Before stopping the device, so our own stop is not mistaken for the
        // device disappearing.
        watcher?.stop()

        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        destroyTap()
    }

    private func destroyTap() {
        guard tapID != AudioObjectID(kAudioObjectUnknown) else { return }
        AudioHardwareDestroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Mixing

    /// Sums every input channel of every buffer into one mono stream. The
    /// aggregate exposes the microphone buffers first, then the tap's — but
    /// nothing here depends on that order, every buffer is simply summed in.
    ///
    /// Runs on the real-time IO thread: it allocates nothing, never blocks, and
    /// fills a buffer the writer allocated up front. When the encoder has
    /// fallen behind, the cycle is dropped and counted instead of queued.
    private static func mix(_ inputData: UnsafePointer<AudioBufferList>,
                            writer: AudioFileWriter,
                            stats: CaptureStats) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))

        // Every stream of one device carries the same number of frames; take
        // the widest in case a disabled stream reports none.
        var frameCount = 0
        for buffer in buffers {
            let channels = Int(max(buffer.mNumberChannels, 1))
            frameCount = max(frameCount, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels)
        }
        guard frameCount > 0 else { return }

        // Storage is pre-sized, so this writes into existing elements only.
        let sourceCount = min(buffers.count, stats.sourcePeaks.count)
        if stats.sourceCount != sourceCount {
            stats.sourceCount = sourceCount
            for index in 0..<sourceCount {
                stats.bufferChannelCounts[index] = Int(buffers[index].mNumberChannels)
            }
        }

        let accepted = writer.withNextBuffer(frameCount: AVAudioFrameCount(frameCount)) { destination in
            destination.update(repeating: 0, count: frameCount)

            for index in 0..<buffers.count {
                let buffer = buffers[index]
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = Int(max(buffer.mNumberChannels, 1))
                let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
                let frames = min(frameCount, available)
                var peak: Float = 0
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        sum += data[frame * channels + channel]
                    }
                    let value = sum / Float(channels)
                    peak = max(peak, abs(value))
                    destination[frame] += value
                }
                if index < sourceCount {
                    stats.sourcePeaks[index] = max(stats.sourcePeaks[index], peak)
                }
            }

            // Two sources summed can clip; clamp instead of distorting.
            for frame in 0..<frameCount {
                destination[frame] = max(-1, min(1, destination[frame]))
            }
        }

        if accepted {
            stats.framesCaptured += Int64(frameCount)
            stats.callbackCount += 1
        } else {
            stats.droppedBuffers += 1
        }
    }

    // MARK: - CoreAudio plumbing

    /// Returns the tap's UID, or nil when the tap could not be created — in
    /// which case the capture carries on with the microphone alone.
    private func createTap() -> String? {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Whiteboard Recorder"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var id = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &id) == noErr,
              id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        tapID = id
        return description.uuid.uuidString
    }

    private func createAggregate(inputUID: String, tapUID: String?) throws -> AudioObjectID {
        var settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Whiteboard Recorder",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Start capturing straight away instead of waiting for a tapped
            // process to play something: the microphone must be recorded even
            // in a silent room.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: inputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: inputUID]]
        ]
        if let tapUID {
            settings[kAudioAggregateDeviceTapListKey] = [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]]
        }

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &id)
        guard status == noErr, id != AudioObjectID(kAudioObjectUnknown) else {
            throw CaptureError.aggregateDeviceFailed(status)
        }
        return id
    }

    private static func defaultInputDeviceUID() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }

        // CoreAudio hands back a +1 CFString here, so it has to be taken as an
        // Unmanaged reference to avoid leaking it.
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func nominalSampleRate(of device: AudioObjectID) -> Double {
        AudioDeviceProperties.nominalSampleRate(of: device)
    }

    /// Frames the device hands over per IO cycle, used to size the pre-allocated
    /// buffers.
    private static func bufferFrameSize(of device: AudioObjectID) -> UInt32 {
        var frames: UInt32 = 512
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &frames) == noErr,
              frames > 0 else { return 512 }
        return frames
    }
}

// MARK: - Supporting types

private enum AudioDeviceProperties {
    static func nominalSampleRate(of device: AudioObjectID) -> Double {
        var rate: Double = 48_000
        var size = UInt32(MemoryLayout<Double>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr,
              rate > 0 else { return 48_000 }
        return rate
    }

    static func flag(_ selector: AudioObjectPropertySelector, of device: AudioObjectID) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }
}

/// Owns the output file and a fixed ring of pre-allocated buffers.
///
/// Producer is the real-time IO thread, consumer is one dedicated thread. The
/// ring is bounded: when it is full the producer is told so and drops the cycle
/// rather than letting the backlog grow. Nothing on the producer side allocates.
private final class AudioFileWriter {
    private struct Shared {
        var pending = 0
        var stopping = false
    }

    private var file: AVAudioFile?
    private let slots: [AVAudioPCMBuffer]
    private let slotFrames: AVAudioFrameCount

    private var writeIndex = 0              // producer thread only
    private var readIndex = 0               // consumer thread only
    private var firstError: Error?          // consumer thread only, read after it exits

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let wakeup = DispatchSemaphore(value: 0)
    private let drained = DispatchSemaphore(value: 0)
    private var consumer: Thread?

    init(format: AVAudioFormat, url: URL, slotFrames: AVAudioFrameCount, settings: [String: Any]) throws {
        self.file = try AVAudioFile(forWriting: url, settings: settings)
        self.slotFrames = slotFrames
        self.slots = (0..<AudioFileWriter.slotCount).compactMap { _ in
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: slotFrames)
        }
        guard slots.count == AudioFileWriter.slotCount else {
            throw CaptureError.aggregateDeviceFailed(kAudio_MemFullError)
        }

        let thread = Thread { [weak self] in self?.consume() }
        thread.name = "io.keyban.whiteboard-recorder.audio-writer"
        thread.qualityOfService = .userInitiated
        consumer = thread
        thread.start()
    }

    /// Roughly a third of a second of backlog at a 512-frame cycle: enough to
    /// ride out an encoder hiccup, small enough to bound memory.
    private static let slotCount = 32

    /// Called from the IO thread. Hands the next free slot to `fill` and queues
    /// it. Returns false — allocating nothing, blocking on nothing — when the
    /// ring is full or the cycle is larger than a slot.
    func withNextBuffer(frameCount: AVAudioFrameCount,
                        fill: (UnsafeMutablePointer<Float>) -> Void) -> Bool {
        guard frameCount <= slotFrames else { return false }
        let hasRoom = shared.withLock { $0.pending < AudioFileWriter.slotCount }
        guard hasRoom else { return false }

        let buffer = slots[writeIndex]
        guard let destination = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = frameCount
        fill(destination)

        writeIndex = (writeIndex + 1) % AudioFileWriter.slotCount
        shared.withLock { $0.pending += 1 }
        wakeup.signal()
        return true
    }

    /// Drains what is already queued, closes the file and returns the first
    /// encoder error, if any. Must only be called once the IO proc is destroyed,
    /// so that no producer can still be running.
    func finish() -> Error? {
        guard consumer != nil else { return firstError }
        shared.withLock { $0.stopping = true }
        wakeup.signal()
        drained.wait()
        consumer = nil
        // The consumer thread has returned, so its state is ours to read and the
        // file is ours to close.
        file = nil
        return firstError
    }

    private func consume() {
        while true {
            wakeup.wait()
            while true {
                let (pending, stopping) = shared.withLock { ($0.pending, $0.stopping) }
                guard pending > 0 else {
                    if stopping {
                        drained.signal()
                        return
                    }
                    break
                }
                do {
                    try file?.write(from: slots[readIndex])
                } catch {
                    if firstError == nil { firstError = error }
                }
                readIndex = (readIndex + 1) % AudioFileWriter.slotCount
                shared.withLock { $0.pending -= 1 }
            }
        }
    }
}

/// Notices the aggregate device dying or changing sample rate while a capture
/// is running. It does not try to recover: it only makes sure the recording is
/// not silently presented as sound.
private final class DeviceWatcher {
    private struct Shared {
        var changed = false
        var stopping = false
    }

    private let device: AudioObjectID
    private let baselineSampleRate: Double
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let queue = DispatchQueue(label: "io.keyban.whiteboard-recorder.device-watch")
    private var listener: AudioObjectPropertyListenerBlock?

    private static let selectors: [AudioObjectPropertySelector] = [
        kAudioDevicePropertyNominalSampleRate,
        kAudioDevicePropertyDeviceIsAlive,
        kAudioDevicePropertyDeviceIsRunning
    ]

    init(device: AudioObjectID, baselineSampleRate: Double) {
        self.device = device
        self.baselineSampleRate = baselineSampleRate
    }

    var didChange: Bool { shared.withLock { $0.changed } }

    /// Selectors actually accepted by CoreAudio, so `stop()` unregisters exactly
    /// what was registered.
    private var registered: [AudioObjectPropertySelector] = []

    /// True only when every selector was accepted. A partial registration still
    /// watches what it can, but it is not the full coverage the recording is
    /// trusted on, so it counts as unarmed and the user is told.
    private(set) var isArmed = false

    @discardableResult
    func start() -> Bool {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.evaluate() }
        listener = block
        for selector in DeviceWatcher.selectors {
            var address = DeviceWatcher.address(for: selector)
            // Ignoring this status used to make the watcher silently optional:
            // nothing would ever fire, `didChange` would stay false, and a
            // truncated recording would be shipped as if it were sound.
            let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
            if status == noErr { registered.append(selector) }
        }
        isArmed = registered.count == DeviceWatcher.selectors.count
        return isArmed
    }

    func stop() {
        guard let listener else { return }
        // Set first: a notification already in flight on the queue must not be
        // mistaken for the device failing when it is only us shutting down.
        shared.withLock { $0.stopping = true }
        for selector in registered {
            var address = DeviceWatcher.address(for: selector)
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, listener)
        }
        registered = []
        self.listener = nil
    }

    private func evaluate() {
        guard !shared.withLock({ $0.stopping }) else { return }

        var failed = false
        if abs(AudioDeviceProperties.nominalSampleRate(of: device) - baselineSampleRate) > 0.5 {
            failed = true
        }
        if AudioDeviceProperties.flag(kAudioDevicePropertyDeviceIsAlive, of: device) == 0 {
            failed = true
        }
        if AudioDeviceProperties.flag(kAudioDevicePropertyDeviceIsRunning, of: device) == 0 {
            failed = true
        }
        guard failed else { return }
        shared.withLock { $0.changed = true }
    }

    private static func address(for selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

/// Counters written only by the IO thread and read only once the IO proc has
/// been destroyed, so they need no locking. The arrays are sized up front so
/// that recording into them never allocates.
private final class CaptureStats {
    private static let maxSources = 8

    var bufferChannelCounts = [Int](repeating: 0, count: CaptureStats.maxSources)
    var sourcePeaks = [Float](repeating: 0, count: CaptureStats.maxSources)
    var sourceCount = 0
    var framesCaptured: Int64 = 0
    var callbackCount = 0
    var droppedBuffers = 0
}
