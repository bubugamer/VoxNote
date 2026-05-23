import AVFoundation
import Cocoa
import UniformTypeIdentifiers

@MainActor
final class MainWindow: NSWindow, NSWindowDelegate {
    var onSettings: (() -> Void)?

    private let topBar = NSView()
    private let topModelStatusLabel = NSTextField.label("", font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor)
    private let actionGroup = NSStackView()
    private let mainContainer = NSView()
    private let sidebarView = FileSidebarView()
    private let transcriptView = TranscriptPanelView()
    private let progressView = TranscriptionProgressView()
    private let recordingView = RecordingWorkspaceView()

    private var selectedFolderURL: URL?
    private var files: [VoxFileItem] = []
    private var selectedFile: VoxFileItem?
    private var latestState: VoxTranscriptionState = .idle

    init() {
        let rect = NSRect(x: 0, y: 0, width: 1320, height: 820)
        super.init(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "VoxNote"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        minSize = NSSize(width: 1120, height: 700)
        delegate = self
        isReleasedWhenClosed = false
        center()
        setupContent()
        setupCallbacks()
        loadInitialFolder()
        refreshModelStatus()
        updateActionState()
    }

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        orderOut(nil)
        return false
    }

    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Audio or Video"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.supportedContentTypes()

        if panel.runModal() == .OK, let url = panel.url {
            guard VideoAudioExtractor.isSupportedFile(url) else {
                showAlert(title: "Unsupported File", message: "Please choose a supported audio or video file.")
                return
            }
            loadFolder(url.deletingLastPathComponent(), selecting: url)
        }
    }

    func copyAll() {
        transcriptView.copyAll()
    }

    func exportTranscription() {
        exportTranscription(as: .txt)
    }

    func exportMarkdown() {
        exportTranscription(as: .markdown)
    }

    func update(state: VoxTranscriptionState) {
        latestState = state

        if case .recording = state {
            recordingView.update(state: state)
        } else if !recordingView.isHidden {
            recordingView.update(state: state)
        }

        transcriptView.update(state: state)
        progressView.update(state: state, selectedFile: selectedFile)

        if case .completed = state {
            refreshFolderAfterCompletion()
        }

        updateActionState()
        refreshModelStatus()
    }

    func refreshLanguage() {
        // Language selection now lives in the Settings menu, so the main window
        // only needs to refresh model/status driven controls.
        refreshModelStatus()
    }

    func refreshModelStatus() {
        let manager = AppModelManager.shared
        topModelStatusLabel.stringValue = "Model: \(manager.currentModelInfo.displayName) - \(manager.whisperModelState.displayText)"
    }

    private func setupContent() {
        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.voxWindowBackground.cgColor
        contentView = rootView

        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = NSColor.white.cgColor
        rootView.addSubview(topBar)

        mainContainer.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(mainContainer)

        recordingView.translatesAutoresizingMaskIntoConstraints = false
        recordingView.isHidden = true
        rootView.addSubview(recordingView)

        setupTopBar()
        setupMainLayout()

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: rootView.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 58),

            mainContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            mainContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            mainContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            mainContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            recordingView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            recordingView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            recordingView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            recordingView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
    }

    private func setupTopBar() {
        let titleStack = NSStackView()
        titleStack.orientation = .horizontal
        titleStack.alignment = .centerY
        titleStack.spacing = 12
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(titleStack)

        let titleLabel = NSTextField.label("VoxNote", font: .systemFont(ofSize: 22, weight: .bold), color: .labelColor)
        titleStack.addArrangedSubview(titleLabel)

        actionGroup.orientation = .horizontal
        actionGroup.alignment = .centerY
        actionGroup.spacing = 8
        actionGroup.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        actionGroup.translatesAutoresizingMaskIntoConstraints = false
        actionGroup.wantsLayer = true
        actionGroup.layer?.cornerRadius = 21
        actionGroup.layer?.backgroundColor = NSColor.voxControlBackground.cgColor
        topBar.addSubview(actionGroup)

        topModelStatusLabel.alignment = .right
        topModelStatusLabel.lineBreakMode = .byTruncatingTail
        topBar.addSubview(topModelStatusLabel)

        actionGroup.addArrangedSubview(makeSymbolButton(symbol: "doc.on.doc", accessibilityLabel: "Copy", action: #selector(copyClicked)))
        actionGroup.addArrangedSubview(makeTextButton("TXT", accessibilityLabel: "Export TXT", action: #selector(exportTxtClicked)))
        actionGroup.addArrangedSubview(makeTextButton("MD", accessibilityLabel: "Export Markdown", action: #selector(exportMarkdownClicked)))
        actionGroup.addArrangedSubview(makeSymbolButton(symbol: "gearshape", accessibilityLabel: "Settings", action: #selector(settingsClicked)))

        NSLayoutConstraint.activate([
            titleStack.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 150),
            titleStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            actionGroup.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -18),
            actionGroup.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            actionGroup.heightAnchor.constraint(equalToConstant: 42),

            topModelStatusLabel.trailingAnchor.constraint(equalTo: actionGroup.leadingAnchor, constant: -12),
            topModelStatusLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            topModelStatusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleStack.trailingAnchor, constant: 24),
            topModelStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340)
        ])
    }

    private func setupMainLayout() {
        mainContainer.wantsLayer = true
        mainContainer.layer?.backgroundColor = NSColor.white.cgColor

        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        mainContainer.addSubview(sidebarView)

        let rightPane = NSView()
        rightPane.translatesAutoresizingMaskIntoConstraints = false
        rightPane.wantsLayer = true
        rightPane.layer?.backgroundColor = NSColor.white.cgColor
        mainContainer.addSubview(rightPane)

        transcriptView.translatesAutoresizingMaskIntoConstraints = false
        progressView.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(transcriptView)
        rightPane.addSubview(progressView)

        NSLayoutConstraint.activate([
            sidebarView.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
            sidebarView.topAnchor.constraint(equalTo: mainContainer.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: mainContainer.bottomAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: 340),

            rightPane.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            rightPane.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
            rightPane.topAnchor.constraint(equalTo: mainContainer.topAnchor),
            rightPane.bottomAnchor.constraint(equalTo: mainContainer.bottomAnchor),

            transcriptView.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            transcriptView.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            transcriptView.topAnchor.constraint(equalTo: rightPane.topAnchor),

            progressView.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            progressView.topAnchor.constraint(equalTo: transcriptView.bottomAnchor),
            progressView.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 190)
        ])
    }

    private func setupCallbacks() {
        sidebarView.onChooseFolder = { [weak self] in
            self?.chooseFolder(startRecordingAfterSelection: false)
        }
        sidebarView.onSelectFile = { [weak self] item in
            self?.selectFile(item)
        }
        sidebarView.onRecord = { [weak self] in
            self?.startRecordingFlow()
        }
        progressView.onStart = { [weak self] in
            self?.startSelectedTranscription()
        }
        recordingView.onDone = { [weak self] in
            self?.finishRecording()
        }
    }

    private func loadInitialFolder() {
        guard let path = UserDefaults.standard.string(forKey: "selectedFolderPath") else {
            sidebarView.setFolder(nil, files: [], selected: nil)
            transcriptView.showEmptyFolder()
            progressView.update(state: .idle, selectedFile: nil)
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            sidebarView.setFolder(nil, files: [], selected: nil)
            transcriptView.showEmptyFolder()
            progressView.update(state: .idle, selectedFile: nil)
            return
        }
        loadFolder(url, selecting: nil)
    }

    private func chooseFolder(startRecordingAfterSelection: Bool) {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if let selectedFolderURL {
            panel.directoryURL = selectedFolderURL
        }

        if panel.runModal() == .OK, let url = panel.url {
            loadFolder(url, selecting: nil)
            if startRecordingAfterSelection {
                startRecordingFlow()
            }
        }
    }

    private func loadFolder(_ url: URL, selecting selectedURL: URL?) {
        selectedFolderURL = url
        UserDefaults.standard.set(url.path, forKey: "selectedFolderPath")

        files = Self.supportedFiles(in: url)
        let target = selectedURL.flatMap { selected in files.first(where: { $0.url.path == selected.path }) } ?? files.first
        selectedFile = target

        sidebarView.setFolder(url, files: files, selected: target?.url)
        transcriptView.showSelectedFile(target)
        progressView.update(state: .idle, selectedFile: target)
        latestState = .idle
        updateActionState()
    }

    private func selectFile(_ item: VoxFileItem) {
        selectedFile = item
        sidebarView.select(url: item.url)
        if !latestState.isBusy {
            latestState = .idle
            transcriptView.showSelectedFile(item)
            progressView.update(state: .idle, selectedFile: item)
            updateActionState()
        }
    }

    private func startSelectedTranscription() {
        guard !latestState.isBusy else { return }
        guard let selectedFile else {
            showAlert(title: "Choose a File", message: "Select a supported audio or video file first.")
            return
        }
        transcriptView.showSelectedFile(selectedFile)
        TranscriptionOrchestrator.shared.transcribe(fileURL: selectedFile.url)
    }

    private func startRecordingFlow() {
        guard !latestState.isBusy else { return }
        guard selectedFolderURL != nil else {
            chooseFolder(startRecordingAfterSelection: true)
            return
        }

        showRecordingMode()
        let folderName = selectedFolderURL?.lastPathComponent ?? "Recordings"
        recordingView.prepare(folderName: folderName)
        TranscriptionOrchestrator.shared.setRecordingDirectory(selectedFolderURL)
        TranscriptionOrchestrator.shared.startRecording()
    }

    private func finishRecording() {
        guard case .recording = latestState else {
            showMainMode()
            return
        }
        recordingView.showFinishing()
        showMainMode()
        TranscriptionOrchestrator.shared.stopRecording()
    }

    private func showRecordingMode() {
        mainContainer.isHidden = true
        recordingView.isHidden = false
        actionGroup.isHidden = true
        topModelStatusLabel.isHidden = true
    }

    private func showMainMode() {
        mainContainer.isHidden = false
        recordingView.isHidden = true
        actionGroup.isHidden = false
        topModelStatusLabel.isHidden = false
    }

    private func refreshFolderAfterCompletion() {
        guard let folder = selectedFolderURL else { return }
        let currentURL = TranscriptionOrchestrator.shared.currentSourceURL
        files = Self.supportedFiles(in: folder)
        if let currentURL, currentURL.deletingLastPathComponent().path == folder.path,
           let item = files.first(where: { $0.url.path == currentURL.path }) {
            selectedFile = item
        }
        sidebarView.setFolder(folder, files: files, selected: selectedFile?.url)
        progressView.update(state: latestState, selectedFile: selectedFile)
    }

    private func exportTranscription(as format: ExportFormat) {
        let text = transcriptView.currentText
        guard transcriptView.hasExportableText, !text.isEmpty else { return }

        let sourceName = selectedFile?.url.deletingPathExtension().lastPathComponent
            ?? TranscriptionOrchestrator.shared.currentSourceName
        let fileName = "\(sourceName).\(format.fileExtension)"

        let panel = NSSavePanel()
        panel.title = "Export Transcription"
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try format.contents(title: sourceName, transcript: text)
                    .write(to: url, atomically: true, encoding: .utf8)
            } catch {
                showAlert(title: "Export Failed", message: error.localizedDescription)
            }
        }
    }

    private func updateActionState() {
        let hasText = transcriptView.hasExportableText && !latestState.isBusy
        for case let button as NSButton in actionGroup.arrangedSubviews {
            button.isEnabled = hasText || button.action == #selector(settingsClicked)
            button.alphaValue = button.isEnabled ? 1 : 0.45
        }
    }

    @objc private func copyClicked() {
        copyAll()
    }

    @objc private func exportTxtClicked() {
        exportTranscription(as: .txt)
    }

    @objc private func exportMarkdownClicked() {
        exportTranscription(as: .markdown)
    }

    @objc private func settingsClicked() {
        onSettings?()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: self)
    }

    private func makeSymbolButton(symbol: String, accessibilityLabel: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)
        button.contentTintColor = .labelColor
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 34),
            button.heightAnchor.constraint(equalToConstant: 34)
        ])
        return button
    }

    private func makeTextButton(_ text: String, accessibilityLabel: String, action: Selector) -> NSButton {
        let button = NSButton(title: text, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .bold)
        button.contentTintColor = .labelColor
        button.toolTip = accessibilityLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 42),
            button.heightAnchor.constraint(equalToConstant: 34)
        ])
        return button
    }

    private static func supportedFiles(in folder: URL) -> [VoxFileItem] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url -> VoxFileItem? in
            guard VideoAudioExtractor.isSupportedFile(url) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { return nil }
            let date = values?.contentModificationDate ?? Date()
            return VoxFileItem(
                url: url,
                modifiedDate: date,
                duration: Self.durationString(for: url)
            )
        }
        .sorted { lhs, rhs in
            lhs.modifiedDate > rhs.modifiedDate
        }
    }

    private static func durationString(for url: URL) -> String? {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return VoxTranscriptionState.formatDuration(seconds)
    }

    private static func supportedContentTypes() -> [UTType] {
        let exts = VideoAudioExtractor.supportedAudioExtensions.union(VideoAudioExtractor.supportedVideoExtensions)
        let types = exts.compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.audio, .movie] : types
    }
}

