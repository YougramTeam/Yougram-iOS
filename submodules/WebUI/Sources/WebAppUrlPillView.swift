import Foundation
import UIKit
import Display
import ComponentFlow
import TelegramPresentationData
import GlassBackgroundComponent

func webAppDisplayDomain(from urlString: String) -> String? {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return nil
    }
    let parsed = URL(string: trimmed) ?? URL(string: "https://\(trimmed)")
    guard var host = parsed?.host, !host.isEmpty else {
        return nil
    }
    if host.lowercased().hasPrefix("www.") {
        host = String(host.dropFirst(4))
    }
    return host.isEmpty ? nil : host.lowercased()
}

final class WebAppUrlPillView: UIView, UIGestureRecognizerDelegate {
    private let backgroundView = GlassBackgroundView()

    private let collapsedContainer = UIView()
    private let lockImageView = UIImageView()
    private let domainLabel = UILabel()

    private let expandedContainer = UIView()
    private let urlScrollView = UIScrollView()
    private let fullUrlLabel = UILabel()
    private let copyButton = HighlightTrackingButton()
    private let copyIconView = UIImageView()

    private var tapRecognizer: UITapGestureRecognizer?
    private var longPressRecognizer: UILongPressGestureRecognizer?

    private var currentUrl: String?
    private var currentTheme: PresentationTheme?
    private var currentPrimaryTextColor: UIColor?
    private var currentSecondaryTextColor: UIColor?
    private var currentIsDark = false
    private var currentCompact = false
    private var currentSize: CGSize = .zero

    private(set) var isExpanded = false

    var onCopyUrl: ((String) -> Void)?
    var onLongPressUrl: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.backgroundView.clipsToBounds = true
        self.addSubview(self.backgroundView)

        self.collapsedContainer.isUserInteractionEnabled = false
        self.collapsedContainer.clipsToBounds = true
        self.backgroundView.contentView.addSubview(self.collapsedContainer)

        self.lockImageView.contentMode = .scaleAspectFit
        self.collapsedContainer.addSubview(self.lockImageView)

        self.domainLabel.numberOfLines = 1
        self.domainLabel.textAlignment = .center
        self.domainLabel.lineBreakMode = .byTruncatingMiddle
        self.collapsedContainer.addSubview(self.domainLabel)

        self.expandedContainer.clipsToBounds = true
        self.expandedContainer.alpha = 0.0
        self.expandedContainer.isHidden = true
        self.backgroundView.contentView.addSubview(self.expandedContainer)

        self.urlScrollView.showsHorizontalScrollIndicator = false
        self.urlScrollView.showsVerticalScrollIndicator = false
        self.urlScrollView.alwaysBounceHorizontal = true
        self.urlScrollView.alwaysBounceVertical = false
        self.expandedContainer.addSubview(self.urlScrollView)

        self.fullUrlLabel.numberOfLines = 1
        self.fullUrlLabel.lineBreakMode = .byClipping
        self.urlScrollView.addSubview(self.fullUrlLabel)

        self.copyIconView.contentMode = .scaleAspectFit
        self.copyIconView.isUserInteractionEnabled = false
        self.copyButton.addSubview(self.copyIconView)
        self.expandedContainer.addSubview(self.copyButton)

