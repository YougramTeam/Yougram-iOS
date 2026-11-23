import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import UndoUI

// MARK: - Helpers

private func statusText(for progress: YougramAdvancedForwardProgress, strings: PresentationStrings) -> String {
    switch progress.phase {
    case .preparing:
        return strings.Yougram_AdvancedForward_Preparing
    case let .downloading(current, total, currentMediaProgress):
        let currentPercent = Int(round(max(0.0, min(1.0, currentMediaProgress)) * 100.0))
        if currentPercent > 0 {
            return strings.Yougram_AdvancedForward_DownloadingPercent("\(current)", "\(total)", "\(currentPercent)").string
        } else {
            return strings.Yougram_AdvancedForward_Downloading("\(current)", "\(total)").string
        }
    case .sending:
        return strings.Yougram_AdvancedForward_Sending
    }
}

// MARK: - Floating Background Circle Button

private final class YougramAdvancedForwardFloatingButton: UIView {
    private static let buttonSize: CGFloat = 58.0

    private let onTap: () -> Void

    private let glassView: UIVisualEffectView
    private let ringContainerView: UIView
    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private let iconView: UIImageView

    private var isSpinning = false
    private var isDarkTheme = false
    private var lastCenterRatio: CGPoint?

    init(accentColor: UIColor, isDark: Bool, onTap: @escaping () -> Void) {
        self.onTap = onTap
        self.isDarkTheme = isDark

        let diameter = Self.buttonSize
        let effect = UIBlurEffect(style: isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight)
        self.glassView = UIVisualEffectView(effect: effect)
        self.ringContainerView = UIView(frame: CGRect(x: 0.0, y: 0.0, width: diameter, height: diameter))
        self.iconView = UIImageView(frame: CGRect(x: 0.0, y: 0.0, width: diameter, height: diameter))

        super.init(frame: CGRect(x: 0.0, y: 0.0, width: diameter, height: diameter))

        self.backgroundColor = .clear
        self.layer.shadowColor = UIColor.black.cgColor
        self.layer.shadowOpacity = isDark ? 0.42 : 0.22
        self.layer.shadowRadius = 10.0
        self.layer.shadowOffset = CGSize(width: 0.0, height: 4.0)

        self.glassView.frame = self.bounds
        self.glassView.layer.cornerRadius = diameter * 0.5
        self.glassView.clipsToBounds = true
        self.glassView.layer.borderWidth = 0.75
        self.glassView.layer.borderColor = (isDark ? UIColor.white.withAlphaComponent(0.16) : UIColor.black.withAlphaComponent(0.08)).cgColor
        self.glassView.isUserInteractionEnabled = false
        self.addSubview(self.glassView)

        let center = CGPoint(x: diameter * 0.5, y: diameter * 0.5)
        let circlePath = UIBezierPath(
            arcCenter: center,
            radius: diameter * 0.5 - 4.0,
            startAngle: -CGFloat.pi * 0.5,
            endAngle: CGFloat.pi * 1.5,
            clockwise: true
        ).cgPath

        self.ringContainerView.isUserInteractionEnabled = false
        self.addSubview(self.ringContainerView)

        self.trackLayer.frame = self.bounds
        self.trackLayer.path = circlePath
        self.trackLayer.fillColor = nil
        self.trackLayer.lineWidth = 3.2
        self.trackLayer.strokeColor = accentColor.withAlphaComponent(0.20).cgColor
        self.ringContainerView.layer.addSublayer(self.trackLayer)

        self.progressLayer.bounds = self.bounds
        self.progressLayer.position = center
        self.progressLayer.path = circlePath
        self.progressLayer.fillColor = nil
        self.progressLayer.lineWidth = 3.2
        self.progressLayer.lineCap = .round
        self.progressLayer.strokeColor = accentColor.cgColor
        self.progressLayer.strokeStart = 0.0
        self.progressLayer.strokeEnd = 0.28
        self.ringContainerView.layer.addSublayer(self.progressLayer)

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 20.0, weight: .semibold)
        self.iconView.image = UIImage(systemName: "arrowshape.turn.up.right.fill", withConfiguration: symbolConfig)?.withRenderingMode(.alwaysTemplate)
        self.iconView.tintColor = accentColor
        self.iconView.contentMode = .center
        self.iconView.isUserInteractionEnabled = false
        self.addSubview(self.iconView)

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleTap))
        self.addGestureRecognizer(tapRecognizer)

        let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:)))
        self.addGestureRecognizer(panRecognizer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        UIView.animate(withDuration: 0.14) {
            self.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        UIView.animate(withDuration: 0.22, delay: 0.0, usingSpringWithDamping: 0.7, initialVelocity: 0.5, options: [.allowUserInteraction], animations: {
            self.transform = .identity
        }, completion: nil)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        UIView.animate(withDuration: 0.18) {
            self.transform = .identity
        }
    }

    @objc private func handleTap() {
        self.onTap()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let superview = self.superview else {
            return
        }
        let translation = recognizer.translation(in: superview)
        recognizer.setTranslation(.zero, in: superview)

        switch recognizer.state {
        case .began, .changed:
            var newCenter = CGPoint(x: self.center.x + translation.x, y: self.center.y + translation.y)
            let half = Self.buttonSize * 0.5
            let minX = half + 8.0
            let maxX = max(minX, superview.bounds.width - half - 8.0)
            let minY = max(half + 12.0, superview.safeAreaInsets.top + half + 12.0)
            let maxY = max(minY, superview.bounds.height - superview.safeAreaInsets.bottom - half - 12.0)
            newCenter.x = min(max(newCenter.x, minX), maxX)
            newCenter.y = min(max(newCenter.y, minY), maxY)
            self.center = newCenter
        case .ended, .cancelled, .failed:
            self.snapToNearestEdge(in: superview, animated: true)
        default:
            break
        }
    }

    func attach(to containerView: UIView, initialCenterRatio: CGPoint?) {
        if self.superview !== containerView {
            self.removeFromSuperview()
            containerView.addSubview(self)
        }
        self.layer.zPosition = 9999.0
        containerView.bringSubviewToFront(self)

        if let ratio = initialCenterRatio ?? self.lastCenterRatio, containerView.bounds.width > 0.0, containerView.bounds.height > 0.0 {
            self.center = CGPoint(x: containerView.bounds.width * ratio.x, y: containerView.bounds.height * ratio.y)
        } else {
            let half = Self.buttonSize * 0.5
            let defaultX = containerView.bounds.width - containerView.safeAreaInsets.right - 14.0 - half
            let defaultY = max(containerView.safeAreaInsets.top + 88.0, containerView.bounds.height * 0.68)
            self.center = CGPoint(x: defaultX, y: defaultY)
        }
        self.snapToNearestEdge(in: containerView, animated: false)

        self.alpha = 0.0
        self.transform = CGAffineTransform(scaleX: 0.45, y: 0.45)
        UIView.animate(withDuration: 0.34, delay: 0.0, usingSpringWithDamping: 0.72, initialVelocity: 0.6, options: [.allowUserInteraction], animations: {
            self.alpha = 1.0
            self.transform = .identity
        }, completion: nil)
    }

    var currentCenterRatio: CGPoint? {
        return self.lastCenterRatio
    }

    private func snapToNearestEdge(in containerView: UIView, animated: Bool) {
        let bounds = containerView.bounds
        guard bounds.width > 0.0, bounds.height > 0.0 else {
            return
        }
        let insets = containerView.safeAreaInsets
        let half = Self.buttonSize * 0.5
        let leftX = insets.left + 14.0 + half
        let rightX = max(leftX, bounds.width - insets.right - 14.0 - half)
        let targetX: CGFloat = (self.center.x < bounds.midX) ? leftX : rightX

        let minY = insets.top + 64.0 + half
        let maxY = max(minY, bounds.height - insets.bottom - 96.0 - half)
        let targetY = min(max(self.center.y, minY), maxY)

        let finalCenter = CGPoint(x: targetX, y: targetY)
        self.lastCenterRatio = CGPoint(x: finalCenter.x / bounds.width, y: finalCenter.y / bounds.height)

        if animated {
            UIView.animate(withDuration: 0.36, delay: 0.0, usingSpringWithDamping: 0.78, initialVelocity: 0.4, options: [.allowUserInteraction], animations: {
                self.center = finalCenter
            }, completion: nil)
        } else {
            self.center = finalCenter
        }
    }

    func update(progress: YougramAdvancedForwardProgress, accentColor: UIColor, isDark: Bool) {
        if self.isDarkTheme != isDark {
            self.isDarkTheme = isDark
            self.glassView.effect = UIBlurEffect(style: isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight)
            self.glassView.layer.borderColor = (isDark ? UIColor.white.withAlphaComponent(0.16) : UIColor.black.withAlphaComponent(0.08)).cgColor
            self.layer.shadowOpacity = isDark ? 0.42 : 0.22
        }

        self.trackLayer.strokeColor = accentColor.withAlphaComponent(0.20).cgColor
        self.progressLayer.strokeColor = accentColor.cgColor
        self.iconView.tintColor = accentColor

        let indeterminate = progress.isIndeterminate || progress.fraction < 0.04
        if indeterminate {
            self.progressLayer.strokeEnd = 0.28
            if !self.isSpinning {
                self.isSpinning = true
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0.0
                spin.toValue = Double.pi * 2.0
                spin.duration = 0.95
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                self.progressLayer.add(spin, forKey: "yougram.advancedForward.spin")
            }
        } else {
            if self.isSpinning {
                self.isSpinning = false
                self.progressLayer.removeAnimation(forKey: "yougram.advancedForward.spin")
                self.progressLayer.transform = CATransform3DIdentity
            }
            let targetEnd = CGFloat(max(0.06, min(1.0, progress.fraction)))
            self.progressLayer.strokeEnd = targetEnd
        }
    }

    func animateOutAndRemove() {
        UIView.animate(withDuration: 0.22, animations: {
            self.alpha = 0.0
            self.transform = CGAffineTransform(scaleX: 0.55, y: 0.55)
        }, completion: { _ in
            self.progressLayer.removeAllAnimations()
            self.removeFromSuperview()
        })
    }
}