private enum ExportFormat {
    case txt
    case markdown

    var fileExtension: String {
        switch self {
        case .txt: "txt"
        case .markdown: "md"
        }
    }

    var contentType: UTType {
        switch self {
        case .txt:
            return .plainText
        case .markdown:
            return UTType(filenameExtension: "md") ?? .plainText
        }
    }

    func contents(title: String, transcript: String) -> String {
        switch self {
        case .txt:
            return transcript
        case .markdown:
            return "# \(title)\n\n\(transcript)\n"
        }
    }
}

private struct VoxFileItem: Equatable {
    let url: URL
    let modifiedDate: Date
    let duration: String?

    var title: String {
        url.deletingPathExtension().lastPathComponent
    }

    var fileExtension: String {
        url.pathExtension.uppercased()
    }

    var dateText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: modifiedDate)
    }

    var detailText: String {
        "\(fileExtension) · \(dateText)"
    }
}

private final class FileSidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onChooseFolder: (() -> Void)?
    var onSelectFile: ((VoxFileItem) -> Void)?
    var onRecord: (() -> Void)?

    private let folderTitleLabel = NSTextField.label("No folder selected", font: .systemFont(ofSize: 15, weight: .semibold))
    private let folderPathLabel = NSTextField.label("Choose a folder to list supported files", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let countLabel = NSTextField.label("0", font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor)
    private let tableView = NSTableView()
    private var items: [VoxFileItem] = []
    private var selectedURL: URL?
    private var isUpdatingSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setFolder(_ folder: URL?, files: [VoxFileItem], selected: URL?) {
        folderTitleLabel.stringValue = folder?.lastPathComponent ?? "No folder selected"
        folderPathLabel.stringValue = folder?.path ?? "Choose a folder to list supported files"
        items = files
        selectedURL = selected
        countLabel.stringValue = "\(files.count)"
        tableView.reloadData()
        isUpdatingSelection = true
        if let selected, let row = items.firstIndex(where: { $0.url.path == selected.path }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        isUpdatingSelection = false
    }

    func select(url: URL) {
        guard selectedURL?.path != url.path else {
            tableView.reloadData()
            return
        }
        selectedURL = url
        isUpdatingSelection = true
        if let row = items.firstIndex(where: { $0.url.path == url.path }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        isUpdatingSelection = false
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        70
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? FileTableCellView ?? FileTableCellView()
        cell.identifier = identifier
        let item = items[row]
        cell.configure(item: item, selected: item.url.path == selectedURL?.path)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection else { return }
        let row = tableView.selectedRow
        guard items.indices.contains(row) else { return }
        guard selectedURL?.path != items[row].url.path else {
            tableView.reloadData()
            return
        }
        selectedURL = items[row].url
        tableView.reloadData()
        onSelectFile?(items[row])
    }

    override func layout() {
        super.layout()
        tableView.tableColumns.first?.width = tableView.bounds.width
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.voxSidebarBackground.cgColor

        let folderCard = NSView()
        folderCard.translatesAutoresizingMaskIntoConstraints = false
        folderCard.wantsLayer = true
        folderCard.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
        addSubview(folderCard)

        let folderLabel = NSTextField.label("FOLDER", font: .systemFont(ofSize: 11, weight: .bold), color: .secondaryLabelColor)
        folderCard.addSubview(folderLabel)

        let folderBox = NSView()
        folderBox.translatesAutoresizingMaskIntoConstraints = false
        folderBox.wantsLayer = true
        folderBox.layer?.cornerRadius = 10
        folderBox.layer?.borderWidth = 1
        folderBox.layer?.borderColor = NSColor.voxSeparator.cgColor
        folderBox.layer?.backgroundColor = NSColor.white.cgColor
        folderCard.addSubview(folderBox)

        folderTitleLabel.lineBreakMode = .byTruncatingTail
        folderPathLabel.lineBreakMode = .byTruncatingMiddle
        folderBox.addSubview(folderTitleLabel)
        folderBox.addSubview(folderPathLabel)

        let chooseButton = NSButton(title: "Choose", target: self, action: #selector(chooseFolderClicked))
        chooseButton.isBordered = false
        chooseButton.font = .systemFont(ofSize: 14, weight: .bold)
        chooseButton.contentTintColor = .white
        chooseButton.translatesAutoresizingMaskIntoConstraints = false
        chooseButton.wantsLayer = true
        chooseButton.layer?.cornerRadius = 10
        chooseButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
        folderCard.addSubview(chooseButton)

        let chips = NSStackView()
        chips.orientation = .horizontal
        chips.spacing = 6
        chips.translatesAutoresizingMaskIntoConstraints = false
        ["MP3", "WAV", "M4A", "MP4", "MOV", "WEBM"].forEach { chips.addArrangedSubview(Self.chip($0)) }
        folderCard.addSubview(chips)

        let listHeader = NSView()
        listHeader.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listHeader)

        let supportedLabel = NSTextField.label("Supported files", font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor)
        listHeader.addSubview(supportedLabel)
        listHeader.addSubview(countLabel)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        addSubview(scrollView)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        scrollView.documentView = tableView

        let recordDock = NSView()
        recordDock.translatesAutoresizingMaskIntoConstraints = false
        recordDock.wantsLayer = true
        recordDock.layer?.backgroundColor = NSColor.voxSidebarBackground.cgColor
        addSubview(recordDock)

        let recordButton = NSButton()
        recordButton.title = ""
        recordButton.attributedTitle = NSAttributedString(string: "")
        recordButton.alternateTitle = ""
        recordButton.isBordered = false
        recordButton.setButtonType(.momentaryChange)
        recordButton.target = self
        recordButton.action = #selector(recordClicked)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.wantsLayer = true
        recordButton.layer?.cornerRadius = 35
        recordButton.layer?.backgroundColor = NSColor.systemRed.cgColor
        recordButton.toolTip = "Record"
        recordDock.addSubview(recordButton)

        NSLayoutConstraint.activate([
            folderCard.leadingAnchor.constraint(equalTo: leadingAnchor),
            folderCard.trailingAnchor.constraint(equalTo: trailingAnchor),
            folderCard.topAnchor.constraint(equalTo: topAnchor),
            folderCard.heightAnchor.constraint(equalToConstant: 150),

            folderLabel.leadingAnchor.constraint(equalTo: folderCard.leadingAnchor, constant: 16),
            folderLabel.topAnchor.constraint(equalTo: folderCard.topAnchor, constant: 18),

            folderBox.leadingAnchor.constraint(equalTo: folderCard.leadingAnchor, constant: 16),
            folderBox.topAnchor.constraint(equalTo: folderLabel.bottomAnchor, constant: 10),
            folderBox.trailingAnchor.constraint(equalTo: chooseButton.leadingAnchor, constant: -10),
            folderBox.heightAnchor.constraint(equalToConstant: 54),

            folderTitleLabel.leadingAnchor.constraint(equalTo: folderBox.leadingAnchor, constant: 12),
            folderTitleLabel.trailingAnchor.constraint(equalTo: folderBox.trailingAnchor, constant: -12),
            folderTitleLabel.topAnchor.constraint(equalTo: folderBox.topAnchor, constant: 9),

            folderPathLabel.leadingAnchor.constraint(equalTo: folderTitleLabel.leadingAnchor),
            folderPathLabel.trailingAnchor.constraint(equalTo: folderTitleLabel.trailingAnchor),
            folderPathLabel.topAnchor.constraint(equalTo: folderTitleLabel.bottomAnchor, constant: 2),

            chooseButton.trailingAnchor.constraint(equalTo: folderCard.trailingAnchor, constant: -16),
            chooseButton.centerYAnchor.constraint(equalTo: folderBox.centerYAnchor),
            chooseButton.widthAnchor.constraint(equalToConstant: 78),
            chooseButton.heightAnchor.constraint(equalToConstant: 42),

            chips.leadingAnchor.constraint(equalTo: folderCard.leadingAnchor, constant: 16),
            chips.trailingAnchor.constraint(lessThanOrEqualTo: folderCard.trailingAnchor, constant: -16),
            chips.topAnchor.constraint(equalTo: folderBox.bottomAnchor, constant: 12),

            listHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            listHeader.trailingAnchor.constraint(equalTo: trailingAnchor),
            listHeader.topAnchor.constraint(equalTo: folderCard.bottomAnchor),
            listHeader.heightAnchor.constraint(equalToConstant: 42),

            supportedLabel.leadingAnchor.constraint(equalTo: listHeader.leadingAnchor, constant: 16),
            supportedLabel.centerYAnchor.constraint(equalTo: listHeader.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: listHeader.trailingAnchor, constant: -16),
            countLabel.centerYAnchor.constraint(equalTo: listHeader.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: listHeader.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: recordDock.topAnchor),

            recordDock.leadingAnchor.constraint(equalTo: leadingAnchor),
            recordDock.trailingAnchor.constraint(equalTo: trailingAnchor),
            recordDock.bottomAnchor.constraint(equalTo: bottomAnchor),
            recordDock.heightAnchor.constraint(equalToConstant: 110),

            recordButton.centerXAnchor.constraint(equalTo: recordDock.centerXAnchor),
            recordButton.centerYAnchor.constraint(equalTo: recordDock.centerYAnchor),
            recordButton.widthAnchor.constraint(equalToConstant: 70),
            recordButton.heightAnchor.constraint(equalToConstant: 70)
        ])
    }

    private static func chip(_ text: String) -> NSView {
        let label = NSTextField.label(text, font: .systemFont(ofSize: 11, weight: .bold), color: .secondaryLabelColor)
        label.alignment = .center
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = 7
        wrapper.layer?.backgroundColor = NSColor.voxControlBackground.cgColor
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -3)
        ])
        return wrapper
    }

    @objc private func chooseFolderClicked() {
        onChooseFolder?()
    }

    @objc private func recordClicked() {
        onRecord?()
    }
}

