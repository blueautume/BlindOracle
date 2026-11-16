import XCTest
@testable import BlindOracle

@MainActor final class SpeechInputControllerTests: XCTestCase {
    func testAuthorizationCompletesWithoutStartingEvenIfFingerIsStillDown() async throws {
        let backend = FakeSpeechInputBackend()
        backend.permissions = .init(microphone: .undetermined, speech: .undetermined)
        let controller = SpeechInputController(backend: backend)
        controller.begin { _ in XCTFail("Authorization must never transcribe") }
        XCTAssertEqual(controller.phase, .authorizing)
        try await waitUntil { backend.permissionRequests == 1 }
        backend.completePermission(granted: true)
        try await waitUntil { controller.phase == .idle }
        XCTAssertEqual(backend.starts, 0)
        XCTAssertNotNil(controller.notice)

        controller.begin { _ in }
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertEqual(backend.starts, 1)
        controller.cancel()
    }

    func testReleaseDuringAuthorizationCannotStartCaptureLater() async throws {
        let backend = FakeSpeechInputBackend()
        backend.permissions = .init(microphone: .undetermined, speech: .undetermined)
        let controller = SpeechInputController(backend: backend)
        controller.begin { _ in XCTFail("Released authorization cannot transcribe") }
        try await waitUntil { backend.permissionRequests == 1 }
        controller.finish()
        backend.completePermission(granted: true)
        try await waitUntil { controller.phase == .idle }
        XCTAssertEqual(backend.starts, 0)
    }