// MARK: - Modal Progress Sheet

private final class YougramAdvancedForwardProgressNode: ASDisplayNode {
    private let theme: PresentationTheme
    private let strings: PresentationStrings
    private let targetSummary: String
    private let messageCount: Int
    private let onBackground: () -> Void
    private let onCancel: () -> Void

    private let dimControl = UIControl()
    private let cardShadowView = UIView()
    private let cardView = UIView()
    private let badgeView = UIView()
    private let badgeIconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusLabel = UILabel()
    private let percentLabel = UILabel()
    private let progressTrackView = UIView()
    private let progressFillView = UIView()
    private let backgroundButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    private var currentProgress: YougramAdvancedForwardProgress

    init(
        presentationData: PresentationData,
        targetSummary: String,
        messageCount: Int,
        initialProgress: YougramAdvancedForwardProgress,
        onBackground: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.theme = presentationData.theme
        self.strings = presentationData.strings
        self.targetSummary = targetSummary
        self.messageCount = messageCount
        self.currentProgress = initialProgress
        self.onBackground = onBackground
        self.onCancel = onCancel

        super.init()

        self.backgroundColor = .clear

        self.dimControl.backgroundColor = UIColor(white: 0.0, alpha: 0.42)
        self.dimControl.alpha = 0.0
        self.dimControl.addTarget(self, action: #selector(self.backgroundPressed), for: .touchUpInside)
        self.view.addSubview(self.dimControl)

        self.cardShadowView.layer.shadowColor = UIColor.black.cgColor
        self.cardShadowView.layer.shadowOpacity = self.theme.overallDarkAppearance ? 0.45 : 0.18
        self.cardShadowView.layer.shadowRadius = 22.0
        self.cardShadowView.layer.shadowOffset = CGSize(width: 0.0, height: 10.0)
        self.cardShadowView.alpha = 0.0
        self.view.addSubview(self.cardShadowView)

        self.cardView.backgroundColor = self.theme.list.itemBlocksBackgroundColor
        self.cardView.layer.cornerRadius = 24.0
        self.cardView.clipsToBounds = true
        self.cardShadowView.addSubview(self.cardView)

        let accentColor = self.theme.list.itemAccentColor

        self.badgeView.backgroundColor = accentColor.withAlphaComponent(0.14)
        self.badgeView.layer.cornerRadius = 26.0
        self.cardView.addSubview(self.badgeView)

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 22.0, weight: .semibold)
        self.badgeIconView.image = UIImage(systemName: "arrowshape.turn.up.right.fill", withConfiguration: symbolConfig)?.withRenderingMode(.alwaysTemplate)
        self.badgeIconView.tintColor = accentColor
        self.badgeIconView.contentMode = .center
        self.badgeView.addSubview(self.badgeIconView)

        self.titleLabel.font = Font.semibold(18.0)
        self.titleLabel.textColor = self.theme.list.itemPrimaryTextColor
        self.titleLabel.textAlignment = .center
        self.titleLabel.text = self.strings.Yougram_AdvancedForward_Title
        self.cardView.addSubview(self.titleLabel)

        let countText = messageCount == 1
            ? self.strings.Yougram_AdvancedForward_SubtitleOne
            : self.strings.Yougram_AdvancedForward_SubtitleMany("\(messageCount)").string
        self.subtitleLabel.font = Font.regular(13.0)
        self.subtitleLabel.textColor = self.theme.list.itemSecondaryTextColor
        self.subtitleLabel.textAlignment = .center
        self.subtitleLabel.numberOfLines = 2
        self.subtitleLabel.text = targetSummary.isEmpty ? countText : "\(targetSummary) • \(countText)"
        self.cardView.addSubview(self.subtitleLabel)

        self.statusLabel.font = Font.medium(14.0)
        self.statusLabel.textColor = self.theme.list.itemPrimaryTextColor
        self.statusLabel.textAlignment = .left
        self.statusLabel.lineBreakMode = .byTruncatingTail
        self.cardView.addSubview(self.statusLabel)

        self.percentLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13.0, weight: .semibold)
        self.percentLabel.textColor = accentColor
        self.percentLabel.textAlignment = .right
        self.cardView.addSubview(self.percentLabel)