private final class FileTableCellView: NSTableCellView {
    private let titleLabel = NSTextField.label("", font: .systemFont(ofSize: 15, weight: .bold), color: .labelColor)
    private let detailLabel = NSTextField.label("", font: .systemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor)
    private let durationLabel = NSTextField.label("", font: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(item: VoxFileItem, selected: Bool) {
        titleLabel.stringValue = item.title
        detailLabel.stringValue = item.detailText
        durationLabel.stringValue = item.duration ?? "--:--"
        layer?.backgroundColor = selected ? NSColor.voxSelectedRow.cgColor : NSColor.clear.cgColor
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 10

        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(durationLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: durationLabel.leadingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: durationLabel.leadingAnchor, constant: -12),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),

            durationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            durationLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

private final class TranscriptPanelView: NSView {
    private let statusLabel = NSTextField.label("", font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor)
    private let titleLabel = NSTextField.label("VoxNote", font: .systemFont(ofSize: 22, weight: .bold), color: .labelColor)
    private let subtitleLabel = NSTextField.label("", font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor)
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private(set) var hasExportableText = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
        showEmptyFolder()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentText: String {
        textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func showEmptyFolder() {
        hasExportableText = false
        statusLabel.stringValue = ""
        titleLabel.stringValue = "Choose a folder"
        subtitleLabel.stringValue = ""
        setText("Choose a folder on the left to show supported audio and video files.", color: .secondaryLabelColor)
    }

    func showSelectedFile(_ item: VoxFileItem?) {
        guard let item else {
            showEmptyFolder()
            return
        }
        statusLabel.stringValue = "Ready"
        titleLabel.stringValue = item.title
        subtitleLabel.stringValue = [item.dateText, item.duration].compactMap(\.self).joined(separator: "  ")
        hasExportableText = false
        setText("", color: .secondaryLabelColor)
    }

    func update(state: VoxTranscriptionState) {
        switch state {
        case .idle:
            break
        case .extractingAudio, .loadingModel, .preparingAudio, .diarizing, .refining, .downloadingModel:
            statusLabel.stringValue = state.text
        case .transcribing(_, let partialText):
            statusLabel.stringValue = "Transcribing"
            if !partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasExportableText = true
                setText(partialText, color: .labelColor)
            }
        case .recording(let confirmedText, let pendingText, _):
            statusLabel.stringValue = "Recording"
            hasExportableText = !confirmedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            setRecordingText(confirmed: confirmedText, pending: pendingText)
        case .completed(let text):
            statusLabel.stringValue = "Completed"
            hasExportableText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            setText(text.isEmpty ? "No speech was detected." : text, color: .labelColor)
        case .error(let message):
            statusLabel.stringValue = "Error"
            hasExportableText = false
            setText(message, color: .systemRed)
        }
    }

    func copyAll() {
        let text = currentText
        guard hasExportableText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let statusDot = NSView()
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4.5
        statusDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        header.addSubview(statusDot)
        header.addSubview(statusLabel)

        titleLabel.alignment = .center
        subtitleLabel.alignment = .center
        header.addSubview(titleLabel)
        header.addSubview(subtitleLabel)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 19, weight: .semibold)
        textView.textColor = .secondaryLabelColor
        textView.textContainerInset = NSSize(width: 30, height: 22)
        textView.backgroundColor = .white
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        let width = scrollView.widthAnchor.constraint(equalToConstant: 820)
        width.priority = .defaultHigh
        let height = scrollView.heightAnchor.constraint(equalToConstant: 440)
        height.priority = .defaultHigh

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -34),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            header.heightAnchor.constraint(equalToConstant: 54),

            statusDot.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            statusDot.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 9),
            statusDot.heightAnchor.constraint(equalToConstant: 9),

            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: statusDot.centerYAnchor),

            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 4),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 540),

            subtitleLabel.centerXAnchor.constraint(equalTo: titleLabel.centerXAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 22),
            scrollView.centerXAnchor.constraint(equalTo: centerXAnchor),
            scrollView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            scrollView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
            width,
            height,
            scrollView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -18)
        ])
    }

    private func setText(_ text: String, color: NSColor) {
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 19, weight: .semibold),
                .foregroundColor: color,
                .paragraphStyle: Self.paragraphStyle()
            ]
        ))
        scrollToBottom()
    }

    private func setRecordingText(confirmed: String, pending: String) {
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(
            string: confirmed,
            attributes: [
                .font: NSFont.systemFont(ofSize: 19, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: Self.paragraphStyle()
            ]
        ))
        if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if attributed.length > 0 {
                attributed.append(NSAttributedString(string: "\n\n"))
            }
            attributed.append(NSAttributedString(
                string: pending,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 19, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: Self.paragraphStyle()
                ]
            ))
        }
        textView.textStorage?.setAttributedString(attributed)
        scrollToBottom()
    }

    private func scrollToBottom() {
        guard let textStorage = textView.textStorage else { return }
        textView.scrollRangeToVisible(NSRange(location: textStorage.length, length: 0))
    }

    fileprivate static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 18
        return style
    }
}