    func testCancelBeforePermissionTaskRunsDoesNotRequestPermission() async throws {
        let backend = FakeSpeechInputBackend()
        backend.permissions = .init(microphone: .undetermined, speech: .undetermined)
        let controller = SpeechInputController(backend: backend)
        controller.begin { _ in XCTFail("Cancelled session cannot transcribe") }
        controller.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(backend.permissionRequests, 0)
        XCTAssertEqual(backend.starts, 0)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testCancelledAuthorizationDoesNotChangeNoticeOrNewSession() async throws {
        let backend = FakeSpeechInputBackend()
        backend.permissions = .init(microphone: .undetermined, speech: .undetermined)
        let controller = SpeechInputController(backend: backend)
        controller.begin { _ in XCTFail("Cancelled authorization cannot transcribe") }
        try await waitUntil { backend.permissionRequests == 1 }
        controller.cancel()
        backend.completePermission(granted: true)
        controller.begin { _ in }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertNil(controller.notice)
        XCTAssertEqual(backend.starts, 1)
        controller.cancel()
    }

    func testRepeatedHoldWhileAuthorizingDoesNotDuplicatePermissionRequests() async throws {
        let backend = FakeSpeechInputBackend()
        backend.permissions = .init(microphone: .undetermined, speech: .undetermined)
        let controller = SpeechInputController(backend: backend)
        controller.begin { _ in }
        try await waitUntil { backend.permissionRequests == 1 }
        controller.begin { _ in }
        XCTAssertEqual(backend.permissionRequests, 1)
        backend.completePermission(granted: true)
        try await waitUntil { controller.phase == .idle }
        XCTAssertEqual(backend.starts, 0)
    }

    func testDeniedPermissionPreservesDraftAndDoesNotStartBackend() {
        let backend = FakeSpeechInputBackend()
        backend.permissions = .init(microphone: .denied, speech: .authorized)
        let controller = SpeechInputController(backend: backend)
        var draft = "原有文字"
        controller.begin { draft = $0 }
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(draft, "原有文字")
        XCTAssertEqual(backend.starts, 0)
        XCTAssertNotNil(controller.notice)
    }

    func testHypothesesReplaceCurrentUtteranceAndFinalArrivesAfterRelease() {
        let backend = FakeSpeechInputBackend()
        let controller = SpeechInputController(backend: backend)
        var draft = "原文："
        controller.begin { draft = "原文：" + $0 }
        backend.emit(.transcript("我想问", isFinal: false))
        backend.emit(.transcript("我想问一下工作", isFinal: false))
        XCTAssertEqual(draft, "原文：我想问一下工作")
        controller.finish()
        XCTAssertEqual(controller.phase, .finishing)
        XCTAssertEqual(backend.audioEnds, 1)
        XCTAssertFalse(backend.capturing)
        XCTAssertTrue(backend.recognitionActive)

        backend.emit(.transcript("我想问一下工作的事情。", isFinal: true))
        XCTAssertEqual(draft, "原文：我想问一下工作的事情。")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(backend.recognitionActive)
        XCTAssertNil(controller.notice)
    }

    func testSynchronousFinalDuringEndAudioCompletesWithoutWaitingForTimeout() {
        let backend = FakeSpeechInputBackend()
        backend.finalOnEnd = "说完了。"
        let controller = SpeechInputController(backend: backend)
        var text = ""
        controller.begin { text = $0 }
        controller.finish()
        XCTAssertEqual(text, "说完了。")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(backend.recognitionActive)
    }

    func testFinishingTimeoutKeepsPartialTextAndReleasesBackend() async throws {
        let backend = FakeSpeechInputBackend()
        let controller = SpeechInputController(backend: backend, finishTimeout: .milliseconds(15))
        var draft = ""
        controller.begin { draft = $0 }
        backend.emit(.transcript("已听到的话", isFinal: false))
        controller.finish()
        try await waitUntil { controller.phase == .idle }
        XCTAssertEqual(draft, "已听到的话")
        XCTAssertFalse(backend.capturing)
        XCTAssertFalse(backend.recognitionActive)
        XCTAssertNil(controller.notice)
    }

    func testEmptyRecognitionTimeoutPreservesExistingDraft() async throws {
        let backend = FakeSpeechInputBackend()
        let controller = SpeechInputController(backend: backend, finishTimeout: .milliseconds(15))
        var draft = "原有草稿"
        controller.begin { draft = $0 }
        controller.finish()
        try await waitUntil { controller.phase == .idle }
        XCTAssertEqual(draft, "原有草稿")
        XCTAssertNotNil(controller.notice)
    }

    func testLateResultsCannotRestoreSubmittedDraftOrEnterNewHold() {
        let backend = FakeSpeechInputBackend()
        let controller = SpeechInputController(backend: backend)
        var draft = ""
        controller.begin { draft = $0 }
        let oldHandler = backend.handlers[0]
        backend.emit(.transcript("第一轮", isFinal: false))
        controller.cancel()
        draft = ""
        oldHandler(.transcript("第一轮迟到的结果", isFinal: true))
        XCTAssertEqual(draft, "")

        controller.begin { draft = "新草稿：" + $0 }
        oldHandler(.failure(.interrupted))
        oldHandler(.transcript("第一轮又来的结果", isFinal: false))
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertEqual(draft, "")
        backend.emit(.transcript("第二轮", isFinal: true))
        XCTAssertEqual(draft, "新草稿：第二轮")
    }

    func testNewHoldWhileFinishingInvalidatesOldFinalAndTimeout() async throws {
        let backend = FakeSpeechInputBackend()
        let controller = SpeechInputController(backend: backend, finishTimeout: .milliseconds(15))
        var draft = ""
        controller.begin { draft = $0 }
        let oldHandler = backend.handlers[0]
        controller.finish()
        controller.begin { draft = "第二轮：" + $0 }
        oldHandler(.transcript("旧句尾", isFinal: true))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertTrue(backend.capturing)
        XCTAssertEqual(draft, "")
        backend.emit(.transcript("当前内容", isFinal: true))
        XCTAssertEqual(draft, "第二轮：当前内容")
    }

    func testInterruptionStopsCaptureAndPreservesRecognizedText() {
        let backend = FakeSpeechInputBackend()
        let controller = SpeechInputController(backend: backend)
        var draft = ""
        controller.begin { draft = $0 }
        backend.emit(.transcript("中断前的话", isFinal: false))
        backend.emit(.failure(.interrupted))
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(draft, "中断前的话")
        XCTAssertFalse(backend.capturing)
        XCTAssertFalse(backend.recognitionActive)
        XCTAssertNotNil(controller.notice)
    }

    func testStartFailureReleasesResourcesAndAllowsAnotherHold() {
        let backend = FakeSpeechInputBackend()
        backend.startError = SpeechInputFailure.microphoneUnavailable
        let controller = SpeechInputController(backend: backend)
        controller.begin { _ in XCTFail("Failed startup cannot transcribe") }
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(backend.capturing)
        XCTAssertFalse(backend.recognitionActive)
        XCTAssertNotNil(controller.notice)
        backend.startError = nil
        controller.begin { _ in }
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertNil(controller.notice)
        controller.cancel()
    }

    func testLanguageIsChosenForEachHoldAndLongRecordingIsBounded() async throws {
        let backend = FakeSpeechInputBackend()
        let controller = SpeechInputController(backend: backend, recordingLimit: .milliseconds(15))
        AppLanguage.$override.withValue(.english) { controller.begin { _ in } }
        XCTAssertEqual(backend.locales.last?.identifier, "en-US")
        try await waitUntil { controller.phase == .finishing }
        XCTAssertFalse(backend.capturing)
        backend.emit(.transcript("A question.", isFinal: true))
        AppLanguage.$override.withValue(.simplifiedChinese) { controller.begin { _ in } }
        XCTAssertEqual(backend.locales.last?.identifier, "zh-CN")
        controller.cancel()
    }

    private func waitUntil(_ predicate: @escaping () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for speech input state", file: file, line: line)
    }
}

@MainActor private final class FakeSpeechInputBackend: SpeechInputBackend {
    var permissions = SpeechInputPermissions(microphone: .authorized, speech: .authorized)
    var permissionRequests = 0
    var starts = 0
    var audioEnds = 0
    var capturing = false
    var recognitionActive = false
    var startError: Error?
    var finalOnEnd: String?
    var locales: [Locale] = []
    var handlers: [(SpeechInputEvent) -> Void] = []
    private var permissionContinuation: CheckedContinuation<SpeechInputPermissions, Never>?

    func requestPermissions() async -> SpeechInputPermissions {
        permissionRequests += 1
        return await withCheckedContinuation { permissionContinuation = $0 }
    }

    func completePermission(granted: Bool) {
        permissions = .init(microphone: granted ? .authorized : .denied, speech: granted ? .authorized : .denied)
        permissionContinuation?.resume(returning: permissions)
        permissionContinuation = nil
    }

    func start(locale: Locale, onEvent: @escaping (SpeechInputEvent) -> Void) throws {
        starts += 1
        capturing = true
        recognitionActive = true
        if let startError { throw startError }
        locales.append(locale)
        handlers.append(onEvent)
    }

    func endAudio() {
        audioEnds += 1
        capturing = false
        if let finalOnEnd { emit(.transcript(finalOnEnd, isFinal: true)) }
    }

    func cancel() {
        capturing = false
        recognitionActive = false
    }

    func emit(_ event: SpeechInputEvent) { handlers.last?(event) }
}