        self.progressTrackView.backgroundColor = self.theme.list.itemPrimaryTextColor.withAlphaComponent(0.10)
        self.progressTrackView.layer.cornerRadius = 3.0
        self.progressTrackView.clipsToBounds = true
        self.cardView.addSubview(self.progressTrackView)

        self.progressFillView.backgroundColor = accentColor
        self.progressFillView.layer.cornerRadius = 3.0
        self.progressTrackView.addSubview(self.progressFillView)

        self.backgroundButton.backgroundColor = accentColor
        self.backgroundButton.setTitle(self.strings.Yougram_AdvancedForward_Background, for: .normal)
        self.backgroundButton.setTitleColor(.white, for: .normal)
        self.backgroundButton.titleLabel?.font = Font.semibold(15.0)
        self.backgroundButton.layer.cornerRadius = 14.0
        self.backgroundButton.addTarget(self, action: #selector(self.backgroundPressed), for: .touchUpInside)
        self.cardView.addSubview(self.backgroundButton)

        self.cancelButton.backgroundColor = self.theme.list.itemDestructiveColor.withAlphaComponent(0.12)
        self.cancelButton.setTitle(self.strings.Yougram_AdvancedForward_Cancel, for: .normal)
        self.cancelButton.setTitleColor(self.theme.list.itemDestructiveColor, for: .normal)
        self.cancelButton.titleLabel?.font = Font.semibold(15.0)
        self.cancelButton.layer.cornerRadius = 14.0
        self.cancelButton.addTarget(self, action: #selector(self.cancelPressed), for: .touchUpInside)
        self.cardView.addSubview(self.cancelButton)

        self.updateProgress(initialProgress, animated: false)
    }

    @objc private func backgroundPressed() {
        self.onBackground()
    }

    @objc private func cancelPressed() {
        self.onCancel()
    }

    func animateIn() {
        self.cardShadowView.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.28, delay: 0.0, usingSpringWithDamping: 0.84, initialVelocity: 0.5, options: [.allowUserInteraction], animations: {
            self.dimControl.alpha = 1.0
            self.cardShadowView.alpha = 1.0
            self.cardShadowView.transform = .identity
        }, completion: nil)
    }