private final class TranscriptionProgressView: NSView {
    var onStart: (() -> Void)?

    private let startLabel = NSTextField.label("0:00", font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor)
    private let percentLabel = NSTextField.label("0%", font: .systemFont(ofSize: 12, weight: .bold), color: .secondaryLabelColor)
    private let endLabel = NSTextField.label("--:--", font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor)
    private let progressIndicator = NSProgressIndicator()
    private let timerLabel = NSTextField.label("00:00.00", font: .monospacedDigitSystemFont(ofSize: 42, weight: .bold), color: .labelColor)
    private let startButton = NSButton(title: "Start Transcription", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(state: VoxTranscriptionState, selectedFile: VoxFileItem?) {
        let progress: Double
        switch state {
        case .transcribing(let value, _):
            progress = value
        case .downloadingModel(let value):
            progress = value
        case .extractingAudio:
            progress = 0.08
        case .loadingModel:
            progress = 0.12
        case .preparingAudio:
            progress = 0.18
        case .diarizing(let value):
            progress = value
        case .refining:
            progress = 0.96
        case .completed:
            progress = 1
        case .error:
            progress = 0
        case .idle, .recording:
            progress = 0
        }

        progressIndicator.doubleValue = min(1, max(0, progress))
        percentLabel.stringValue = "\(Int(progressIndicator.doubleValue * 100))%"

        if let duration = selectedFile?.duration {
            endLabel.stringValue = duration
        } else {
            endLabel.stringValue = "--:--"
        }
        startLabel.stringValue = progress > 0 && selectedFile?.duration != nil
            ? VoxTranscriptionState.formatDuration(progress * durationSeconds(selectedFile?.duration))
            : "0:00"
        timerLabel.stringValue = Self.timerString(progress: progress, duration: selectedFile?.duration)

        let canStart = selectedFile != nil && !state.isBusy
        startButton.isEnabled = canStart
        startButton.alphaValue = canStart ? 1 : 0.5
        startButton.title = state.isBusy ? "Transcribing" : "Start Transcription"
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.voxSeparator.cgColor

        let progressBox = NSView()
        progressBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressBox)

        progressBox.addSubview(startLabel)
        progressBox.addSubview(percentLabel)
        progressBox.addSubview(endLabel)

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.controlSize = .small
        progressIndicator.style = .bar
        progressBox.addSubview(progressIndicator)

        timerLabel.alignment = .center
        addSubview(timerLabel)

        startButton.target = self
        startButton.action = #selector(startClicked)
        startButton.isBordered = false
        startButton.font = .systemFont(ofSize: 15, weight: .bold)
        startButton.translatesAutoresizingMaskIntoConstraints = false
        startButton.wantsLayer = true
        startButton.layer?.cornerRadius = 24
        startButton.layer?.backgroundColor = NSColor.voxControlBackground.cgColor
        addSubview(startButton)

        NSLayoutConstraint.activate([
            progressBox.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            progressBox.centerXAnchor.constraint(equalTo: centerXAnchor),
            progressBox.widthAnchor.constraint(equalToConstant: 680),
            progressBox.heightAnchor.constraint(equalToConstant: 30),

            startLabel.leadingAnchor.constraint(equalTo: progressBox.leadingAnchor),
            startLabel.topAnchor.constraint(equalTo: progressBox.topAnchor),
            percentLabel.centerXAnchor.constraint(equalTo: progressBox.centerXAnchor),
            percentLabel.topAnchor.constraint(equalTo: progressBox.topAnchor),
            endLabel.trailingAnchor.constraint(equalTo: progressBox.trailingAnchor),
            endLabel.topAnchor.constraint(equalTo: progressBox.topAnchor),

            progressIndicator.leadingAnchor.constraint(equalTo: progressBox.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: progressBox.trailingAnchor),
            progressIndicator.topAnchor.constraint(equalTo: startLabel.bottomAnchor, constant: 7),
            progressIndicator.heightAnchor.constraint(equalToConstant: 8),

            timerLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            timerLabel.topAnchor.constraint(equalTo: progressBox.bottomAnchor, constant: 16),

            startButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            startButton.topAnchor.constraint(equalTo: timerLabel.bottomAnchor, constant: 8),
            startButton.widthAnchor.constraint(equalToConstant: 190),
            startButton.heightAnchor.constraint(equalToConstant: 44),
            startButton.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -14)
        ])
    }

    @objc private func startClicked() {
        onStart?()
    }

    private func durationSeconds(_ duration: String?) -> Double {
        guard let duration else { return 0 }
        let parts = duration.split(separator: ":").compactMap { Double($0) }
        if parts.count == 3 {
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        }
        if parts.count == 2 {
            return parts[0] * 60 + parts[1]
        }
        return 0
    }

    private static func timerString(progress: Double, duration: String?) -> String {
        let total = max(0, progress) * Self.durationSecondsStatic(duration)
        let whole = Int(total)
        let hundredths = Int((total - Double(whole)) * 100)
        let minutes = whole / 60
        let seconds = whole % 60
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }

    private static func durationSecondsStatic(_ duration: String?) -> Double {
        guard let duration else { return 0 }
        let parts = duration.split(separator: ":").compactMap { Double($0) }
        if parts.count == 3 {
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        }
        if parts.count == 2 {
            return parts[0] * 60 + parts[1]
        }
        return 0
    }
}