        self.copyButton.highligthedChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            if highlighted {
                self.copyIconView.layer.removeAnimation(forKey: "opacity")
                self.copyIconView.alpha = 0.45
            } else {
                self.copyIconView.alpha = 1.0
                self.copyIconView.layer.animateAlpha(from: 0.45, to: 1.0, duration: 0.2)
            }
        }
        self.copyButton.addTarget(self, action: #selector(self.copyPressed), for: .touchUpInside)

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleTap(_:)))
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delegate = self
        self.backgroundView.addGestureRecognizer(tapRecognizer)
        self.tapRecognizer = tapRecognizer

        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(self.handleLongPress(_:)))
        longPressRecognizer.minimumPressDuration = 0.35
        self.backgroundView.addGestureRecognizer(longPressRecognizer)
        self.longPressRecognizer = longPressRecognizer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.isHidden || self.alpha < 0.01 || !self.isUserInteractionEnabled {
            return nil
        }
        let convertedPoint = self.convert(point, to: self.backgroundView)
        guard self.backgroundView.bounds.contains(convertedPoint) else {
            return nil
        }
        return super.hitTest(point, with: event)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === self.tapRecognizer && self.isExpanded {
            let point = touch.location(in: self.expandedContainer)
            if self.copyButton.frame.insetBy(dx: -4.0, dy: -4.0).contains(point) {
                return false
            }
        }
        return true
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, self.currentUrl != nil else {
            return
        }
        self.isExpanded.toggle()
        if self.isExpanded {
            self.urlScrollView.setContentOffset(.zero, animated: false)
        }
        self.relayout(transition: .spring(duration: 0.32))
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let url = self.currentUrl else {
            return
        }
        self.onLongPressUrl?(url)
    }

    @objc private func copyPressed() {
        guard let url = self.currentUrl else {
            return
        }
        UIPasteboard.general.string = url
        self.onCopyUrl?(url)
    }

    func update(
        url: String?,
        theme: PresentationTheme,
        primaryTextColor: UIColor?,
        secondaryTextColor: UIColor?,
        isDark: Bool,
        compact: Bool,
        size: CGSize,
        transition: ComponentTransition
    ) {
        if url != self.currentUrl {
            if url == nil || self.currentUrl == nil {
                self.isExpanded = false
            }
            self.currentUrl = url
        }
        self.currentTheme = theme
        self.currentPrimaryTextColor = primaryTextColor
        self.currentSecondaryTextColor = secondaryTextColor
        self.currentIsDark = isDark
        self.currentCompact = compact
        self.currentSize = size

        self.relayout(transition: transition)
    }

    private func relayout(transition: ComponentTransition) {
        guard let url = self.currentUrl,
              let domain = webAppDisplayDomain(from: url),
              let theme = self.currentTheme,
              self.currentSize.width > 1.0,
              self.currentSize.height > 1.0 else {
            return
        }

        let primaryColor = self.currentPrimaryTextColor ?? theme.rootController.navigationBar.primaryTextColor
        let secondaryColor = self.currentSecondaryTextColor ?? theme.rootController.navigationBar.secondaryTextColor
        let pillHeight = min(self.currentSize.height, self.currentCompact ? 30.0 : 36.0)
        let horizontalPadding: CGFloat = self.currentCompact ? 11.0 : 14.0

        let isHttps = URL(string: url)?.scheme?.lowercased() == "https"
        self.lockImageView.isHidden = !isHttps
        if isHttps {
            let lockConfig = UIImage.SymbolConfiguration(pointSize: self.currentCompact ? 9.5 : 11.0, weight: .semibold)
            self.lockImageView.image = UIImage(systemName: "lock.fill", withConfiguration: lockConfig)?
                .withTintColor(secondaryColor, renderingMode: .alwaysOriginal)
        }

        self.domainLabel.font = Font.medium(self.currentCompact ? 13.0 : 15.0)
        self.domainLabel.textColor = primaryColor
        self.domainLabel.text = domain

        let copyConfig = UIImage.SymbolConfiguration(pointSize: self.currentCompact ? 12.0 : 14.0, weight: .medium)
        self.copyIconView.image = UIImage(systemName: "doc.on.doc", withConfiguration: copyConfig)?
            .withTintColor(primaryColor, renderingMode: .alwaysOriginal)

        self.fullUrlLabel.font = Font.regular(self.currentCompact ? 12.5 : 14.0)
        self.fullUrlLabel.textColor = primaryColor
        self.fullUrlLabel.text = url

        let lockSize = isHttps ? self.lockImageView.sizeThatFits(CGSize(width: 14.0, height: pillHeight)) : .zero
        let lockSpacing: CGFloat = isHttps ? (self.currentCompact ? 4.0 : 5.0) : 0.0
        let domainNaturalSize = self.domainLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: pillHeight))

        let collapsedContentWidth = lockSize.width + lockSpacing + domainNaturalSize.width
        let collapsedWidth = min(self.currentSize.width, max(self.currentCompact ? 76.0 : 96.0, ceil(collapsedContentWidth + horizontalPadding * 2.0)))
        let expandedWidth = self.currentSize.width

        let backgroundWidth = self.isExpanded ? expandedWidth : collapsedWidth
        let backgroundSize = CGSize(width: backgroundWidth, height: pillHeight)
        let backgroundFrame = CGRect(
            origin: CGPoint(
                x: floorToScreenPixels((self.currentSize.width - backgroundWidth) * 0.5),
                y: floorToScreenPixels((self.currentSize.height - pillHeight) * 0.5)
            ),
            size: backgroundSize
        )

        self.backgroundView.update(
            size: backgroundSize,
            cornerRadius: pillHeight * 0.5,
            isDark: self.currentIsDark,
            tintColor: .init(kind: .panel),
            isInteractive: true,
            transition: transition
        )
        transition.setFrame(view: self.backgroundView, frame: backgroundFrame)

        // Layout collapsed domain + optional lock centered inside capsule.
        let innerCollapsedFrame = CGRect(origin: .zero, size: backgroundSize)
        transition.setFrame(view: self.collapsedContainer, frame: innerCollapsedFrame)
        let maxDomainWidth = max(12.0, backgroundSize.width - horizontalPadding * 2.0 - lockSize.width - lockSpacing)
        let drawnDomainWidth = min(ceil(domainNaturalSize.width), maxDomainWidth)
        let totalInnerWidth = lockSize.width + lockSpacing + drawnDomainWidth
        let startX = floorToScreenPixels((backgroundSize.width - totalInnerWidth) * 0.5)
        if isHttps {
            transition.setFrame(
                view: self.lockImageView,
                frame: CGRect(
                    origin: CGPoint(x: startX, y: floorToScreenPixels((backgroundSize.height - lockSize.height) * 0.5)),
                    size: lockSize
                )
            )
        }
        let domainHeight = ceil(domainNaturalSize.height)
        transition.setFrame(
            view: self.domainLabel,
            frame: CGRect(
                origin: CGPoint(x: startX + lockSize.width + lockSpacing, y: floorToScreenPixels((backgroundSize.height - domainHeight) * 0.5)),
                size: CGSize(width: drawnDomainWidth, height: domainHeight)
            )
        )

        // Layout expanded scrollable full URL + trailing copy button inside capsule.
        let copyButtonWidth = pillHeight
        let expandedFrame = CGRect(origin: .zero, size: backgroundSize)
        transition.setFrame(view: self.expandedContainer, frame: expandedFrame)

        let leftPadding: CGFloat = self.currentCompact ? 11.0 : 14.0
        let copyFrame = CGRect(
            origin: CGPoint(x: max(0.0, backgroundSize.width - copyButtonWidth - 2.0), y: 0.0),
            size: CGSize(width: copyButtonWidth, height: backgroundSize.height)
        )
        transition.setFrame(view: self.copyButton, frame: copyFrame)
        let copyIconSize = self.copyIconView.sizeThatFits(CGSize(width: 20.0, height: 20.0))
        self.copyIconView.frame = CGRect(
            origin: CGPoint(
                x: floorToScreenPixels((copyFrame.width - copyIconSize.width) * 0.5),
                y: floorToScreenPixels((copyFrame.height - copyIconSize.height) * 0.5)
            ),
            size: copyIconSize
        )

        let scrollFrame = CGRect(
            origin: CGPoint(x: leftPadding, y: 0.0),
            size: CGSize(width: max(0.0, copyFrame.minX - leftPadding - 2.0), height: backgroundSize.height)
        )
        transition.setFrame(view: self.urlScrollView, frame: scrollFrame)
        let fullUrlSize = self.fullUrlLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: backgroundSize.height))
        let fullUrlWidth = ceil(fullUrlSize.width)
        let fullUrlHeight = ceil(fullUrlSize.height)
        self.fullUrlLabel.frame = CGRect(
            origin: CGPoint(x: 0.0, y: floorToScreenPixels((scrollFrame.height - fullUrlHeight) * 0.5)),
            size: CGSize(width: fullUrlWidth, height: fullUrlHeight)
        )
        self.urlScrollView.contentSize = CGSize(width: max(scrollFrame.width, fullUrlWidth), height: scrollFrame.height)

        // Cross-fade collapsed vs expanded contents cleanly.
        self.collapsedContainer.isHidden = false
        self.expandedContainer.isHidden = false
        let isExpanded = self.isExpanded
        transition.setAlpha(view: self.collapsedContainer, alpha: isExpanded ? 0.0 : 1.0, completion: { [weak self] completed in
            if completed, let self, self.isExpanded {
                self.collapsedContainer.isHidden = true
            }
        })
        transition.setAlpha(view: self.expandedContainer, alpha: isExpanded ? 1.0 : 0.0, completion: { [weak self] completed in
            if completed, let self, !self.isExpanded {
                self.expandedContainer.isHidden = true
            }
        })

        self.accessibilityLabel = domain
        self.accessibilityValue = url
    }
}
