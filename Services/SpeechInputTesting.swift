import Foundation

extension SpeechInputController {
    @MainActor static func forChat() -> SpeechInputController {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing-local"), arguments.contains("--ui-testing-speech-input") {
            return SpeechInputController(backend: SpeechInputUITestBackend())
        }
        #endif
        return SpeechInputController()
    }
}

#if DEBUG
/// Closed UI fixture: no permission prompts, microphone or network access.
@MainActor private final class SpeechInputUITestBackend: SpeechInputBackend {
    var permissions: SpeechInputPermissions { .init(microphone: .authorized, speech: .authorized) }
    private var onEvent: ((SpeechInputEvent) -> Void)?
    private var partial: Task<Void, Never>?

    func requestPermissions() async -> SpeechInputPermissions { permissions }

    func start(locale: Locale, onEvent: @escaping (SpeechInputEvent) -> Void) throws {
        self.onEvent = onEvent
        partial = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            self?.onEvent?(.transcript("今天想聊聊", isFinal: false))
        }
    }

    func endAudio() {
        partial?.cancel(); partial = nil
        onEvent?(.transcript("今天想聊聊工作", isFinal: true))
    }

    func cancel() {
        partial?.cancel(); partial = nil
        onEvent = nil
    }
}
#endif