private final class RecordingWorkspaceView: NSView {
    var onDone: (() -> Void)?

    private let titleLabel = NSTextField.label("New Recording", font: .systemFont(ofSize: 24, weight: .bold), color: .labelColor)
    private let subtitleLabel = NSTextField.label("", font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor)
    private let textView = NSTextView()
    private let waveView = RecordingWaveView()
    private let timerLabel = NSTextField.label("00:00.00", font: .monospacedDigitSystemFont(ofSize: 46, weight: .bold), color: .labelColor)
    private let stateLabel = NSTextField.label("Recording", font: .systemFont(ofSize: 15, weight: .bold), color: .systemRed)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func prepare(folderName: String) {
        titleLabel.stringValue = "New Recording"
        subtitleLabel.stringValue = "\(folderName) · recording audio"
        timerLabel.stringValue = "00:00.00"
        stateLabel.stringValue = "Recording"
        doneButton.isEnabled = true
        setText("")
    }

    func update(state: VoxTranscriptionState) {
        switch state {
        case .recording(let confirmed, let pending, let duration):
            timerLabel.stringValue = Self.timerString(duration)
            stateLabel.stringValue = "Recording"
            setRecordingText(confirmed: confirmed, pending: pending)
            waveView.progress = min(1, duration.truncatingRemainder(dividingBy: 20) / 20)
        case .completed(let text):
            stateLabel.stringValue = "Completed"
            doneButton.isEnabled = true
            setText(text)
        case .error(let message):
            stateLabel.stringValue = "Error"
            doneButton.isEnabled = true
            setText(message)
        default:
            break
        }
    }

