import Cocoa

@MainActor
final class TranscriptionView: NSView {
    private let statusLabel = NSTextField.label("", font: .systemFont(ofSize: 13, weight: .medium))
    private let progressIndicator = NSProgressIndicator()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    private(set) var finalText = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
        setPlaceholder()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentText: String {
        textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func update(state: VoxTranscriptionState) {
        switch state {
        case .idle:
            finalText = ""
            setPlaceholder()
            hideProgress()
        case .extractingAudio, .loadingModel, .preparingAudio, .refining:
            showIndeterminate(state.text)
        case .downloadingModel(let progress):
            showProgress("Downloading model...", progress: progress)
        case .transcribing(let progress, let partialText):
            showProgress("Transcribing...", progress: progress)
            if !partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setPlainText(partialText)
            }
        case .recording(let confirmedText, let pendingText, let duration, let isPaused, _):
            statusLabel.stringValue = "\(isPaused ? "Paused" : "Recording")... \(VoxTranscriptionState.formatDuration(duration))"
            statusLabel.textColor = .labelColor
            hideProgressIndicatorOnly()
            setRecordingText(confirmed: confirmedText, pending: pendingText)
        case .diarizing(let progress):
            showProgress("Identifying speakers...", progress: progress)
        case .completed(let text):
            hideProgress()
            finalText = text
            setPlainText(text.isEmpty ? "No speech was detected." : text)
        case .error(let message):
            hideProgressIndicatorOnly()
            statusLabel.stringValue = message
            statusLabel.textColor = .systemRed
        }
    }

    func copyAll() {
        let text = currentText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func setup() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.pinEdges(to: self)

        let progressRow = NSStackView()
        progressRow.orientation = .horizontal
        progressRow.spacing = 10
        progressRow.alignment = .centerY
        progressRow.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.controlSize = .small
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressRow.addArrangedSubview(statusLabel)
        progressRow.addArrangedSubview(progressIndicator)
        stack.addArrangedSubview(progressRow)

        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        stack.addArrangedSubview(scrollView)

        NSLayoutConstraint.activate([
            progressIndicator.widthAnchor.constraint(equalToConstant: 180),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
    }

    private func setPlaceholder() {
        statusLabel.stringValue = ""
        statusLabel.textColor = .labelColor
        setPlainText("Drop an audio or video file, or switch to Recording to start live transcription.")
        textView.textColor = .secondaryLabelColor
    }

    private func setPlainText(_ text: String) {
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor
            ]
        ))
        scrollToBottom()
    }

    private func setRecordingText(confirmed: String, pending: String) {
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(
            string: confirmed,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor
            ]
        ))
        if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if attributed.length > 0 {
                attributed.append(NSAttributedString(string: "\n\n"))
            }
            attributed.append(NSAttributedString(
                string: pending,
                attributes: [
                    .font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 14), toHaveTrait: .italicFontMask),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
        }
        textView.textStorage?.setAttributedString(attributed)
        scrollToBottom()
    }

    private func showProgress(_ title: String, progress: Double) {
        statusLabel.stringValue = "\(title) \(Int(progress * 100))%"
        statusLabel.textColor = .labelColor
        progressIndicator.isHidden = false
        progressIndicator.isIndeterminate = false
        progressIndicator.doubleValue = min(1, max(0, progress))
    }

    private func showIndeterminate(_ title: String) {
        statusLabel.stringValue = title
        statusLabel.textColor = .labelColor
        progressIndicator.isHidden = false
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
    }

    private func hideProgress() {
        statusLabel.stringValue = ""
        hideProgressIndicatorOnly()
    }

    private func hideProgressIndicatorOnly() {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
    }

    private func scrollToBottom() {
        guard let textStorage = textView.textStorage else { return }
        textView.scrollRangeToVisible(NSRange(location: textStorage.length, length: 0))
    }
}
