import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Keeps touch ownership in UIKit so lifting the finger always ends a voice hold,
/// even when SwiftUI dismisses the keyboard or locks editing during recognition.
struct HoldToDictateTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let isInputLocked: Bool
    let onHoldBegan: () -> Void
    let onHoldEnded: () -> Void
    let onHoldCancelled: () -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.backgroundColor = .clear
        view.font = Self.inputFont
        view.textColor = UIColor(InkTheme.ink)
        view.tintColor = UIColor(InkTheme.ink)
        // Keep the former SwiftUI padding inside the touch surface, so pressing
        // the empty space above or below a line is also a voice hold.
        view.textContainerInset = UIEdgeInsets(top: 10, left: 4, bottom: 10, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.showsVerticalScrollIndicator = false
        view.returnKeyType = .send
        view.enablesReturnKeyAutomatically = true
        view.keyboardDismissMode = .interactive
        view.adjustsFontForContentSizeCategory = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "questionInput"
        view.delegate = context.coordinator
        context.coordinator.textView = view
        view.onWindowChanged = { [weak coordinator = context.coordinator] in
            coordinator?.applyFocus()
        }

        let hold = DictationHoldRecognizer(target: context.coordinator, action: #selector(Coordinator.handleHold(_:)))
        hold.minimumPressDuration = 0.08
        hold.allowableMovement = 10
        hold.cancelsTouchesInView = true
        hold.delegate = context.coordinator
        view.addGestureRecognizer(hold)
        context.coordinator.holdRecognizer = hold
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.isUpdatingView = true
        defer { coordinator.isUpdatingView = false }

        view.placeholder = placeholder
        view.accessibilityLabel = placeholder
        view.accessibilityHint = L10n.text("按住说话，松手结束。识别文字后仍需点发送。", "Hold to speak, then release to finish. Tap Send when you are ready.")
        view.accessibilityCustomActions = [UIAccessibilityCustomAction(
            name: isInputLocked ? L10n.text("结束语音输入", "Finish voice input") : L10n.text("开始语音输入", "Start voice input"),
            target: coordinator, selector: #selector(Coordinator.performVoiceAction)
        )]
        // Never replace marked text while an input method is composing it.
        // Transcription starts only after resigning first responder.
        if view.text != text, view.markedTextRange == nil {
            view.text = text
            let count = (text as NSString).length
            view.selectedRange = NSRange(location: count, length: 0)
            coordinator.caretOnNextFocus = !view.isFirstResponder && !text.isEmpty ? text : nil
            coordinator.queuedCaretRestore = nil
            view.invalidateIntrinsicContentSize()
        }
        view.updatePlaceholder()
        coordinator.applyFocus()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.composerSize(for: width)
    }

    static func dismantleUIView(_ view: ComposerTextView, coordinator: Coordinator) {
        view.onWindowChanged = nil
        view.delegate = nil
        if coordinator.holdStarted {
            coordinator.holdStarted = false
            coordinator.parent.onHoldCancelled()
        }
        view.resignFirstResponder()
    }

    private static var inputFont: UIFont {
        let font = UIFont.systemFont(ofSize: 16)
        return font.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 16) } ?? font
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: HoldToDictateTextInput
        weak var textView: ComposerTextView?
        weak var holdRecognizer: UILongPressGestureRecognizer?
        var isUpdatingView = false
        var holdStarted = false
        var caretOnNextFocus: String?
        var queuedCaretRestore: UUID?

        init(_ parent: HoldToDictateTextInput) { self.parent = parent }

        func applyFocus() {
            guard let textView else { return }
            let shouldFocus = parent.isFocused && !parent.isInputLocked
            // Suppress delegate-driven binding writes when focus changes originate
            // from updateUIView, which is already applying the same SwiftUI state.
            let wasUpdating = isUpdatingView
            isUpdatingView = true
            defer { isUpdatingView = wasUpdating }
            if shouldFocus {
                if textView.window != nil, !textView.isFirstResponder { textView.becomeFirstResponder() }
            } else if textView.isFirstResponder {
                textView.resignFirstResponder()
            }
        }

        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool { !parent.isInputLocked && !holdStarted }

        func textViewDidBeginEditing(_ textView: UITextView) {
            restoreCaretAfterFirstFocus(in: textView)
            guard !isUpdatingView else { return }
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            queuedCaretRestore = nil
            guard !isUpdatingView else { return }
            parent.isFocused = false
        }

        private func restoreCaretAfterFirstFocus(in textView: UITextView) {
            guard let expectedText = caretOnNextFocus else { return }
            caretOnNextFocus = nil
            let restoreID = UUID()
            queuedCaretRestore = restoreID
            let end = NSRange(location: (expectedText as NSString).length, length: 0)
            textView.selectedRange = end
            // UIKit's tap-to-edit interaction may update the selection after
            // didBeginEditing. Restore this external draft once that interaction
            // has finished, then leave all later taps free to position the caret.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView,
                      self.queuedCaretRestore == restoreID else { return }
                self.queuedCaretRestore = nil
                guard textView.isFirstResponder, !self.parent.isInputLocked,
                      !self.holdStarted, textView.text == expectedText else { return }
                textView.selectedRange = end
                textView.scrollRangeToVisible(end)
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            self.textView?.updatePlaceholder()
            textView.invalidateIntrinsicContentSize()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            guard !parent.isInputLocked else { return false }
            if replacement == "\n", textView.markedTextRange == nil {
                parent.onSubmit()
                return false
            }
            return true
        }

        @objc func handleHold(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                guard !parent.isInputLocked else { return }
                holdStarted = true
                queuedCaretRestore = nil
                // Resign before exposing the frozen draft to the speech service;
                // this also commits a keyboard input method's marked text.
                textView?.resignFirstResponder()
                if let textView, parent.text != textView.text { parent.text = textView.text }
                parent.isFocused = false
                parent.onHoldBegan()
            case .ended:
                guard holdStarted else { return }
                holdStarted = false
                parent.onHoldEnded()
            case .cancelled, .failed:
                guard holdStarted else { return }
                holdStarted = false
                parent.onHoldCancelled()
            default: break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            !parent.isInputLocked
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === holdRecognizer, let textView else { return false }
            // UITextInteraction exposes its gestures specifically for coordinating
            // failure requirements, without depending on UIKit's private classes.
            let editingGestures = textView.interactions.compactMap { $0 as? UITextInteraction }
                .flatMap(\.gesturesForFailureRequirements)
            if editingGestures.contains(where: { $0 === otherGestureRecognizer }) { return true }
            guard otherGestureRecognizer is UILongPressGestureRecognizer,
                  let otherView = otherGestureRecognizer.view else { return false }
            return otherView === textView || otherView.isDescendant(of: textView)
        }

        @objc func performVoiceAction() -> Bool {
            if parent.isInputLocked {
                holdStarted = false
                parent.onHoldEnded()
            } else {
                textView?.resignFirstResponder()
                if let textView, parent.text != textView.text { parent.text = textView.text }
                parent.isFocused = false
                parent.onHoldBegan()
            }
            return true
        }
    }

    final class DictationHoldRecognizer: UILongPressGestureRecognizer {
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
            let standardBehavior = super.canBePrevented(by: preventingGestureRecognizer)
            // Keyboard dismissal can reconfigure the system's editing gestures.
            // Once a voice hold owns the touch, keep it through the finger lift.
            if state == .began || state == .changed { return false }
            return standardBehavior
        }
    }

    final class ComposerTextView: UITextView {
        private let placeholderLabel = UILabel()
        var onWindowChanged: (() -> Void)?
        var placeholder: String = "" {
            didSet {
                placeholderLabel.text = placeholder
                setNeedsLayout()
            }
        }

        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            placeholderLabel.font = HoldToDictateTextInput.inputFont
            placeholderLabel.textColor = UIColor(InkTheme.secondary)
            placeholderLabel.numberOfLines = 1
            placeholderLabel.isUserInteractionEnabled = false
            placeholderLabel.isAccessibilityElement = false
            addSubview(placeholderLabel)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChanged?()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            placeholderLabel.frame = CGRect(x: textContainerInset.left, y: textContainerInset.top,
                                            width: max(0, bounds.width - textContainerInset.left - textContainerInset.right),
                                            height: font?.lineHeight ?? 20)
            updatePlaceholder()
        }

        func updatePlaceholder() { placeholderLabel.isHidden = !text.isEmpty }

        func composerSize(for width: CGFloat) -> CGSize {
            let lineHeight = font?.lineHeight ?? 20
            let verticalInsets = textContainerInset.top + textContainerInset.bottom
            let minimum = ceil(lineHeight + verticalInsets)
            let maximum = ceil(lineHeight * 5 + verticalInsets)
            let naturalHeight = super.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            let shouldScroll = naturalHeight > maximum + 1
            if isScrollEnabled != shouldScroll { isScrollEnabled = shouldScroll }
            return CGSize(width: width, height: min(maximum, max(minimum, ceil(naturalHeight))))
        }

        override var intrinsicContentSize: CGSize {
            guard bounds.width > 0 else {
                return CGSize(width: UIView.noIntrinsicMetric,
                              height: ceil((font?.lineHeight ?? 20) + textContainerInset.top + textContainerInset.bottom))
            }
            return CGSize(width: UIView.noIntrinsicMetric, height: composerSize(for: bounds.width).height)
        }
    }
}
