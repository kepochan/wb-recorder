import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

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

    public var duration: TimeInterval {
        sampleRate > 0 ? TimeInterval(framesCaptured) / sampleRate : 0
    }

    public var description: String {
        """
        systemAudioAvailable=\(systemAudioAvailable) sampleRate=\(sampleRate) \
        buffers=\(bufferChannelCounts.count) channels=\(bufferChannelCounts) \
        peaks=\(sourcePeaks) frames=\(framesCaptured) callbacks=\(callbackCount) \
        duration=\(String(format: "%.3f", duration))s
        """
    }
}

/// Microphone and system audio captured through a single private aggregate
/// device, so both sources share one clock and need no drift correction.
public final class CoreAudioCapture: AudioCapture {
    public private(set) var isSystemAudioAvailable = false
    /// Populated by `stop()`, once the IO proc can no longer be running.
    public private(set) var diagnostics: CaptureDiagnostics?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: AudioFileWriter?
    private var stats: CaptureStats?
    private var sampleRate: Double = 0
    private var outputURL: URL?

    public init() {}

    deinit {
        releaseCoreAudioObjects()
    }

    public func start() throws -> Date {
        guard outputURL == nil else {
            // Already running: refuse rather than orphan the current capture.
            throw CaptureError.aggregateDeviceFailed(kAudioHardwareIllegalOperationError)
        }
        guard let inputUID = Self.defaultInputDeviceUID() else { throw CaptureError.noInputDevice }

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
            let writer = try AudioFileWriter(format: format, url: url, settings: [
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
                CoreAudioCapture.mix(inputData, format: format, writer: writer, stats: stats)
            }
            guard status == noErr, let procID else {
                throw CaptureError.aggregateDeviceFailed(status == noErr ? kAudio_ParamError : status)
            }
            ioProcID = procID

            let startStatus = AudioDeviceStart(aggregateID, procID)
            guard startStatus == noErr else {
                throw CaptureError.aggregateDeviceFailed(startStatus)
            }
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
        teardown()
        return url
    }

    /// Releases every CoreAudio object and closes the file, in the only order
    /// that is safe: the IO proc first, so nothing can touch the writer after.
    private func teardown() {
        releaseCoreAudioObjects()

        if let stats {
            diagnostics = CaptureDiagnostics(
                systemAudioAvailable: isSystemAudioAvailable,
                sampleRate: sampleRate,
                bufferChannelCounts: stats.bufferChannelCounts,
                sourcePeaks: stats.sourcePeaks,
                framesCaptured: stats.framesCaptured,
                callbackCount: stats.callbackCount)
        }
        stats = nil

        // Let every queued buffer reach the encoder before closing the file.
        writer?.finish()
        writer = nil
        outputURL = nil
        sampleRate = 0
    }

    /// Safe to call twice, and safe to call from a failure path where only
    /// some of the objects exist.
    private func releaseCoreAudioObjects() {
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
    /// Runs on the real-time IO thread: it must not block, so the mixed buffer
    /// is handed to the writer queue instead of being encoded here.
    private static func mix(_ inputData: UnsafePointer<AudioBufferList>,
                            format: AVAudioFormat,
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
        guard frameCount > 0,
              let mixed = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(frameCount)),
              let destination = mixed.floatChannelData?[0] else { return }
        mixed.frameLength = AVAudioFrameCount(frameCount)
        destination.update(repeating: 0, count: frameCount)

        if stats.bufferChannelCounts.count != buffers.count {
            stats.bufferChannelCounts = buffers.map { Int($0.mNumberChannels) }
            stats.sourcePeaks = Array(repeating: 0, count: buffers.count)
        }

        for (index, buffer) in buffers.enumerated() {
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
            if index < stats.sourcePeaks.count {
                stats.sourcePeaks[index] = max(stats.sourcePeaks[index], peak)
            }
        }

        // Two sources summed can clip; clamp instead of distorting.
        for frame in 0..<frameCount {
            destination[frame] = max(-1, min(1, destination[frame]))
        }

        stats.framesCaptured += Int64(frameCount)
        stats.callbackCount += 1
        writer.enqueue(mixed)
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
}

// MARK: - Supporting types

/// Owns the output file. Every access to it happens on one serial queue, so
/// the real-time IO thread never touches the encoder.
private final class AudioFileWriter {
    let format: AVAudioFormat
    private let queue = DispatchQueue(label: "io.keyban.whiteboard-recorder.audio-writer")
    private var file: AVAudioFile?

    init(format: AVAudioFormat, url: URL, settings: [String: Any]) throws {
        self.format = format
        self.file = try AVAudioFile(forWriting: url, settings: settings)
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            try? file?.write(from: buffer)
        }
    }

    /// Drains what is already queued, then closes the file.
    func finish() {
        queue.sync { file = nil }
    }
}

/// Counters written only by the IO thread and read only once the IO proc has
/// been destroyed, so they need no locking.
private final class CaptureStats {
    var bufferChannelCounts: [Int] = []
    var sourcePeaks: [Float] = []
    var framesCaptured: Int64 = 0
    var callbackCount: Int = 0
}
