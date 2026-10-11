// Watch microphone capture for one voice window (SPEC §5.3).
//
// Records inside our own foreground app with AVAudioRecorder, so no system
// dictation UI covers the Primary Action button. Whether this works from a
// Double Tap-driven flow on a real Series 11 is still the §14 VERIFY spike.
//
// Info.plist (Watch app): NSMicrophoneUsageDescription.

#if os(watchOS)
import AVFoundation
import Foundation

public enum RecorderError: Error {
    case permissionDenied
    case couldNotStart
}

public final class WatchClipRecorder: NSObject, AVAudioRecorderDelegate {
    /// Called on the main queue with the clip bytes, or nil if recording failed.
    public var onFinished: ((_ clipId: String, _ audio: Data?) -> Void)?

    private var recorder: AVAudioRecorder?
    private var clipId: String?

    public static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    public func start(clipId: String, maxDuration: TimeInterval) throws {
        guard AVAudioApplication.shared.recordPermission == .granted else { throw RecorderError.permissionDenied }
        discard()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(clipId).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,  // ~20 KB for 5 s: one or two WCSession messages
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.delegate = self
        guard r.record(forDuration: maxDuration) else { throw RecorderError.couldNotStart }
        recorder = r
        self.clipId = clipId
    }

    /// Finish early; the clip is still delivered through onFinished.
    public func stop() {
        recorder?.stop()
    }

    /// Stop and delete without delivering anything.
    public func discard() {
        guard let r = recorder else { return }
        r.delegate = nil
        r.stop()
        r.deleteRecording()
        recorder = nil
        clipId = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    public func audioRecorderDidFinishRecording(_ r: AVAudioRecorder, successfully flag: Bool) {
        let audio = flag ? try? Data(contentsOf: r.url) : nil
        let id = clipId ?? ""
        r.deleteRecording()
        recorder = nil
        clipId = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        DispatchQueue.main.async { self.onFinished?(id, audio) }
    }
}
#endif