    func showFinishing() {
        stateLabel.stringValue = "Finishing"
        doneButton.isEnabled = false
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor

        titleLabel.alignment = .center
        subtitleLabel.alignment = .center
        addSubview(titleLabel)
        addSubview(subtitleLabel)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        addSubview(scrollView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .white
        textView.textColor = .secondaryLabelColor
        textView.font = .systemFont(ofSize: 20, weight: .semibold)
        textView.textContainerInset = NSSize(width: 28, height: 22)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        waveView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(waveView)

        stateLabel.alignment = .center
        addSubview(stateLabel)

        timerLabel.alignment = .center
        addSubview(timerLabel)

        doneButton.target = self
        doneButton.action = #selector(doneClicked)
        doneButton.isBordered = false
        doneButton.font = .systemFont(ofSize: 16, weight: .bold)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.wantsLayer = true
        doneButton.layer?.cornerRadius = 24
        doneButton.layer?.backgroundColor = NSColor.voxControlBackground.cgColor
        addSubview(doneButton)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 30),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 620),

            subtitleLabel.centerXAnchor.constraint(equalTo: titleLabel.centerXAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),

            scrollView.centerXAnchor.constraint(equalTo: centerXAnchor),
            scrollView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 34),
            scrollView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.78),
            scrollView.heightAnchor.constraint(equalToConstant: 330),

            waveView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            waveView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            waveView.bottomAnchor.constraint(equalTo: timerLabel.topAnchor, constant: -44),
            waveView.heightAnchor.constraint(equalToConstant: 64),

            stateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stateLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -34),
            stateLabel.widthAnchor.constraint(equalToConstant: 150),

            timerLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            timerLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -26),

            doneButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -34),
            doneButton.centerYAnchor.constraint(equalTo: stateLabel.centerYAnchor),
            doneButton.widthAnchor.constraint(equalToConstant: 92),
            doneButton.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    private func setText(_ text: String) {
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: TranscriptPanelView.paragraphStyle()
            ]
        ))
    }

    private func setRecordingText(confirmed: String, pending: String) {
        let text = [confirmed, pending]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "Waiting for speech..." }
            .joined(separator: "\n\n")
        setText(text)
    }

    @objc private func doneClicked() {
        onDone?()
    }

    private static func timerString(_ duration: TimeInterval) -> String {
        let whole = Int(duration)
        let hundredths = Int((duration - Double(whole)) * 100)
        let minutes = whole / 60
        let seconds = whole % 60
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }
}

