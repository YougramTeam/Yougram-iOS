import Foundation
import UIKit
import Display
import ComponentFlow
import ComponentDisplayAdapters
import TelegramPresentationData
import GlassBackgroundComponent

/// The commands of Yougram's quick formatting panel, in the order the panel shows them.
enum YougramQuickFormattingAction: Equatable {
    case bold
    case italic
    case underline
    case strikethrough
    case monospace
    case spoiler
    case link
    case quote
    case codeBlock
    case clearFormatting

    /// `isSecretChat`: a secret chat has no spoilers and no quotes, as the composer's Format menus do.
    static func available(isSecretChat: Bool) -> [YougramQuickFormattingAction] {
        var result: [YougramQuickFormattingAction] = [.bold, .italic, .underline, .strikethrough, .monospace]
        if !isSecretChat {
            result.append(.spoiler)
        }
        result.append(.link)
        if !isSecretChat {
            result.append(.quote)
        }
        result.append(contentsOf: [.codeBlock, .clearFormatting])
        return result
    }

    fileprivate var symbolName: String {
        switch self {
        case .bold:
            return "bold"
        case .italic:
            return "italic"
        case .underline:
            return "underline"
        case .strikethrough:
            return "strikethrough"
        case .monospace:
            return "chevron.left.forwardslash.chevron.right"
        case .spoiler:
            return "eye.slash"
        case .link:
            return "link"
        case .quote:
            return "text.quote"
        case .codeBlock:
            return "curlybraces"
        case .clearFormatting:
            return "eraser"
        }
    }

    fileprivate func title(strings: PresentationStrings) -> String {
        switch self {
        case .bold:
            return strings.TextFormat_Bold
        case .italic:
            return strings.TextFormat_Italic
        case .underline:
            return strings.TextFormat_Underline
        case .strikethrough:
            return strings.TextFormat_Strikethrough
        case .monospace:
            return strings.TextFormat_Monospace
        case .spoiler:
            return strings.TextFormat_Spoiler
        case .link:
            return strings.TextFormat_Link
        case .quote:
            return strings.TextFormat_Quote
        case .codeBlock:
            return strings.TextFormat_Code
        case .clearFormatting:
            // No localized string exists for this command yet.
            return "Clear Formatting"
        }
    }
}

/// Yougram: a horizontally scrolling row of formatting buttons that `ChatTextInputPanelNode` lays out under its text
/// field while the field is focused (Settings ▸ Yougram ▸ Chats ▸ Quick Formatting Panel). The panel sets this
/// view's frame; the view lays its contents out against its own bounds.
final class YougramQuickFormattingPanelView: UIView {
    static let height: CGFloat = 40.0
    static let spacing: CGFloat = 6.0

    private static let sideInset: CGFloat = 6.0
    private static let minButtonWidth: CGFloat = 40.0

    /// A drag that starts on a button scrolls the row (UIScrollView keeps it on the control by default).
    private final class ScrollView: UIScrollView {
        override func touchesShouldCancel(in view: UIView) -> Bool {
            return true
        }
    }

    private struct ButtonItem {
        let action: YougramQuickFormattingAction
        let button: HighlightTrackingButton
        let iconView: UIImageView
    }

    private let backgroundView: GlassBackgroundView
    private let scrollView: ScrollView
    private var items: [ButtonItem] = []
    private var currentActions: [YougramQuickFormattingAction] = []
    private var currentIconColor: UIColor?

    var performAction: ((YougramQuickFormattingAction) -> Void)?