    func animateOut(completion: @escaping () -> Void) {
        UIView.animate(withDuration: 0.20, animations: {
            self.dimControl.alpha = 0.0
            self.cardShadowView.alpha = 0.0
            self.cardShadowView.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        }, completion: { _ in
            completion()
        })
    }

    func updateProgress(_ progress: YougramAdvancedForwardProgress, animated: Bool) {
        self.currentProgress = progress
        self.statusLabel.text = statusText(for: progress, strings: self.strings)
        if progress.isIndeterminate {
            self.percentLabel.text = "…"
        } else {
            let pct = Int(round(max(0.0, min(1.0, progress.fraction)) * 100.0))
            self.percentLabel.text = "\(pct)%"
        }
        self.layoutProgressFill(animated: animated)
    }

    private func layoutProgressFill(animated: Bool) {
        let trackWidth = self.progressTrackView.bounds.width
        let trackHeight = self.progressTrackView.bounds.height
        guard trackWidth > 0.0, trackHeight > 0.0 else {
            return
        }
        let effectiveFraction: CGFloat
        if self.currentProgress.isIndeterminate {
            effectiveFraction = 0.16
        } else {
            effectiveFraction = CGFloat(max(0.03, min(1.0, self.currentProgress.fraction)))
        }
        let targetFrame = CGRect(x: 0.0, y: 0.0, width: max(6.0, trackWidth * effectiveFraction), height: trackHeight)
        if animated {
            UIView.animate(withDuration: 0.16, delay: 0.0, options: [.beginFromCurrentState, .curveEaseOut], animations: {
                self.progressFillView.frame = targetFrame
            }, completion: nil)
        } else {
            self.progressFillView.frame = targetFrame
        }
    }

