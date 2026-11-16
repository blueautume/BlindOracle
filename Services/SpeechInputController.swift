import AVFoundation
import Combine
import Foundation
import Speech
import UIKit

enum SpeechInputPermission {
    case undetermined, authorized, denied
}

struct SpeechInputPermissions {
    var microphone: SpeechInputPermission
    var speech: SpeechInputPermission

    var isAuthorized: Bool { microphone == .authorized && speech == .authorized }
    var needsRequest: Bool { microphone == .undetermined || speech == .undetermined }
}

enum SpeechInputFailure: Error {
    case unavailable, microphoneUnavailable, interrupted, recognitionFailed
}

enum SpeechInputEvent {
    /// Speech returns the complete current hypothesis, including revisions to earlier words.
    case transcript(String, isFinal: Bool)
    case failure(SpeechInputFailure)
}

@MainActor protocol SpeechInputBackend: AnyObject {
    var permissions: SpeechInputPermissions { get }
    func requestPermissions() async -> SpeechInputPermissions
    func start(locale: Locale, onEvent: @escaping (SpeechInputEvent) -> Void) throws
    func endAudio()
    func cancel()
}

/// A hold owns one session. Releasing ends audio immediately, while allowing the
/// recognizer a short, bounded opportunity to deliver the end of the sentence.
@MainActor final class SpeechInputController: ObservableObject {
    enum Phase {
        case idle, authorizing, listening, finishing

        var isActive: Bool { self != .idle }
        var isListening: Bool { self == .listening }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var notice: String?

    var isActive: Bool { phase.isActive }
    var isListening: Bool { phase.isListening }

    private let backend: any SpeechInputBackend
    private let finishTimeout: Duration
    private let recordingLimit: Duration
    private var sessionID: UUID?
    private var transcriptHandler: ((String) -> Void)?
    private var latestTranscript = ""
    private var permissionTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var language: AppLanguage = .current

    init(backend: (any SpeechInputBackend)? = nil,
         finishTimeout: Duration = .seconds(2), recordingLimit: Duration = .seconds(59)) {
        self.backend = backend ?? AppleSpeechInputBackend()
        self.finishTimeout = finishTimeout
        self.recordingLimit = recordingLimit
    }

    func begin(onTranscript: @escaping (String) -> Void) {
        // An outstanding system permission prompt cannot be restarted by a second hold.
        guard phase != .authorizing else { return }
        cancel()
        notice = nil
        language = .current
        let id = UUID()
        sessionID = id
        transcriptHandler = onTranscript
        latestTranscript = ""
        let permissions = backend.permissions
        if permissions.needsRequest {
            phase = .authorizing
            permissionTask = Task { @MainActor [weak self] in
                guard let self, self.sessionID == id, !Task.isCancelled else { return }
                let result = await self.backend.requestPermissions()
                guard self.sessionID == id, !Task.isCancelled else { return }
                self.notice = result.isAuthorized
                    ? L10n.text("已允许语音输入，请再次按住输入框说话。", "Voice input is ready. Hold the input again to speak.", language: self.language)
                    : self.permissionNotice(result)
                self.complete(id: id)
            }
            return
        }
        guard permissions.isAuthorized else {
            notice = permissionNotice(permissions)
            complete(id: id)
            return
        }

        phase = .listening
        do {
            let locale = Locale(identifier: language.isEnglish ? "en-US" : "zh-CN")
            try backend.start(locale: locale) { [weak self] event in
                self?.receive(event, id: id)
            }
            guard sessionID == id, phase == .listening else { return }
            recordingTask = Task { @MainActor [weak self, recordingLimit] in
                do { try await Task.sleep(for: recordingLimit) } catch { return }
                guard let self, self.sessionID == id, self.phase == .listening else { return }
                self.notice = L10n.text("本次语音输入已结束，文字已保留。", "This voice input has ended. Your text is kept.", language: self.language)
                self.finish()
            }
        } catch {
            notice = failureNotice((error as? SpeechInputFailure) ?? .microphoneUnavailable)
            complete(id: id)
        }
    }

    func finish() {
        // Permission completion intentionally never starts capture, even if the
        // original finger is still down. A new deliberate hold is required.
        guard phase == .listening, let id = sessionID else { return }
        recordingTask?.cancel()
        recordingTask = nil
        phase = .finishing
        backend.endAudio()
        // A backend can produce its final result synchronously from endAudio().
        guard sessionID == id, phase == .finishing else { return }
        finishTask = Task { @MainActor [weak self, finishTimeout] in
            do { try await Task.sleep(for: finishTimeout) } catch { return }
            guard let self, self.sessionID == id, self.phase == .finishing else { return }
            if self.latestTranscript.isEmpty {
                self.notice = L10n.text("没有听清，请按住输入框再说一次。", "No speech was recognized. Hold the input and try again.", language: self.language)
            }
            self.complete(id: id)
        }
    }

