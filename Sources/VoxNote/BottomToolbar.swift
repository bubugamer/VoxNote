import Cocoa

@MainActor
final class BottomToolbar: NSView {
    var onCopy: (() -> Void)?
    var onExport: (() -> Void)?

    private let languagePopup = NSPopUpButton()
    private let copyButton = NSButton.rounded(title: "Copy All", target: nil, action: nil)
    private let exportButton = NSButton.rounded(title: "Export .txt", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
        refreshLanguage()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTextActionsEnabled(_ enabled: Bool) {
        copyButton.isEnabled = enabled
        exportButton.isEnabled = enabled
    }

    func refreshLanguage() {
        languagePopup.removeAllItems()
        for language in LanguageManager.supportedLanguages {
            languagePopup.addItem(withTitle: language.display)
            languagePopup.lastItem?.representedObject = language.code
        }
        let current = LanguageManager.shared.currentSelection
        if let item = languagePopup.itemArray.first(where: { ($0.representedObject as? String) == current }) {
            languagePopup.select(item)
        }
    }

    private func setup() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.pinEdges(to: self)

        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(languagePopup)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(spacer)

        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        exportButton.target = self
        exportButton.action = #selector(exportClicked)
        stack.addArrangedSubview(copyButton)
        stack.addArrangedSubview(exportButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            languagePopup.widthAnchor.constraint(equalToConstant: 150),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])
    }

    @objc private func languageChanged() {
        guard let code = languagePopup.selectedItem?.representedObject as? String else { return }
        LanguageManager.shared.currentSelection = code
    }

    @objc private func copyClicked() {
        onCopy?()
        copyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyButton.title = "Copy All"
        }
    }

    @objc private func exportClicked() {
        onExport?()
    }
}
