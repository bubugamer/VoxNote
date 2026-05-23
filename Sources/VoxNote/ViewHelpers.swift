import Cocoa

extension NSView {
    func pinEdges(to other: NSView, inset: CGFloat = 0) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: inset),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -inset),
            topAnchor.constraint(equalTo: other.topAnchor, constant: inset),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -inset)
        ])
    }
}

extension NSButton {
    static func rounded(title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }
}

extension NSTextField {
    static func label(_ text: String, font: NSFont = .systemFont(ofSize: 13), color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