    func containerLayoutUpdated(layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        let bounds = CGRect(origin: .zero, size: layout.size)
        self.dimControl.frame = bounds

        let horizontalMargin: CGFloat = 24.0
        let cardWidth = min(332.0, max(240.0, layout.size.width - horizontalMargin * 2.0))
        let contentInset: CGFloat = 22.0
        let innerWidth = cardWidth - contentInset * 2.0

        let badgeSize: CGFloat = 52.0
        let subtitleSize = self.subtitleLabel.sizeThatFits(CGSize(width: innerWidth, height: 60.0))

        var y: CGFloat = 24.0
        let badgeFrame = CGRect(x: (cardWidth - badgeSize) * 0.5, y: y, width: badgeSize, height: badgeSize)
        y += badgeSize + 14.0

        let titleFrame = CGRect(x: contentInset, y: y, width: innerWidth, height: 22.0)
        y += 22.0 + 6.0

        let subtitleFrame = CGRect(x: contentInset, y: y, width: innerWidth, height: ceil(subtitleSize.height))
        y += ceil(subtitleSize.height) + 20.0

        let percentWidth: CGFloat = 46.0
        let statusFrame = CGRect(x: contentInset, y: y, width: innerWidth - percentWidth - 8.0, height: 18.0)
        let percentFrame = CGRect(x: cardWidth - contentInset - percentWidth, y: y, width: percentWidth, height: 18.0)
        y += 18.0 + 10.0

        let trackFrame = CGRect(x: contentInset, y: y, width: innerWidth, height: 6.0)
        y += 6.0 + 24.0

        let buttonSpacing: CGFloat = 10.0
        let buttonWidth = (innerWidth - buttonSpacing) * 0.5
        let buttonHeight: CGFloat = 46.0
        let cancelFrame = CGRect(x: contentInset, y: y, width: buttonWidth, height: buttonHeight)
        let backgroundFrame = CGRect(x: contentInset + buttonWidth + buttonSpacing, y: y, width: buttonWidth, height: buttonHeight)
        y += buttonHeight + 20.0

        let cardHeight = y
        let cardBounds = CGRect(origin: .zero, size: CGSize(width: cardWidth, height: cardHeight))
        let shadowFrame = CGRect(
            x: floor((layout.size.width - cardWidth) * 0.5),
            y: floor((layout.size.height - cardHeight) * 0.5),
            width: cardWidth,
            height: cardHeight
        )

        let applyFrames = {
            self.cardShadowView.frame = shadowFrame
            self.cardView.frame = cardBounds
            self.badgeView.frame = badgeFrame
            self.badgeIconView.frame = self.badgeView.bounds
            self.titleLabel.frame = titleFrame
            self.subtitleLabel.frame = subtitleFrame
            self.statusLabel.frame = statusFrame
            self.percentLabel.frame = percentFrame
            self.progressTrackView.frame = trackFrame
            self.cancelButton.frame = cancelFrame
            self.backgroundButton.frame = backgroundFrame
            self.layoutProgressFill(animated: false)
        }

        if case .animated = transition {
            UIView.animate(withDuration: 0.22, animations: applyFrames)
        } else {
            applyFrames()
        }
    }
}

private final class YougramAdvancedForwardProgressController: ViewController {
    private let presentationData: PresentationData
    private let targetSummary: String
    private let messageCount: Int
    private var currentProgress: YougramAdvancedForwardProgress
    private let onBackground: () -> Void
    private let onCancel: () -> Void

    private var didAnimateIn = false
    private var dismissed = false

