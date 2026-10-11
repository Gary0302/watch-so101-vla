// SFSpeechRecognizer-based Transcriber for the iPhone.
//
// SpeechAnalyzer (iOS 26+) is the newer API but is not in the iOS 18.2 SDK this
// code is compiled against today. It can be added behind the same Transcriber
// protocol once the Mac mini has the current Xcode.
//
// Info.plist (iPhone app): NSSpeechRecognitionUsageDescription.

#if os(iOS)
import Foundation
import Speech

public enum SpeechError: Error {
    case notAuthorized
    case recognizerUnavailable
}

public final class AppleSpeechTranscriber: Transcriber, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let contextualStrings: [String]

    public init?(localeIdentifier: String = "zh-TW", contextualStrings: [String] = defaultTaskPhrases) {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else { return nil }
        recognizer = r
        self.contextualStrings = contextualStrings
    }

    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    /// Whether audio stays on the device. Shown in the UI; cloud recognition is a privacy choice.
    public var isOnDevice: Bool { recognizer.supportsOnDeviceRecognition }

    public func transcribe(_ clip: AssembledClip) async throws -> String? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw SpeechError.notAuthorized }
        guard recognizer.isAvailable else { throw SpeechError.recognizerUnavailable }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(clip.clipId).m4a")
        try clip.audio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.contextualStrings = contextualStrings
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        return try await withCheckedThrowingContinuation { cont in
            let once = ResumeOnce()
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    once.run { cont.resume(throwing: error) }
                } else if let result, result.isFinal {
                    once.run { cont.resume(returning: result.bestTranscription.formattedString) }
                }
            }
        }
    }
}

/// The recognition callback can fire more than once; a continuation must resume exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
#endif
