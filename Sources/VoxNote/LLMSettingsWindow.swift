import Cocoa

@MainActor
final class LLMSettingsWindow: NSWindow, NSWindowDelegate {
    private let baseURLField = NSTextField()
    private let apiKeyField = NSTextField()
    private let modelField = NSTextField()
    private let statusLabel = NSTextField.label("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let testButton = NSButton.rounded(title: "Test", target: nil, action: nil)
    private let saveButton = NSButton.rounded(title: "Save", target: nil, action: nil)

    init() {
        let rect = NSRect(x: 0, y: 0, width: 440, height: 280)
        super.init(
            contentRect: rect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "LLM Settings"
        isReleasedWhenClosed = false
        delegate = self
        center()
        setupContent()
        loadValues()
    }

    func show() {
        loadValues()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        orderOut(nil)
        return false
    }

    private func setupContent() {
        let content = NSView()
        contentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        stack.pinEdges(to: content, inset: 20)

        stack.addArrangedSubview(row(label: "API Base URL", field: baseURLField))
        stack.addArrangedSubview(row(label: "API Key", field: apiKeyField))
        stack.addArrangedSubview(row(label: "Model", field: modelField))
        stack.addArrangedSubview(statusLabel)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(spacer)
        buttonRow.addArrangedSubview(testButton)
        buttonRow.addArrangedSubview(saveButton)
        stack.addArrangedSubview(buttonRow)

        testButton.target = self
        testButton.action = #selector(testConnection)
        saveButton.target = self
        saveButton.action = #selector(saveSettings)

        NSLayoutConstraint.activate([
            baseURLField.widthAnchor.constraint(equalToConstant: 270),
            apiKeyField.widthAnchor.constraint(equalTo: baseURLField.widthAnchor),
            modelField.widthAnchor.constraint(equalTo: baseURLField.widthAnchor),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])
    }

    private func row(label: String, field: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let labelView = NSTextField.label(label, font: .systemFont(ofSize: 13))
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 110).isActive = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = label

        row.addArrangedSubview(labelView)
        row.addArrangedSubview(field)
        return row
    }

    private func loadValues() {
        baseURLField.stringValue = LLMService.shared.baseURL
        apiKeyField.stringValue = LLMService.shared.apiKey
        modelField.stringValue = LLMService.shared.model
        statusLabel.stringValue = ""
    }

    @objc private func testConnection() {
        saveCurrentValues()
        statusLabel.stringValue = "Testing..."
        testButton.isEnabled = false
        Task {
            do {
                let response = try await LLMService.shared.testConnection()
                statusLabel.stringValue = "Connection OK: \(response.trimmingCharacters(in: .whitespacesAndNewlines))"
                statusLabel.textColor = .secondaryLabelColor
            } catch {
                statusLabel.stringValue = error.localizedDescription
                statusLabel.textColor = .systemRed
            }
            testButton.isEnabled = true
        }
    }

    @objc private func saveSettings() {
        saveCurrentValues()
        NotificationCenter.default.post(name: .settingsDidChange, object: self)
        orderOut(nil)
    }

    private func saveCurrentValues() {
        LLMService.shared.baseURL = baseURLField.stringValue
        LLMService.shared.apiKey = apiKeyField.stringValue
        LLMService.shared.model = modelField.stringValue
    }
}