    init(
        presentationData: PresentationData,
        targetSummary: String,
        messageCount: Int,
        initialProgress: YougramAdvancedForwardProgress,
        onBackground: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.presentationData = presentationData
        self.targetSummary = targetSummary
        self.messageCount = messageCount
        self.currentProgress = initialProgress
        self.onBackground = onBackground
        self.onCancel = onCancel

        super.init(navigationBarPresentationData: nil)

        self.statusBar.statusBarStyle = .Ignore
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadDisplayNode() {
        self.displayNode = YougramAdvancedForwardProgressNode(
            presentationData: self.presentationData,
            targetSummary: self.targetSummary,
            messageCount: self.messageCount,
            initialProgress: self.currentProgress,
            onBackground: self.onBackground,
            onCancel: self.onCancel
        )
        self.displayNodeDidLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if !self.didAnimateIn {
            self.didAnimateIn = true
            (self.displayNode as? YougramAdvancedForwardProgressNode)?.animateIn()
        }
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        (self.displayNode as? YougramAdvancedForwardProgressNode)?.containerLayoutUpdated(layout: layout, transition: transition)
    }

    func updateProgress(_ progress: YougramAdvancedForwardProgress) {
        self.currentProgress = progress
        if self.isNodeLoaded {
            (self.displayNode as? YougramAdvancedForwardProgressNode)?.updateProgress(progress, animated: true)
        }
    }

    override func dismiss(completion: (() -> Void)? = nil) {
        guard !self.dismissed else {
            completion?()
            return
        }
        self.dismissed = true
        if self.isNodeLoaded, let node = self.displayNode as? YougramAdvancedForwardProgressNode {
            node.animateOut { [weak self] in
                self?.presentingViewController?.dismiss(animated: false, completion: nil)
                completion?()
            }
        } else {
            self.presentingViewController?.dismiss(animated: false, completion: nil)
            completion?()
        }
    }
}

// MARK: - Singleton Task Coordinator

public final class YougramAdvancedForwardManager {
    public static let shared = YougramAdvancedForwardManager()

    private final class ActiveTask {
        let context: AccountContext
        let disposable = MetaDisposable()
        let targetSummary: String
        let messageCount: Int
        let isSavedMessagesOnly: Bool
        var latestProgress: YougramAdvancedForwardProgress
        var isBackgrounded: Bool = false
        var sheetController: YougramAdvancedForwardProgressController?
        var floatingButton: YougramAdvancedForwardFloatingButton?
        var lastFloatingCenterRatio: CGPoint?

        init(
            context: AccountContext,
            targetSummary: String,
            messageCount: Int,
            isSavedMessagesOnly: Bool
        ) {
            self.context = context
            self.targetSummary = targetSummary
            self.messageCount = messageCount
            self.isSavedMessagesOnly = isSavedMessagesOnly
            self.latestProgress = YougramAdvancedForwardProgress(phase: .preparing, fraction: 0.0, isIndeterminate: true)
        }
    }

    private var activeTask: ActiveTask?
    private var rememberedCenterRatio: CGPoint?

    private init() {
    }

    public static func formatTargetSummary(
        peers: [EnginePeer],
        peerMap: [EnginePeer.Id: EnginePeer],
        accountPeerId: EnginePeer.Id,
        strings: PresentationStrings,
        nameDisplayOrder: PresentationPersonNameOrder
    ) -> String {
        var displayPeers: [EnginePeer] = []
        for peer in peers {
            if case let .secretChat(secretPeer) = peer, let regular = peerMap[secretPeer.regularPeerId] {
                displayPeers.append(regular)
            } else {
                displayPeers.append(peer)
            }
        }

        func cleanTitle(for peer: EnginePeer) -> String {
            let raw = peer.id == accountPeerId
                ? strings.DialogList_SavedMessages
                : peer.displayTitle(strings: strings, displayOrder: nameDisplayOrder)
            return raw.replacingOccurrences(of: "**", with: "")
        }

        if displayPeers.count == 1, let first = displayPeers.first {
            return cleanTitle(for: first)
        } else if displayPeers.count == 2, let first = displayPeers.first, let second = displayPeers.last {
            return "\(cleanTitle(for: first)), \(cleanTitle(for: second))"
        } else if let first = displayPeers.first {
            return "\(cleanTitle(for: first)) +\(displayPeers.count - 1)"
        }
        return ""
    }

    public func start(
        context: AccountContext,
        messageIds: [EngineMessage.Id],
        targets: [YougramAdvancedForwardTarget],
        targetSummary: String,
        comment: YougramAdvancedForwardComment? = nil,
        silent: Bool = false,
        scheduleTime: Int32? = nil,
        repeatPeriod: Int32? = nil
    ) {
        let work = {
            let signal = context.engine.messages.yougramAdvancedForward(
                messageIds: messageIds,
                targets: targets,
                comment: comment,
                silent: silent,
                scheduleTime: scheduleTime,
                repeatPeriod: repeatPeriod
            )
            self.beginTask(
                context: context,
                targets: targets,
                targetSummary: targetSummary,
                messageCount: messageIds.count,
                signal: signal
            )
        }
        if Thread.isMainThread {
            work()
        } else {
            Queue.mainQueue().async(work)
        }
    }

