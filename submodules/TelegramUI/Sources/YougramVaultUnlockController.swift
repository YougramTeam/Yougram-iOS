import UIKit
import Foundation
import LocalAuthentication
import PasscodeCore
import TelegramCore
import AppLock
import WalletContext
import AppBundle
import TelegramUIPreferences

private final class WeakDisplayLinkTarget {
    weak var owner: YougramAppIconProgressBorderView?

    init(owner: YougramAppIconProgressBorderView) {
        self.owner = owner
    }

    @objc func handleDisplayLink(_ link: CADisplayLink) {
        self.owner?.tick(link)
    }
}

/// Concentric animated border around the active Yougram app icon.
/// Automatically extracts a color-matched gradient from the icon art, supports an
/// indeterminate spinning arc while starting encryption/decryption, and smoothly
/// sweeps clockwise from 0% to 100% until full.
public final class YougramAppIconProgressBorderView: UIView {
    private enum Mode {
        case idle
        case spinning
        case filling(target: CGFloat, completion: (() -> Void)?)
    }

    private let iconSize: CGFloat
    private let borderPadding: CGFloat = 6.0
    private let borderLineWidth: CGFloat = 3.5

    private let iconShadowContainer = UIView()
    private let iconImageView = UIImageView()

    private let trackLayer = CAShapeLayer()
    private let glowContainerLayer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let maskContainerLayer = CALayer()
    private let primaryArcLayer = CAShapeLayer()
    private let wrapArcLayer = CAShapeLayer()

    private var primaryColor: UIColor = UIColor(red: 0.48, green: 0.44, blue: 0.94, alpha: 1.0)
    private var secondaryColor: UIColor = UIColor(red: 0.62, green: 0.56, blue: 0.98, alpha: 1.0)
    private var lastResolvedDarkAppearance: Bool?

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var spinTime: CFTimeInterval = 0

    private var mode: Mode = .idle
    private var arcStart: CGFloat = 0.0
    private var arcLength: CGFloat = 0.0
    private var arcAlpha: CGFloat = 0.0
    private var completionFired = false

    public init(iconSize: CGFloat = 84.0) {
        self.iconSize = iconSize
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.isUserInteractionEnabled = false

        let totalSize = self.iconSize + self.borderPadding * 2.0 + self.borderLineWidth
        NSLayoutConstraint.activate([
            self.widthAnchor.constraint(equalToConstant: totalSize),
            self.heightAnchor.constraint(equalToConstant: totalSize)
        ])

        self.trackLayer.fillColor = nil
        self.trackLayer.lineWidth = self.borderLineWidth
        self.layer.addSublayer(self.trackLayer)

        self.glowContainerLayer.shadowOffset = .zero
        self.glowContainerLayer.shadowRadius = 7.0
        self.glowContainerLayer.opacity = 0.0
        self.layer.addSublayer(self.glowContainerLayer)

        self.gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        self.gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        self.glowContainerLayer.addSublayer(self.gradientLayer)

        self.primaryArcLayer.fillColor = nil
        self.primaryArcLayer.strokeColor = UIColor.white.cgColor
        self.primaryArcLayer.lineWidth = self.borderLineWidth
        self.primaryArcLayer.lineCap = .round

        self.wrapArcLayer.fillColor = nil
        self.wrapArcLayer.strokeColor = UIColor.white.cgColor
        self.wrapArcLayer.lineWidth = self.borderLineWidth
        self.wrapArcLayer.lineCap = .round
        self.wrapArcLayer.isHidden = true

        self.maskContainerLayer.addSublayer(self.primaryArcLayer)
        self.maskContainerLayer.addSublayer(self.wrapArcLayer)
        self.gradientLayer.mask = self.maskContainerLayer

        let iconCornerRadius = self.iconSize * 0.225
        self.iconShadowContainer.translatesAutoresizingMaskIntoConstraints = false
        self.iconShadowContainer.layer.shadowColor = UIColor.black.cgColor
        self.iconShadowContainer.layer.shadowOffset = CGSize(width: 0.0, height: 6.0)
        self.iconShadowContainer.layer.shadowRadius = 14.0
        self.iconShadowContainer.layer.shadowOpacity = 0.16
        self.addSubview(self.iconShadowContainer)

        self.iconImageView.translatesAutoresizingMaskIntoConstraints = false
        self.iconImageView.contentMode = .scaleAspectFill
        self.iconImageView.clipsToBounds = true
        self.iconImageView.layer.cornerRadius = iconCornerRadius
        if #available(iOS 13.0, *) {
            self.iconImageView.layer.cornerCurve = .continuous
        }
        self.iconShadowContainer.addSubview(self.iconImageView)

        NSLayoutConstraint.activate([
            self.iconShadowContainer.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            self.iconShadowContainer.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.iconShadowContainer.widthAnchor.constraint(equalToConstant: self.iconSize),
            self.iconShadowContainer.heightAnchor.constraint(equalToConstant: self.iconSize),
            self.iconImageView.topAnchor.constraint(equalTo: self.iconShadowContainer.topAnchor),
            self.iconImageView.bottomAnchor.constraint(equalTo: self.iconShadowContainer.bottomAnchor),
            self.iconImageView.leadingAnchor.constraint(equalTo: self.iconShadowContainer.leadingAnchor),
            self.iconImageView.trailingAnchor.constraint(equalTo: self.iconShadowContainer.trailingAnchor)
        ])

        self.reloadIconAndColors()

