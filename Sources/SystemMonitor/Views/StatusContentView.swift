import AppKit

/// A custom status-bar view: an icon + up to two lines of text, laid out with
/// precise spacing and vertical centering. `NSStatusBarButton` can't cleanly
/// center an icon next to a two-line title, so we render it ourselves.
final class StatusContentView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private static let lineHeight: CGFloat = 24
    static let menuBarHeight: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleNone

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.cell?.wraps = true
        label.lineBreakMode = .byWordWrapping

        addSubview(iconView)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.lineHeight),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(icon: String, lines: [String], bold: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.image?.isTemplate = true
        iconView.contentTintColor = .labelColor

        let text = lines.joined(separator: "\n")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 0
        let fontSize: CGFloat = 8.8
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
        let attr = NSMutableAttributedString(string: text)
        attr.addAttribute(.font, value: font, range: NSRange(location: 0, length: attr.length))
        attr.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attr.length))
        label.attributedStringValue = attr

        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let iconWidth: CGFloat = 18
        let labelSize = label.intrinsicContentSize
        return NSSize(width: 4 + iconWidth + 5 + labelSize.width + 3,
                      height: Self.lineHeight)
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}
