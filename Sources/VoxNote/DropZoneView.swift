import Cocoa

@MainActor
final class DropZoneView: NSView {
    enum Mode {
        case file
        case recording
    }

    var onChooseFile: (() -> Void)?
    var onFileDropped: ((URL) -> Void)?
    var onRecordToggle: (() -> Void)?

    private let segmentedControl = NSSegmentedControl(labels: ["File", "Recording"], trackingMode: .selectOne, target: nil, action: nil)
    private let fileContent = NSStackView()
    private let recordContent = NSStackView()
    private let titleLabel = NSTextField.label("Drop audio/video file, or click to choose", font: .systemFont(ofSize: 16, weight: .medium))
    private let subtitleLabel = NSTextField.label("MP3, WAV, M4A, FLAC, MP4, MOV, MKV, AVI, WEBM", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let selectedFileLabel = NSTextField.label("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let recordButton = NSButton.rounded(title: "Start Recording", target: nil, action: nil)
    private let durationLabel = NSTextField.label("00:00", font: .monospacedDigitSystemFont(ofSize: 13, weight: .medium), color: .secondaryLabelColor)

    private(set) var mode: Mode = .file
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1.2
        let dash: [CGFloat] = [7, 5]
        path.setLineDash(dash, count: dash.count, phase: 0)
        path.stroke()
    }

    func setSelectedFileName(_ name: String?) {
        selectedFileLabel.stringValue = name.map { "Selected: \($0)" } ?? ""
        selectedFileLabel.isHidden = name == nil
    }

    func updateRecordingState(isRecording: Bool, duration: TimeInterval) {
        self.isRecording = isRecording
        recordButton.title = isRecording ? "Stop Recording" : "Start Recording"
        durationLabel.stringValue = isRecording ? VoxTranscriptionState.formatDuration(duration) : "00:00"
        durationLabel.textColor = isRecording ? .systemRed : .secondaryLabelColor
    }

    func setBusy(_ busy: Bool) {
        segmentedControl.isEnabled = !busy || isRecording
        recordButton.isEnabled = !busy || isRecording
    }

    private func setup() {
        let click = NSClickGestureRecognizer(target: self, action: #selector(didClickDropZone))
        addGestureRecognizer(click)

        segmentedControl.selectedSegment = 0
        segmentedControl.target = self
        segmentedControl.action = #selector(modeChanged)
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(segmentedControl)

        fileContent.orientation = .vertical
        fileContent.alignment = .centerX
        fileContent.spacing = 6
        fileContent.translatesAutoresizingMaskIntoConstraints = false
        fileContent.addArrangedSubview(titleLabel)
        fileContent.addArrangedSubview(subtitleLabel)
        fileContent.addArrangedSubview(selectedFileLabel)
        selectedFileLabel.isHidden = true
        addSubview(fileContent)

        recordContent.orientation = .vertical
        recordContent.alignment = .centerX
        recordContent.spacing = 8
        recordContent.translatesAutoresizingMaskIntoConstraints = false
        recordButton.target = self
        recordButton.action = #selector(recordButtonClicked)
        recordContent.addArrangedSubview(recordButton)
        recordContent.addArrangedSubview(durationLabel)
        addSubview(recordContent)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 112),
            segmentedControl.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            segmentedControl.centerXAnchor.constraint(equalTo: centerXAnchor),
            segmentedControl.widthAnchor.constraint(equalToConstant: 220),

            fileContent.centerXAnchor.constraint(equalTo: centerXAnchor),
            fileContent.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 16),
            fileContent.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            fileContent.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            recordContent.centerXAnchor.constraint(equalTo: centerXAnchor),
            recordContent.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 14),
            recordContent.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            recordContent.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])

        updateMode(.file)
    }

    @objc private func modeChanged() {
        updateMode(segmentedControl.selectedSegment == 0 ? .file : .recording)
    }

    @objc private func didClickDropZone() {
        if mode == .file {
            onChooseFile?()
        }
    }

    @objc private func recordButtonClicked() {
        onRecordToggle?()
    }

    private func updateMode(_ newMode: Mode) {
        mode = newMode
        segmentedControl.selectedSegment = newMode == .file ? 0 : 1
        fileContent.isHidden = newMode != .file
        recordContent.isHidden = newMode != .recording
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard mode == .file, draggedFileURL(sender).map(VideoAudioExtractor.isSupportedFile) == true else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = draggedFileURL(sender), VideoAudioExtractor.isSupportedFile(url) else {
            return false
        }
        onFileDropped?(url)
        return true
    }

    private func draggedFileURL(_ sender: NSDraggingInfo) -> URL? {
        guard let string = sender.draggingPasteboard.string(forType: .fileURL) else {
            return nil
        }
        return URL(string: string)
    }
}