private final class RecordingWaveView: NSView {
    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }

    private let heights: [CGFloat] = [3, 8, 18, 28, 14, 8, 4, 22, 34, 30, 16, 4, 6, 20, 30, 24, 12, 5]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.voxControlBackground.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.labelColor.cgColor)

        let centerY = bounds.midY
        let barWidth: CGFloat = 2
        let gap: CGFloat = 3
        let count = Int(bounds.width / (barWidth + gap))
        for index in 0..<count {
            let height = heights[index % heights.count]
            let x = CGFloat(index) * (barWidth + gap) + 12
            context.fill(CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height))
        }

        context.setFillColor(NSColor.systemBlue.cgColor)
        let playheadX = bounds.width * CGFloat(progress)
        context.fill(CGRect(x: playheadX, y: -4, width: 6, height: bounds.height + 8))
    }
}

private extension NSColor {
    static let voxWindowBackground = NSColor(calibratedWhite: 0.96, alpha: 1)
    static let voxSidebarBackground = NSColor(calibratedWhite: 0.975, alpha: 1)
    static let voxControlBackground = NSColor(calibratedWhite: 0.93, alpha: 1)
    static let voxSeparator = NSColor(calibratedWhite: 0.86, alpha: 1)
    static let voxSelectedRow = NSColor(calibratedWhite: 0.91, alpha: 1)
}