    public func startDeletedRecord(
        context: AccountContext,
        record: YougramDeletedMessageRecord,
        targets: [YougramAdvancedForwardTarget],
        targetSummary: String,
        comment: YougramAdvancedForwardComment? = nil,
        silent: Bool = false,
        scheduleTime: Int32? = nil,
        repeatPeriod: Int32? = nil
    ) {
        let work = {
            let signal = context.engine.messages.yougramAdvancedForwardDeletedRecord(
                record: record,
                targets: targets,
                comment: comment,
                silent: silent,
                scheduleTime: scheduleTime,
                repeatPeriod: repeatPeriod
            )
            self.beginTask(
                context: context,
                targets: targets,
                targetSummary: targetSummary,
                messageCount: 1,
                signal: signal
            )
        }
        if Thread.isMainThread {
            work()
        } else {
            Queue.mainQueue().async(work)
        }
    }

    public func moveToBackground() {
        let work = {
            guard let task = self.activeTask, !task.isBackgrounded else {
                return
            }
            task.isBackgrounded = true
            let sheet = task.sheetController
            task.sheetController = nil
            sheet?.dismiss(completion: nil)
            self.showFloatingButton(for: task)
        }
        if Thread.isMainThread {
            work()
        } else {
            Queue.mainQueue().async(work)
        }
    }

    public func presentActiveSheet() {
        let work = {
            guard let task = self.activeTask else {
                return
            }
            task.isBackgrounded = false
            self.hideFloatingButton(for: task)
            self.showSheet(for: task)
        }
        if Thread.isMainThread {
            work()
        } else {
            Queue.mainQueue().async(work)
        }
    }

    public func cancelCurrentTask() {
        let work = {
            guard let task = self.activeTask else {
                return
            }
            self.activeTask = nil
            task.disposable.dispose()
            self.teardownUI(for: task)

            let presentationData = task.context.sharedContext.currentPresentationData.with { $0 }
            self.presentToast(
                content: .info(title: nil, text: presentationData.strings.Yougram_AdvancedForward_Cancelled, timeout: 2.5, customUndoText: nil),
                context: task.context,
                presentationData: presentationData
            )
        }
        if Thread.isMainThread {
            work()
        } else {
            Queue.mainQueue().async(work)
        }
    }

    private func beginTask(
        context: AccountContext,
        targets: [YougramAdvancedForwardTarget],
        targetSummary: String,
        messageCount: Int,
        signal: Signal<YougramAdvancedForwardEvent, NoError>
    ) {
        guard !targets.isEmpty else {
            return
        }

        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        if let existingTask = self.activeTask {
            self.presentToast(
                content: .info(title: nil, text: presentationData.strings.Yougram_AdvancedForward_Busy, timeout: 2.5, customUndoText: nil),
                context: existingTask.context,
                presentationData: presentationData
            )
            if existingTask.isBackgrounded {
                self.presentActiveSheet()
            }
            return
        }

        let isSavedMessagesOnly = (targets.count == 1 && targets.first?.peerId == context.account.peerId)
        let task = ActiveTask(
            context: context,
            targetSummary: targetSummary,
            messageCount: max(1, messageCount),
            isSavedMessagesOnly: isSavedMessagesOnly
        )
        self.activeTask = task
        self.showSheet(for: task)

        task.disposable.set((signal
        |> deliverOnMainQueue).start(next: { [weak self, weak task] event in
            guard let self, let task, self.activeTask === task else {
                return
            }
            self.handle(event: event, for: task)
        }))
    }