    /// Used when leaving a conversation or submitting. Invalidates the callback
    /// before cancelling the backend, so cancellation results cannot restore a draft.
    func cancel() {
        sessionID = nil
        transcriptHandler = nil
        permissionTask?.cancel()
        permissionTask = nil
        finishTask?.cancel()
        finishTask = nil
        recordingTask?.cancel()
        recordingTask = nil
        backend.cancel()
        phase = .idle
    }

    private func receive(_ event: SpeechInputEvent, id: UUID) {
        guard sessionID == id, phase == .listening || phase == .finishing else { return }
        switch event {
        case .transcript(let text, let isFinal):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                latestTranscript = text
                transcriptHandler?(text)
            }
            guard sessionID == id else { return }
            if isFinal {
                if latestTranscript.isEmpty {
                    notice = L10n.text("没有听清，请按住输入框再说一次。", "No speech was recognized. Hold the input and try again.", language: language)
                }
                complete(id: id)
            }
        case .failure(let failure):
            // A quiet/short utterance can end with an error after useful partial
            // results. Keep those words and avoid showing a spurious failure.
            if failure == .interrupted || latestTranscript.isEmpty || phase == .listening {
                notice = failureNotice(failure)
            }
            complete(id: id)
        }
    }

    private func complete(id: UUID) {
        guard sessionID == id else { return }
        cancel()
    }

    private func permissionNotice(_ permissions: SpeechInputPermissions) -> String {
        if permissions.microphone == .denied {
            return L10n.text("请在系统设置中允许“瞎子”使用麦克风，再按住输入框说话。", "Allow microphone access for BlindOracle in Settings, then hold the input to speak.", language: language)
        }
        return L10n.text("请在系统设置中允许“瞎子”使用语音识别，再按住输入框说话。", "Allow speech recognition for BlindOracle in Settings, then hold the input to speak.", language: language)
    }

    private func failureNotice(_ failure: SpeechInputFailure) -> String {
        switch failure {
        case .unavailable:
            return L10n.text("语音识别暂不可用，请检查网络后重试，或继续打字。", "Speech recognition is unavailable. Check your connection and try again, or keep typing.", language: language)
        case .microphoneUnavailable:
            return L10n.text("麦克风暂不可用，请稍后再试。已有文字已保留。", "The microphone is unavailable. Try again shortly. Your existing text is kept.", language: language)
        case .interrupted:
            return L10n.text("语音输入已中断，已识别的文字已保留。", "Voice input was interrupted. Recognized text is kept.", language: language)
        case .recognitionFailed:
            return L10n.text("这次没有识别完成，请再试一次。已有文字已保留。", "Speech recognition could not finish. Try again. Your existing text is kept.", language: language)
        }
    }

    deinit {
        permissionTask?.cancel()
        finishTask?.cancel()
        recordingTask?.cancel()
    }
}

@MainActor final class AppleSpeechInputBackend: SpeechInputBackend {
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var inputTapInstalled = false
    private var audioSessionActive = false
    private var observers: [NSObjectProtocol] = []

    var permissions: SpeechInputPermissions {
        let microphone: SpeechInputPermission
        switch AVAudioApplication.shared.recordPermission {
        case .granted: microphone = .authorized
        case .undetermined: microphone = .undetermined
        default: microphone = .denied
        }
        let speech: SpeechInputPermission
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = .authorized
        case .notDetermined: speech = .undetermined
        default: speech = .denied
        }
        return SpeechInputPermissions(microphone: microphone, speech: speech)
    }

    func requestPermissions() async -> SpeechInputPermissions {
        if permissions.speech == .undetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        guard !Task.isCancelled else { return permissions }
        if permissions.speech == .authorized, permissions.microphone == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
        return permissions
    }

    func start(locale: Locale, onEvent: @escaping (SpeechInputEvent) -> Void) throws {
        cancel()
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechInputFailure.unavailable
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        // On-device support varies by device/language. Native recognition may
        // use Apple's service when an on-device recognizer is unavailable.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true)
            audioSessionActive = true
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw SpeechInputFailure.microphoneUnavailable
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            inputTapInstalled = true
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let hasError = error != nil
                Task { @MainActor in
                    if let text { onEvent(.transcript(text, isFinal: isFinal)) }
                    if hasError && !isFinal { onEvent(.failure(.recognitionFailed)) }
                }
            }
            installObservers(onEvent: onEvent)
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            cancel()
            throw error
        }
    }

    func endAudio() {
        stopMicrophone()
        request?.endAudio()
    }

    func cancel() {
        stopMicrophone()
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognizer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func stopMicrophone() {
        audioEngine.stop()
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
    }

    private func installObservers(onEvent: @escaping (SpeechInputEvent) -> Void) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in onEvent(.failure(.interrupted)) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor in onEvent(.failure(.interrupted)) }
        })
        for name in [AVAudioSession.mediaServicesWereResetNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in onEvent(.failure(.interrupted)) }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        audioEngine.stop()
        if inputTapInstalled { audioEngine.inputNode.removeTap(onBus: 0) }
        recognitionTask?.cancel()
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