    override init(frame: CGRect) {
        self.backgroundView = GlassBackgroundView(frame: CGRect())
        self.scrollView = ScrollView()

        super.init(frame: frame)

        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.showsVerticalScrollIndicator = false
        self.scrollView.alwaysBounceHorizontal = true
        self.scrollView.alwaysBounceVertical = false
        self.scrollView.delaysContentTouches = false
        self.scrollView.canCancelContentTouches = true
        self.scrollView.scrollsToTop = false
        self.scrollView.contentInsetAdjustmentBehavior = .never
        self.scrollView.clipsToBounds = true
        self.scrollView.disablesInteractiveTransitionGestureRecognizer = true

        self.addSubview(self.backgroundView)
        self.backgroundView.contentView.addSubview(self.scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(size: CGSize, theme: PresentationTheme, strings: PresentationStrings, isSecretChat: Bool, glassTintColor: GlassBackgroundView.TintColor, transition: ContainedViewLayoutTransition) {
        let actions = YougramQuickFormattingAction.available(isSecretChat: isSecretChat)
        let iconColor = theme.chat.inputPanel.panelControlColor

        if actions != self.currentActions {
            self.currentActions = actions
            for item in self.items {
                item.button.removeFromSuperview()
            }
            self.items = actions.map { action -> ButtonItem in
                let button = HighlightTrackingButton()
                button.isAccessibilityElement = true
                button.accessibilityTraits = [.button]
                let iconView = UIImageView()
                iconView.isUserInteractionEnabled = false
                iconView.contentMode = .center
                iconView.image = UIImage(systemName: action.symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17.0, weight: .medium))?.withRenderingMode(.alwaysTemplate)
                button.addSubview(iconView)
                button.highligthedChanged = { [weak iconView] highlighted in
                    guard let iconView else {
                        return
                    }
                    if highlighted {
                        iconView.layer.removeAnimation(forKey: "opacity")
                        iconView.alpha = 0.4
                    } else {
                        iconView.alpha = 1.0
                        iconView.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                    }
                }
                button.addTarget(self, action: #selector(self.buttonPressed(_:)), for: .touchUpInside)
                self.scrollView.addSubview(button)
                return ButtonItem(action: action, button: button, iconView: iconView)
            }
            self.currentIconColor = nil
        }

        if self.currentIconColor != iconColor {
            self.currentIconColor = iconColor
            for item in self.items {
                item.iconView.tintColor = iconColor
            }
        }
        for item in self.items {
            item.button.accessibilityLabel = item.action.title(strings: strings)
        }

        let bounds = CGRect(origin: CGPoint(), size: size)
        transition.updateFrame(view: self.backgroundView, frame: bounds)
        self.backgroundView.update(size: size, cornerRadius: size.height * 0.5, isDark: theme.overallDarkAppearance, tintColor: glassTintColor, transition: ComponentTransition(transition))

        // The row fills the capsule while it fits, and scrolls when it does not.
        let sideInset = YougramQuickFormattingPanelView.sideInset
        let count = CGFloat(max(1, self.items.count))
        let buttonWidth = max(YougramQuickFormattingPanelView.minButtonWidth, floor((size.width - sideInset * 2.0) / count))
        let contentWidth = sideInset * 2.0 + buttonWidth * CGFloat(self.items.count)

        self.scrollView.frame = bounds
        self.scrollView.contentSize = CGSize(width: contentWidth, height: size.height)
        for i in 0 ..< self.items.count {
            let item = self.items[i]
            let buttonFrame = CGRect(x: sideInset + buttonWidth * CGFloat(i), y: 0.0, width: buttonWidth, height: size.height)
            item.button.frame = buttonFrame
            let iconSize = item.iconView.image?.size ?? CGSize(width: 24.0, height: 24.0)
            item.iconView.frame = CGRect(origin: CGPoint(x: floor((buttonFrame.width - iconSize.width) * 0.5), y: floor((buttonFrame.height - iconSize.height) * 0.5)), size: iconSize)
        }
    }

    /// Back to the row's start, for the next time the panel appears.
    func resetScrollPosition() {
        self.scrollView.setContentOffset(CGPoint(), animated: false)
    }

    @objc private func buttonPressed(_ sender: UIButton) {
        guard let item = self.items.first(where: { $0.button === sender }) else {
            return
        }
        self.performAction?(item.action)
    }
}