    private func handle(event: YougramAdvancedForwardEvent, for task: ActiveTask) {
        let presentationData = task.context.sharedContext.currentPresentationData.with { $0 }
        let strings = presentationData.strings

        switch event {
        case let .progress(progress):
            task.latestProgress = progress
            task.sheetController?.updateProgress(progress)
            if let floatingButton = task.floatingButton {
                floatingButton.update(
                    progress: progress,
                    accentColor: presentationData.theme.list.itemAccentColor,
                    isDark: presentationData.theme.overallDarkAppearance
                )
                floatingButton.superview?.bringSubviewToFront(floatingButton)
            }

        case let .completed(result):
            self.activeTask = nil
            task.disposable.dispose()
            self.teardownUI(for: task)

            if result.sentMessageCount <= 0 {
                self.presentToast(
                    content: .info(title: nil, text: strings.Yougram_AdvancedForward_NothingToForward, timeout: 3.0, customUndoText: nil),
                    context: task.context,
                    presentationData: presentationData
                )
            } else {
                let text: String
                if result.skippedMediaCount > 0 {
                    text = strings.Yougram_AdvancedForward_CompletedWithSkipped("\(result.sentMessageCount)", "\(result.skippedMediaCount)").string
                } else if result.sentMessageCount == 1 {
                    text = strings.Yougram_AdvancedForward_CompletedOne
                } else {
                    text = strings.Yougram_AdvancedForward_CompletedMany("\(result.sentMessageCount)").string
                }
                self.presentToast(
                    content: .forward(savedMessages: task.isSavedMessagesOnly, text: text),
                    context: task.context,
                    presentationData: presentationData
                )
            }

        case .cancelled:
            self.activeTask = nil
            task.disposable.dispose()
            self.teardownUI(for: task)

            self.presentToast(
                content: .info(title: nil, text: strings.Yougram_AdvancedForward_Cancelled, timeout: 2.5, customUndoText: nil),
                context: task.context,
                presentationData: presentationData
            )

        case let .failed(reason):
            self.activeTask = nil
            task.disposable.dispose()
            self.teardownUI(for: task)

            self.presentToast(
                content: .info(title: nil, text: reason ?? strings.Yougram_AdvancedForward_NothingToForward, timeout: 3.0, customUndoText: nil),
                context: task.context,
                presentationData: presentationData
            )
        }
    }

    private func showSheet(for task: ActiveTask) {
        if let existingSheet = task.sheetController {
            existingSheet.updateProgress(task.latestProgress)
            return
        }
        let presentationData = task.context.sharedContext.currentPresentationData.with { $0 }
        let sheet = YougramAdvancedForwardProgressController(
            presentationData: presentationData,
            targetSummary: task.targetSummary,
            messageCount: task.messageCount,
            initialProgress: task.latestProgress,
            onBackground: { [weak self] in
                self?.moveToBackground()
            },
            onCancel: { [weak self] in
                self?.cancelCurrentTask()
            }
        )
        task.sheetController = sheet
        task.context.sharedContext.mainWindow?.present(sheet, on: .root, blockInteraction: false, completion: {})
    }

    private func showFloatingButton(for task: ActiveTask) {
        guard let containerView = task.context.sharedContext.mainWindow?.hostView.containerView else {
            return
        }
        let presentationData = task.context.sharedContext.currentPresentationData.with { $0 }
        let button: YougramAdvancedForwardFloatingButton
        if let existing = task.floatingButton {
            button = existing
        } else {
            button = YougramAdvancedForwardFloatingButton(
                accentColor: presentationData.theme.list.itemAccentColor,
                isDark: presentationData.theme.overallDarkAppearance,
                onTap: { [weak self] in
                    self?.presentActiveSheet()
                }
            )
            task.floatingButton = button
        }
        button.attach(to: containerView, initialCenterRatio: task.lastFloatingCenterRatio ?? self.rememberedCenterRatio)
        button.update(
            progress: task.latestProgress,
            accentColor: presentationData.theme.list.itemAccentColor,
            isDark: presentationData.theme.overallDarkAppearance
        )
    }

    private func hideFloatingButton(for task: ActiveTask) {
        if let button = task.floatingButton {
            let ratio = button.currentCenterRatio
            task.lastFloatingCenterRatio = ratio
            self.rememberedCenterRatio = ratio
            task.floatingButton = nil
            button.animateOutAndRemove()
        }
    }

    private func teardownUI(for task: ActiveTask) {
        let sheet = task.sheetController
        task.sheetController = nil
        sheet?.dismiss(completion: nil)
        self.hideFloatingButton(for: task)
    }

    private func presentToast(content: UndoOverlayContent, context: AccountContext, presentationData: PresentationData) {
        let controller = UndoOverlayController(
            presentationData: presentationData,
            content: content,
            elevatedLayout: false,
            position: .bottom,
            animateInAsReplacement: true,
            action: { _ in
                return false
            }
        )
        context.sharedContext.mainWindow?.present(controller, on: .root, blockInteraction: false, completion: {})
    }
}