        if #available(iOS 17.0, *) {
            self.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: YougramAppIconProgressBorderView, _: UITraitCollection) in
                view.updateAccentColorsFromCurrentIcon()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.stopDisplayLink()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let isDark: Bool
        if #available(iOS 13.0, *) {
            isDark = self.traitCollection.userInterfaceStyle == .dark
        } else {
            isDark = false
        }
        if self.lastResolvedDarkAppearance != isDark {
            self.updateAccentColorsFromCurrentIcon()
        }
        let bounds = self.bounds
        let iconInset = (bounds.width - self.iconSize) * 0.5
        let borderInset = iconInset - self.borderPadding - self.borderLineWidth * 0.5
        let borderRect = bounds.insetBy(dx: max(self.borderLineWidth * 0.5, borderInset), dy: max(self.borderLineWidth * 0.5, borderInset))
        let borderCornerRadius = self.iconSize * 0.225 + self.borderPadding + self.borderLineWidth * 0.5
        let path = Self.makeClockwiseRoundedRectPath(rect: borderRect, cornerRadius: borderCornerRadius)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.trackLayer.frame = bounds
        self.trackLayer.path = path
        self.glowContainerLayer.frame = bounds
        self.gradientLayer.frame = bounds
        self.maskContainerLayer.frame = bounds
        self.primaryArcLayer.frame = bounds
        self.primaryArcLayer.path = path
        self.wrapArcLayer.frame = bounds
        self.wrapArcLayer.path = path
        CATransaction.commit()

        self.applyArcLayers()
    }

    public func reloadIconAndColors() {
        let iconName = UIApplication.shared.alternateIconName ?? "Purple"
        let bundle = getAppBundle()
        let iconImage = UIImage(named: iconName, in: bundle, compatibleWith: nil)
            ?? UIImage(named: "Purple", in: bundle, compatibleWith: nil)

        if let iconImage {
            self.iconImageView.image = iconImage
            self.iconImageView.backgroundColor = .clear
        } else if #available(iOS 13.0, *) {
            let config = UIImage.SymbolConfiguration(pointSize: self.iconSize * 0.45, weight: .medium)
            self.iconImageView.image = UIImage(systemName: "lock.shield.fill", withConfiguration: config)
            self.iconImageView.contentMode = .center
            self.iconImageView.tintColor = .white
            self.iconImageView.backgroundColor = UIColor(red: 0.46, green: 0.40, blue: 0.92, alpha: 1.0)
        }
        self.updateAccentColorsFromCurrentIcon()
    }

    private func updateAccentColorsFromCurrentIcon() {
        let isDark: Bool
        if #available(iOS 13.0, *) {
            isDark = self.traitCollection.userInterfaceStyle == .dark
        } else {
            isDark = false
        }
        self.lastResolvedDarkAppearance = isDark

        let colors = Self.extractAccentColors(from: self.iconImageView.image, isDark: isDark)
        self.primaryColor = colors.primary
        self.secondaryColor = colors.secondary

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.trackLayer.strokeColor = colors.primary.withAlphaComponent(isDark ? 0.16 : 0.12).cgColor
        self.gradientLayer.colors = [colors.primary.cgColor, colors.secondary.cgColor, colors.primary.cgColor]
        self.glowContainerLayer.shadowColor = colors.primary.cgColor
        self.glowContainerLayer.shadowOpacity = isDark ? 0.48 : 0.28
        CATransaction.commit()
    }

    public func setIdle() {
        self.stopDisplayLink()
        self.mode = .idle
        self.completionFired = false
        self.arcLength = 0.0
        self.arcAlpha = 0.0
        self.applyArcLayers()
    }

    public func startSpinning() {
        self.completionFired = false
        if case .spinning = self.mode {
            self.ensureDisplayLink()
            return
        }
        if self.arcAlpha < 0.05 || self.arcLength <= 0.01 {
            self.arcStart = 0.0
            self.arcLength = 0.26
        }
        self.mode = .spinning
        self.ensureDisplayLink()
    }

    public func setFillProgress(_ value: Float) {
        let clamped = CGFloat(max(0.0, min(1.0, value)))
        self.completionFired = false
        switch self.mode {
        case .idle:
            self.arcStart = 0.0
            self.arcLength = 0.0
            self.mode = .filling(target: clamped, completion: nil)
        case .spinning:
            // Lock tail at current spin position so arc sweeps forward without jumping.
            let targetLength = max(self.arcLength, clamped)
            self.mode = .filling(target: targetLength, completion: nil)
        case let .filling(existingTarget, existingCompletion):
            let nextTarget = max(existingTarget, clamped)
            self.mode = .filling(target: nextTarget, completion: existingCompletion)
        }
        self.ensureDisplayLink()
    }

    public func finishFillingAndPulse(completion: @escaping () -> Void) {
        switch self.mode {
        case .idle:
            self.arcStart = 0.0
            self.arcLength = 0.05
            self.arcAlpha = 1.0
        case .spinning, .filling:
            break
        }
        self.completionFired = false
        self.mode = .filling(target: 1.0, completion: completion)
        self.ensureDisplayLink()
    }

    private func ensureDisplayLink() {
        guard self.displayLink == nil else {
            return
        }
        let proxy = WeakDisplayLinkTarget(owner: self)
        let link = CADisplayLink(target: proxy, selector: #selector(WeakDisplayLinkTarget.handleDisplayLink(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60.0, maximum: 120.0, preferred: 120.0)
        }
        link.add(to: .main, forMode: .common)
        self.lastTimestamp = 0
        self.displayLink = link
    }

    private func stopDisplayLink() {
        self.displayLink?.invalidate()
        self.displayLink = nil
        self.lastTimestamp = 0
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt: CFTimeInterval
        if self.lastTimestamp == 0 {
            dt = 1.0 / 60.0
        } else {
            dt = max(0.001, min(0.05, now - self.lastTimestamp))
        }
        self.lastTimestamp = now

        switch self.mode {
        case .idle:
            self.arcAlpha = max(0.0, self.arcAlpha - CGFloat(dt) * 4.0)
            self.applyArcLayers()
            if self.arcAlpha <= 0.001 {
                self.stopDisplayLink()
            }

        case .spinning:
            self.spinTime += dt
            self.arcAlpha = min(1.0, self.arcAlpha + CGFloat(dt) * 5.0)
            self.arcStart = (self.arcStart + CGFloat(dt) * 0.68).truncatingRemainder(dividingBy: 1.0)
            self.arcLength = 0.26 + 0.04 * CGFloat(sin(self.spinTime * 2.8))
            self.applyArcLayers()

        case let .filling(target, completion):
            self.arcAlpha = min(1.0, self.arcAlpha + CGFloat(dt) * 6.0)
            let clampedTarget = max(0.0, min(1.0, target))
            let diff = clampedTarget - self.arcLength
            if diff > 0.001 {
                let maxRate: CGFloat = (clampedTarget >= 0.999 && completion != nil) ? 1.55 : 1.20
                let minRate: CGFloat = 0.14
                let adaptive = diff * 7.5
                let rate = max(minRate, min(maxRate, adaptive))
                let delta = min(diff, rate * CGFloat(dt))
                self.arcLength = min(clampedTarget, self.arcLength + delta)
            } else {
                self.arcLength = clampedTarget
            }
            self.applyArcLayers()

            if self.arcLength >= 0.999, let completion, !self.completionFired {
                self.completionFired = true
                self.arcLength = 1.0
                self.applyArcLayers()
                self.stopDisplayLink()
                self.playCompletionPulse(completion: completion)
            }
        }
    }

    private func playCompletionPulse(completion: @escaping () -> Void) {
        UIView.animate(withDuration: 0.13, delay: 0.0, options: [.curveEaseOut], animations: {
            self.transform = CGAffineTransform(scaleX: 1.045, y: 1.045)
        }, completion: { _ in
            UIView.animate(withDuration: 0.17, delay: 0.0, options: [.curveEaseInOut], animations: {
                self.transform = .identity
            }, completion: { _ in
                completion()
            })
        })
    }

    private func applyArcLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.glowContainerLayer.opacity = Float(self.arcAlpha)

        if self.arcLength <= 0.001 || self.arcAlpha <= 0.001 {
            self.primaryArcLayer.strokeStart = 0.0
            self.primaryArcLayer.strokeEnd = 0.0
            self.wrapArcLayer.isHidden = true
        } else if self.arcLength >= 0.999 {
            self.primaryArcLayer.strokeStart = 0.0
            self.primaryArcLayer.strokeEnd = 1.0
            self.wrapArcLayer.isHidden = true
        } else {
            let s = self.arcStart - floor(self.arcStart)
            let end = s + self.arcLength
            if end <= 1.0 {
                self.primaryArcLayer.strokeStart = s
                self.primaryArcLayer.strokeEnd = end
                self.wrapArcLayer.isHidden = true
            } else {
                self.primaryArcLayer.strokeStart = s
                self.primaryArcLayer.strokeEnd = 1.0
                self.wrapArcLayer.isHidden = false
                self.wrapArcLayer.strokeStart = 0.0
                self.wrapArcLayer.strokeEnd = min(1.0, end - 1.0)
            }
        }
        CATransaction.commit()
    }

    /// Rounded-rect path starting at top-center (12 o'clock) going clockwise so strokeStart/strokeEnd fills cleanly.
    private static func makeClockwiseRoundedRectPath(rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        let r = min(cornerRadius, min(rect.width, rect.height) * 0.5)
        let path = CGMutablePath()
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY
        let midX = rect.midX

        path.move(to: CGPoint(x: midX, y: minY))
        path.addLine(to: CGPoint(x: maxX - r, y: minY))
        path.addArc(center: CGPoint(x: maxX - r, y: minY + r), radius: r, startAngle: -.pi * 0.5, endAngle: 0.0, clockwise: false)
        path.addLine(to: CGPoint(x: maxX, y: maxY - r))
        path.addArc(center: CGPoint(x: maxX - r, y: maxY - r), radius: r, startAngle: 0.0, endAngle: .pi * 0.5, clockwise: false)
        path.addLine(to: CGPoint(x: minX + r, y: maxY))
        path.addArc(center: CGPoint(x: minX + r, y: maxY - r), radius: r, startAngle: .pi * 0.5, endAngle: .pi, clockwise: false)
        path.addLine(to: CGPoint(x: minX, y: minY + r))
        path.addArc(center: CGPoint(x: minX + r, y: minY + r), radius: r, startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
        path.closeSubpath()
        return path
    }

    private static func extractAccentColors(from image: UIImage?, isDark: Bool) -> (primary: UIColor, secondary: UIColor) {
        let fallbackPrimary = isDark
            ? UIColor(hue: 0.70, saturation: 0.52, brightness: 0.90, alpha: 1.0)
            : UIColor(hue: 0.70, saturation: 0.62, brightness: 0.74, alpha: 1.0)
        let fallbackSecondary = isDark
            ? UIColor(hue: 0.76, saturation: 0.46, brightness: 0.95, alpha: 1.0)
            : UIColor(hue: 0.76, saturation: 0.54, brightness: 0.80, alpha: 1.0)

        guard let cgImage = image?.cgImage else {
            return (fallbackPrimary, fallbackSecondary)
        }

        let sampleSize = 24
        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return (fallbackPrimary, fallbackSecondary)
        }

        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        var sumCos: Double = 0.0
        var sumSin: Double = 0.0
        var sumSat: Double = 0.0
        var totalWeight: Double = 0.0

        for idx in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[idx + 3]) / 255.0
            if a < 0.5 { continue }
            let r = CGFloat(pixels[idx]) / 255.0 / CGFloat(a)
            let g = CGFloat(pixels[idx + 1]) / 255.0 / CGFloat(a)
            let b = CGFloat(pixels[idx + 2]) / 255.0 / CGFloat(a)

            var h: CGFloat = 0
            var s: CGFloat = 0
            var br: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1.0).getHue(&h, saturation: &s, brightness: &br, alpha: nil)

            if s < 0.14 || br < 0.12 || br > 0.97 {
                continue
            }

            let weight = Double(s * s) * (0.4 + 0.6 * Double(br))
            let angle = Double(h) * 2.0 * .pi
            sumCos += cos(angle) * weight
            sumSin += sin(angle) * weight
            sumSat += Double(s) * weight
            totalWeight += weight
        }

        guard totalWeight > 0.01 else {
            return (fallbackPrimary, fallbackSecondary)
        }

        var meanHue = atan2(sumSin, sumCos) / (2.0 * .pi)
        if meanHue < 0 {
            meanHue += 1.0
        }
        let avgSat = sumSat / totalWeight
        let hue = CGFloat(meanHue)
        let secondaryHue = (hue + 0.065).truncatingRemainder(dividingBy: 1.0)

        let sat1: CGFloat
        let sat2: CGFloat
        let bri1: CGFloat
        let bri2: CGFloat
        if isDark {
            sat1 = max(0.48, min(0.72, CGFloat(avgSat)))
            sat2 = max(0.42, min(0.68, sat1 * 0.90))
            bri1 = 0.88
            bri2 = 0.94
        } else {
            sat1 = max(0.56, min(0.78, CGFloat(avgSat)))
            sat2 = max(0.50, min(0.72, sat1 * 0.92))
            bri1 = 0.72
            bri2 = 0.80
        }

        return (
            UIColor(hue: hue, saturation: sat1, brightness: bri1, alpha: 1.0),
            UIColor(hue: secondaryHue, saturation: sat2, brightness: bri2, alpha: 1.0)
        )
    }
}

public final class YougramMigrationProgressController: UIViewController {
    private let encrypting: Bool
    private let iconBorderView = YougramAppIconProgressBorderView(iconSize: 92.0)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let percentLabel = UILabel()

    public init(encrypting: Bool) {
        self.encrypting = encrypting
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
        if #available(iOS 13.0, *) {
            self.isModalInPresentation = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 13.0, *) {
            self.view.backgroundColor = .systemBackground
        } else {
            self.view.backgroundColor = .white
        }

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16.0
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(stack)

        stack.addArrangedSubview(self.iconBorderView)
        self.iconBorderView.startSpinning()

        self.titleLabel.text = self.encrypting ? "Encrypting Local Data" : "Decrypting Local Data"
        self.titleLabel.font = UIFont.systemFont(ofSize: 22.0, weight: .semibold)
        self.titleLabel.textAlignment = .center
        self.titleLabel.numberOfLines = 0
        stack.addArrangedSubview(self.titleLabel)

        self.subtitleLabel.text = self.encrypting
            ? "Encrypting contacts, chats, accounts, and cached media.\nPlease keep Yougram open until complete."
            : "Decrypting local databases and media back to standard storage.\nPlease keep Yougram open until complete."
        self.subtitleLabel.font = UIFont.systemFont(ofSize: 15.0)
        if #available(iOS 13.0, *) {
            self.subtitleLabel.textColor = .secondaryLabel
        } else {
            self.subtitleLabel.textColor = .gray
        }
        self.subtitleLabel.textAlignment = .center
        self.subtitleLabel.numberOfLines = 0
        stack.addArrangedSubview(self.subtitleLabel)

        self.percentLabel.text = "0%"
        self.percentLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 15.0, weight: .semibold)
        if #available(iOS 13.0, *) {
            self.percentLabel.textColor = .secondaryLabel
        } else {
            self.percentLabel.textColor = .gray
        }
        stack.addArrangedSubview(self.percentLabel)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: self.view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 32.0),
            stack.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -32.0)
        ])
    }

    public func updateProgress(_ value: Float) {
        let clamped = max(0.0, min(1.0, value))
        if clamped > 0.005 {
            self.iconBorderView.setFillProgress(clamped)
        }
        self.percentLabel.text = "\(Int(round(clamped * 100.0)))%"
    }
}

public final class YougramVaultUnlockController: UIViewController, UITextFieldDelegate {
    public enum InitialPhase {
        case locked
        case sealing
    }

    private enum Phase {
        case sealing
        case locked
        case decrypting
    }

    private enum EntryKind {
        case digits(Int)
        case password
    }

    private let rootPath: String
    private let appGroupPath: String?
    private let manifest: YougramVaultManifest
    private let onUnlocked: (Data, YougramVaultUnlockController) -> Void
    private let onWipedAndReset: () -> Void

    private var phase: Phase
    private var entryKind: EntryKind = .digits(6)
    private var passcodeMode: Bool = false
    private var biometricsEnabled: Bool = false
    private var scrambledKeypad: Bool = false
    private var enteredDigits: String = ""
    private var keypadOrder: [Int] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]
    private var hasPromptedBiometrics = false
    private var cooldownTimer: Timer?
    private var didFinishUnlock = false

    private let containerStack = UIStackView()
    private let iconBorderView = YougramAppIconProgressBorderView(iconSize: 84.0)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let errorLabel = UILabel()

    private let dotsStack = UIStackView()
    private var dotViews: [UIView] = []
    private let keypadStack = UIStackView()
    private var digitButtons: [UIButton] = []

    private let passwordField = UITextField()
    private let unlockButton = UIButton(type: .system)
    private let biometricsButton = UIButton(type: .system)
    private let eraseButton = UIButton(type: .system)

    public init(
        rootPath: String,
        appGroupPath: String?,
        manifest: YougramVaultManifest,
        initialPhase: InitialPhase = .locked,
        onUnlocked: @escaping (Data, YougramVaultUnlockController) -> Void,
        onWipedAndReset: @escaping () -> Void
    ) {
        self.rootPath = rootPath
        self.appGroupPath = appGroupPath
        self.manifest = manifest
        self.phase = (initialPhase == .sealing) ? .sealing : .locked
        self.onUnlocked = onUnlocked
        self.onWipedAndReset = onWipedAndReset

        switch manifest.unlockMode {
        case let .dedicated(kind):
            self.passcodeMode = false
            self.biometricsEnabled = manifest.biometricsEnabled
            self.scrambledKeypad = manifest.scrambledKeypad || YougramSettings.current.scramblePasscodeKeypad
            switch kind {
            case .digits4:
                self.entryKind = .digits(4)
            case .digits6:
                self.entryKind = .digits(6)
            case .password:
                self.entryKind = .password
            }
        case .appPasscode:
            self.passcodeMode = true
            let kind = PasscodeCredentialStore.shared.currentPasscodeKind() ?? .digits6
            let protection = try? PasscodeCredentialStore.shared.protectionSettings()
            self.biometricsEnabled = protection?.biometricsEnabled ?? false
            self.scrambledKeypad = manifest.scrambledKeypad || YougramSettings.current.scramblePasscodeKeypad
            switch kind {
            case .digits4:
                self.entryKind = .digits(4)
            case .digits6:
                self.entryKind = .digits(6)
            case .alphanumeric:
                self.entryKind = .password
            }
        }

        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
        self.keypadOrder = Self.nextKeypadOrder(scrambled: self.scrambledKeypad)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.cooldownTimer?.invalidate()
    }

    private static func nextKeypadOrder(scrambled: Bool) -> [Int] {
        let standard = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]
        guard scrambled else {
            return standard
        }
        var order = standard.shuffled()
        if order == standard {
            order.swapAt(0, 9)
        }
        return order
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 13.0, *) {
            self.view.backgroundColor = .systemBackground
        } else {
            self.view.backgroundColor = .white
        }
        self.setupUI()
        self.applyPhaseUI(animated: false)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.iconBorderView.reloadIconAndColors()
        if self.phase == .locked {
            self.activateLockedInputFocusAndBiometrics()
        }
    }

    // MARK: - Sealing & Decryption Lifecycle API

    public func updateSealingProgress(_ value: Float) {
        guard self.phase == .sealing else {
            return
        }
        self.iconBorderView.setFillProgress(value)
    }

    public func finishSealingAndShowUnlock() {
        guard self.phase == .sealing else {
            return
        }
        self.iconBorderView.finishFillingAndPulse { [weak self] in
            guard let self, self.phase == .sealing else {
                return
            }
            self.phase = .locked
            self.enteredDigits = ""
            self.passwordField.text = ""
            self.updateDots()
            self.reshuffleKeypad()
            self.applyPhaseUI(animated: true)
            self.activateLockedInputFocusAndBiometrics()
        }
    }

    public func updateDecryptionProgress(_ value: Float) {
        guard self.phase == .decrypting else {
            return
        }
        self.iconBorderView.setFillProgress(value)
    }

    public func completeDecryptionAndDismiss(completion: @escaping () -> Void) {
        guard self.phase == .decrypting, !self.didFinishUnlock else {
            return
        }
        self.didFinishUnlock = true
        self.iconBorderView.finishFillingAndPulse {
            completion()
        }
    }

    private func activateLockedInputFocusAndBiometrics() {
        if case .password = self.entryKind, self.currentCooldownRemaining() == 0 {
            self.passwordField.becomeFirstResponder()
        }
        if !self.hasPromptedBiometrics && self.biometricsEnabled && self.currentCooldownRemaining() == 0 {
            self.hasPromptedBiometrics = true
            self.attemptBiometricUnlock()
        }
    }

    // MARK: - Setup UI

    private func setupUI() {
        self.containerStack.axis = .vertical
        self.containerStack.alignment = .center
        self.containerStack.spacing = 14.0
        self.containerStack.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(self.containerStack)

        self.containerStack.addArrangedSubview(self.iconBorderView)

        self.titleLabel.text = "Yougram Locked"
        self.titleLabel.font = UIFont.systemFont(ofSize: 22.0, weight: .semibold)
        self.titleLabel.textAlignment = .center
        self.containerStack.addArrangedSubview(self.titleLabel)

        self.subtitleLabel.font = UIFont.systemFont(ofSize: 15.0)
        if #available(iOS 13.0, *) {
            self.subtitleLabel.textColor = .secondaryLabel
        } else {
            self.subtitleLabel.textColor = .gray
        }
        self.subtitleLabel.textAlignment = .center
        self.subtitleLabel.numberOfLines = 0
        self.containerStack.addArrangedSubview(self.subtitleLabel)

        self.errorLabel.text = " "
        self.errorLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .medium)
        self.errorLabel.textColor = .systemRed
        self.errorLabel.textAlignment = .center
        self.errorLabel.numberOfLines = 0
        self.containerStack.addArrangedSubview(self.errorLabel)

        switch self.entryKind {
        case let .digits(count):
            self.setupPinUI(count: count)
        case .password:
            self.setupPasswordUI()
        }

        if self.biometricsEnabled {
            self.biometricsButton.setTitle("Unlock with Face ID / Touch ID", for: .normal)
            self.biometricsButton.titleLabel?.font = UIFont.systemFont(ofSize: 15.0, weight: .medium)
            self.biometricsButton.addTarget(self, action: #selector(self.biometricsTapped), for: .touchUpInside)
            self.containerStack.addArrangedSubview(self.biometricsButton)
        }

        self.eraseButton.setTitle("Erase All Data", for: .normal)
        self.eraseButton.setTitleColor(.systemRed, for: .normal)
        self.eraseButton.titleLabel?.font = UIFont.systemFont(ofSize: 14.0, weight: .regular)
        self.eraseButton.translatesAutoresizingMaskIntoConstraints = false
        self.eraseButton.addTarget(self, action: #selector(self.eraseTapped), for: .touchUpInside)
        self.view.addSubview(self.eraseButton)

        NSLayoutConstraint.activate([
            self.containerStack.centerYAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.centerYAnchor, constant: -16.0),
            self.containerStack.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 28.0),
            self.containerStack.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -28.0),
            self.eraseButton.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -16.0),
            self.eraseButton.centerXAnchor.constraint(equalTo: self.view.centerXAnchor)
        ])
    }

    private func setupPinUI(count: Int) {
        self.dotsStack.axis = .horizontal
        self.dotsStack.spacing = 16.0
        self.dotsStack.alignment = .center
        for _ in 0 ..< count {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.layer.cornerRadius = 7.0
            dot.layer.borderWidth = 1.5
            if #available(iOS 13.0, *) {
                dot.layer.borderColor = UIColor.label.cgColor
            } else {
                dot.layer.borderColor = UIColor.black.cgColor
            }
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 14.0),
                dot.heightAnchor.constraint(equalToConstant: 14.0)
            ])
            self.dotViews.append(dot)
            self.dotsStack.addArrangedSubview(dot)
        }
        self.containerStack.addArrangedSubview(self.dotsStack)

        self.keypadStack.axis = .vertical
        self.keypadStack.spacing = 12.0
        self.keypadStack.alignment = .center
        self.digitButtons.removeAll()

        let rows: [[Int?]] = [
            [self.keypadOrder[0], self.keypadOrder[1], self.keypadOrder[2]],
            [self.keypadOrder[3], self.keypadOrder[4], self.keypadOrder[5]],
            [self.keypadOrder[6], self.keypadOrder[7], self.keypadOrder[8]],
            [nil, self.keypadOrder[9], -1]
        ]

        for row in rows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 20.0
            rowStack.alignment = .center
            for cell in row {
                if let digit = cell {
                    let button = UIButton(type: .system)
                    button.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        button.widthAnchor.constraint(equalToConstant: 72.0),
                        button.heightAnchor.constraint(equalToConstant: 72.0)
                    ])
                    if digit == -1 {
                        if #available(iOS 13.0, *) {
                            button.setImage(UIImage(systemName: "delete.left"), for: .normal)
                            button.tintColor = .label
                        } else {
                            button.setTitle("⌫", for: .normal)
                        }
                        button.tag = -1
                        button.addTarget(self, action: #selector(self.backspaceTapped), for: .touchUpInside)
                    } else {
                        button.setTitle("\(digit)", for: .normal)
                        button.titleLabel?.font = UIFont.systemFont(ofSize: 28.0, weight: .regular)
                        if #available(iOS 13.0, *) {
                            button.backgroundColor = .secondarySystemBackground
                            button.setTitleColor(.label, for: .normal)
                        } else {
                            button.backgroundColor = UIColor(white: 0.92, alpha: 1.0)
                            button.setTitleColor(.black, for: .normal)
                        }
                        button.layer.cornerRadius = 36.0
                        button.tag = digit
                        button.addTarget(self, action: #selector(self.digitTapped(_:)), for: .touchUpInside)
                        self.digitButtons.append(button)
                    }
                    rowStack.addArrangedSubview(button)
                } else {
                    let spacer = UIView()
                    spacer.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        spacer.widthAnchor.constraint(equalToConstant: 72.0),
                        spacer.heightAnchor.constraint(equalToConstant: 72.0)
                    ])
                    rowStack.addArrangedSubview(spacer)
                }
            }
            self.keypadStack.addArrangedSubview(rowStack)
        }
        self.containerStack.addArrangedSubview(self.keypadStack)
    }

    private func reshuffleKeypad() {
        let shouldScramble = self.manifest.scrambledKeypad || YougramSettings.current.scramblePasscodeKeypad
        self.scrambledKeypad = shouldScramble
        self.keypadOrder = Self.nextKeypadOrder(scrambled: shouldScramble)
        guard self.digitButtons.count == self.keypadOrder.count else {
            return
        }
        for (idx, button) in self.digitButtons.enumerated() {
            let digit = self.keypadOrder[idx]
            button.tag = digit
            button.setTitle("\(digit)", for: .normal)
            button.accessibilityLabel = "\(digit)"
        }
    }

    private func setupPasswordUI() {
        self.passwordField.isSecureTextEntry = true
        self.passwordField.borderStyle = .roundedRect
        self.passwordField.placeholder = "Password"
        self.passwordField.autocorrectionType = .no
        self.passwordField.autocapitalizationType = .none
        self.passwordField.returnKeyType = .go
        self.passwordField.delegate = self
        self.passwordField.translatesAutoresizingMaskIntoConstraints = false

        let revealButton = UIButton(type: .system)
        if #available(iOS 13.0, *) {
            revealButton.setImage(UIImage(systemName: "eye"), for: .normal)
        } else {
            revealButton.setTitle("Show", for: .normal)
        }
        revealButton.frame = CGRect(x: 0.0, y: 0.0, width: 36.0, height: 32.0)
        revealButton.addTarget(self, action: #selector(self.togglePasswordVisibility(_:)), for: .touchUpInside)
        self.passwordField.rightView = revealButton
        self.passwordField.rightViewMode = .always

        self.containerStack.addArrangedSubview(self.passwordField)
        NSLayoutConstraint.activate([
            self.passwordField.widthAnchor.constraint(equalTo: self.containerStack.widthAnchor),
            self.passwordField.heightAnchor.constraint(equalToConstant: 44.0)
        ])

        self.unlockButton.setTitle("Unlock", for: .normal)
        self.unlockButton.titleLabel?.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        self.unlockButton.backgroundColor = .systemBlue
        self.unlockButton.setTitleColor(.white, for: .normal)
        self.unlockButton.layer.cornerRadius = 10.0
        self.unlockButton.translatesAutoresizingMaskIntoConstraints = false
        self.unlockButton.addTarget(self, action: #selector(self.unlockPasswordTapped), for: .touchUpInside)
        self.containerStack.addArrangedSubview(self.unlockButton)
        NSLayoutConstraint.activate([
            self.unlockButton.widthAnchor.constraint(equalTo: self.containerStack.widthAnchor),
            self.unlockButton.heightAnchor.constraint(equalToConstant: 46.0)
        ])
    }

    private func applyPhaseUI(animated: Bool) {
        let interactiveViews: [UIView] = [
            self.errorLabel,
            self.dotsStack,
            self.keypadStack,
            self.passwordField,
            self.unlockButton,
            self.biometricsButton,
            self.eraseButton
        ]

        let applyState: () -> Void = {
            switch self.phase {
            case .sealing:
                self.titleLabel.text = "Yougram"
                self.subtitleLabel.text = "Encrypting…"
                self.view.endEditing(true)
                for view in interactiveViews {
                    view.alpha = 0.0
                    view.isHidden = true
                }
                self.iconBorderView.startSpinning()

            case .locked:
                self.titleLabel.text = "Yougram Locked"
                self.subtitleLabel.text = self.passcodeMode
                    ? "Enter your App Passcode to decrypt local data"
                    : "Enter your Local Encryption secret to unlock"
                self.iconBorderView.setIdle()
                for view in interactiveViews where view.superview != nil {
                    view.isHidden = false
                    view.alpha = 1.0
                }
                self.refreshCooldownState()

            case .decrypting:
                self.titleLabel.text = "Yougram"
                self.subtitleLabel.text = "Decrypting…"
                self.view.endEditing(true)
                for view in interactiveViews {
                    view.alpha = 0.0
                    view.isHidden = true
                }
                self.iconBorderView.startSpinning()
            }
            self.view.layoutIfNeeded()
        }

        if animated {
            if self.phase == .locked {
                for view in interactiveViews where view.superview != nil {
                    view.alpha = 0.0
                    view.isHidden = false
                }
            }
            UIView.animate(withDuration: 0.24, delay: 0.0, options: [.curveEaseInOut], animations: applyState)
        } else {
            applyState()
        }
    }

    @objc private func togglePasswordVisibility(_ sender: UIButton) {
        let wasFirstResponder = self.passwordField.isFirstResponder
        let existingText = self.passwordField.text
        self.passwordField.isSecureTextEntry.toggle()
        if #available(iOS 13.0, *) {
            let iconName = self.passwordField.isSecureTextEntry ? "eye" : "eye.slash"
            sender.setImage(UIImage(systemName: iconName), for: .normal)
        }
        if wasFirstResponder {
            self.passwordField.text = nil
            self.passwordField.text = existingText
        }
    }

    @objc private func digitTapped(_ sender: UIButton) {
        guard self.phase == .locked, self.currentCooldownRemaining() == 0 else {
            return
        }
        guard case let .digits(targetCount) = self.entryKind, self.enteredDigits.count < targetCount else {
            return
        }
        self.enteredDigits.append("\(sender.tag)")
        self.errorLabel.text = " "
        self.updateDots()
        if self.enteredDigits.count == targetCount {
            let code = self.enteredDigits
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.submitSecret(code)
            }
        }
    }

    @objc private func backspaceTapped() {
        guard self.phase == .locked, !self.enteredDigits.isEmpty else {
            return
        }
        self.enteredDigits.removeLast()
        self.updateDots()
    }

    @objc private func unlockPasswordTapped() {
        guard self.phase == .locked else {
            return
        }
        self.submitSecret(self.passwordField.text ?? "")
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if self.phase == .locked {
            self.submitSecret(textField.text ?? "")
        }
        return true
    }

    private func updateDots() {
        for (idx, dot) in self.dotViews.enumerated() {
            if idx < self.enteredDigits.count {
                if #available(iOS 13.0, *) {
                    dot.backgroundColor = .label
                } else {
                    dot.backgroundColor = .black
                }
            } else {
                dot.backgroundColor = .clear
            }
        }
    }

    private func currentCooldownRemaining() -> Int {
        if self.passcodeMode {
            return (try? PasscodeCredentialStore.shared.cooldownRemaining()) ?? 0
        }
        return YougramVaultStore.shared.cooldownRemaining(rootPath: self.rootPath)
    }

    private func refreshCooldownState() {
        let remaining = self.currentCooldownRemaining()
        if remaining > 0 {
            self.errorLabel.text = "Too many attempts. Try again in \(remaining)s."
            self.setInputEnabled(false)
            self.cooldownTimer?.invalidate()
            self.cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                let left = self.currentCooldownRemaining()
                if left <= 0 {
                    self.cooldownTimer?.invalidate()
                    self.cooldownTimer = nil
                    self.errorLabel.text = " "
                    self.setInputEnabled(true)
                } else {
                    self.errorLabel.text = "Too many attempts. Try again in \(left)s."
                }
            }
        } else {
            self.setInputEnabled(true)
        }
    }

    private func setInputEnabled(_ enabled: Bool) {
        self.keypadStack.isUserInteractionEnabled = enabled
        self.keypadStack.alpha = enabled ? 1.0 : 0.45
        self.passwordField.isEnabled = enabled
        self.unlockButton.isEnabled = enabled
        self.unlockButton.alpha = enabled ? 1.0 : 0.45
    }

    private func submitSecret(_ secret: String) {
        guard self.phase == .locked else {
            return
        }
        guard !secret.isEmpty else {
            self.errorLabel.text = "Enter your password to unlock."
            return
        }
        if self.currentCooldownRemaining() > 0 {
            self.refreshCooldownState()
            return
        }

        self.phase = .decrypting
        self.applyPhaseUI(animated: true)

        let rootPath = self.rootPath
        let appGroupPath = self.appGroupPath
        let isPasscodeMode = self.passcodeMode

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if isPasscodeMode {
                if PasscodeCredentialStore.shared.matchesDuressCode(secret) {
                    YougramVaultStore.shared.cryptoShredAndWipeAllData(rootPath: rootPath, appGroupPath: appGroupPath)
                    try? resetWalletLocalSecrets()
                    DispatchQueue.main.async {
                        self?.onWipedAndReset()
                    }
                    return
                }
                do {
                    PasscodeSession.setApplicationAvailable(true)
                    let session = try PasscodeCredentialStore.shared.verify(secret, scope: .appUnlock)
                    let masterKey = try YougramVaultStore.shared.unlockWithAppPasscodeSession(session, rootPath: rootPath)
                    AppLockContextImpl.markUnlockedFromVault(rootPath: rootPath)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.iconBorderView.setFillProgress(0.15)
                        self.onUnlocked(masterKey, self)
                    }
                } catch let error as PasscodeError {
                    DispatchQueue.main.async {
                        self?.handleAuthFailure(message: error == .invalidCode ? "Incorrect passcode." : "Try again later.")
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.handleAuthFailure(message: "Unable to unlock vault.")
                    }
                }
            } else {
                do {
                    let masterKey = try YougramVaultStore.shared.unlockWithDedicatedSecret(secret, rootPath: rootPath)
                    AppLockContextImpl.markUnlockedFromVault(rootPath: rootPath)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.iconBorderView.setFillProgress(0.15)
                        self.onUnlocked(masterKey, self)
                    }
                } catch YougramVaultError.duressTriggered {
                    YougramVaultStore.shared.cryptoShredAndWipeAllData(rootPath: rootPath, appGroupPath: appGroupPath)
                    try? resetWalletLocalSecrets()
                    DispatchQueue.main.async {
                        self?.onWipedAndReset()
                    }
                } catch let YougramVaultError.cooldown(seconds) {
                    DispatchQueue.main.async {
                        self?.handleAuthFailure(message: "Too many attempts. Try again in \(seconds)s.")
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.handleAuthFailure(message: "Incorrect password or code.")
                    }
                }
            }
        }
    }

    private func handleAuthFailure(message: String) {
        self.phase = .locked
        self.enteredDigits = ""
        self.passwordField.text = ""
        self.updateDots()
        self.reshuffleKeypad()
        self.applyPhaseUI(animated: true)
        self.errorLabel.text = message
        self.shakeInputView()
        if case .password = self.entryKind, self.currentCooldownRemaining() == 0 {
            self.passwordField.becomeFirstResponder()
        }
    }

    private func shakeInputView() {
        let target: UIView = self.dotsStack.superview != nil ? self.dotsStack : self.passwordField
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.duration = 0.35
        anim.values = [-12, 12, -9, 9, -5, 5, 0]
        target.layer.add(anim, forKey: "shake")
    }

    @objc private func biometricsTapped() {
        guard self.phase == .locked else {
            return
        }
        self.attemptBiometricUnlock()
    }

    private func attemptBiometricUnlock() {
        guard self.phase == .locked, self.biometricsEnabled, self.currentCooldownRemaining() == 0 else {
            return
        }
        let rootPath = self.rootPath
        let isPasscodeMode = self.passcodeMode
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let masterKey: Data
                if isPasscodeMode {
                    PasscodeSession.setApplicationAvailable(true)
                    let context = LAContext()
                    context.localizedReason = "Unlock Yougram Local Encryption"
                    let session = try PasscodeCredentialStore.shared.authenticateBiometrics(
                        context: context,
                        scope: .resource(namespace: "yougram.vault")
                    )
                    DispatchQueue.main.async {
                        guard let self, self.phase == .locked else { return }
                        self.phase = .decrypting
                        self.applyPhaseUI(animated: true)
                    }
                    masterKey = try YougramVaultStore.shared.unlockWithAppPasscodeSession(session, rootPath: rootPath)
                } else {
                    masterKey = try YougramVaultStore.shared.unlockWithBiometrics(
                        rootPath: rootPath,
                        localizedReason: "Unlock Yougram Local Encryption"
                    )
                }
                AppLockContextImpl.markUnlockedFromVault(rootPath: rootPath)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.phase = .decrypting
                    self.applyPhaseUI(animated: false)
                    self.iconBorderView.setFillProgress(0.15)
                    self.onUnlocked(masterKey, self)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.phase == .decrypting else { return }
                    self.phase = .locked
                    self.applyPhaseUI(animated: true)
                }
            }
        }
    }

    @objc private func eraseTapped() {
        let first = UIAlertController(
            title: "Erase All Data?",
            message: "This will permanently destroy all encrypted messages, media, accounts, and local keys on this device. This cannot be undone.",
            preferredStyle: .alert
        )
        first.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        first.addAction(UIAlertAction(title: "Continue", style: .destructive, handler: { [weak self] _ in
            self?.confirmSecondErase()
        }))
        self.present(first, animated: true, completion: nil)
    }

    private func confirmSecondErase() {
        let second = UIAlertController(
            title: "Confirm Permanent Erasure",
            message: "All local Yougram data will be cryptographically shredded immediately.",
            preferredStyle: .alert
        )
        second.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        second.addAction(UIAlertAction(title: "Erase Everything", style: .destructive, handler: { [weak self] _ in
            guard let self else { return }
            YougramVaultStore.shared.cryptoShredAndWipeAllData(rootPath: self.rootPath, appGroupPath: self.appGroupPath)
            try? resetWalletLocalSecrets()
            self.onWipedAndReset()
        }))
        self.present(second, animated: true, completion: nil)
    }
}
