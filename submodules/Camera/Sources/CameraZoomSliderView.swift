import Foundation
import UIKit
import QuartzCore

public final class CameraZoomSliderView: UIView {
    public var onScaleChanged: ((Float) -> Void)?

    private let backgroundEffectView: UIVisualEffectView
    private let tintOverlayView: UIView
    private let resetButton: UIButton
    private let valueLabel: UILabel
    private let slider: UISlider
    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)

    private var minScale: Float = 1.0
    private var maxScale: Float = 5.0
    private var currentScale: Float = 1.0
    private var defaultScale: Float = 1.0
    private var lastDetentStep: Float?
    private var displayedText: String = ""
    private var lastDisplayedScale: Float = 1.0

    public static let preferredHeight: CGFloat = 36.0

    public override init(frame: CGRect) {
        self.backgroundEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        self.tintOverlayView = UIView()
        self.resetButton = UIButton(type: .custom)
        self.valueLabel = UILabel()
        self.slider = UISlider()

        super.init(frame: frame)

        self.clipsToBounds = true
        self.layer.cornerRadius = Self.preferredHeight * 0.5
        self.layer.borderColor = UIColor(white: 1.0, alpha: 0.16).cgColor

        self.backgroundEffectView.isUserInteractionEnabled = false
        self.addSubview(self.backgroundEffectView)

        self.tintOverlayView.backgroundColor = UIColor(white: 0.06, alpha: 0.32)
        self.tintOverlayView.isUserInteractionEnabled = false
        self.addSubview(self.tintOverlayView)

        self.resetButton.clipsToBounds = false
        self.resetButton.addTarget(self, action: #selector(self.resetPressed), for: .touchUpInside)
        self.addSubview(self.resetButton)

        self.valueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .semibold)
        self.valueLabel.textAlignment = .center
        self.valueLabel.textColor = .white
        self.valueLabel.isUserInteractionEnabled = false
        self.resetButton.addSubview(self.valueLabel)

        self.slider.minimumValue = 0.0
        self.slider.maximumValue = 1.0
        self.slider.isContinuous = true
        self.slider.minimumTrackTintColor = UIColor(white: 1.0, alpha: 0.85)
        self.slider.maximumTrackTintColor = UIColor(white: 1.0, alpha: 0.24)
        self.slider.setThumbImage(Self.makeThumbImage(), for: .normal)
        self.slider.addTarget(self, action: #selector(self.sliderChanged), for: .valueChanged)
        self.slider.addTarget(self, action: #selector(self.sliderTouchDown), for: .touchDown)
        self.addSubview(self.slider)

        self.updateLabel(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(minScale: Float, maxScale: Float, currentScale: Float, defaultScale: Float) {
        let clampedMin = max(0.25, minScale)
        let clampedMax = max(clampedMin + 0.1, maxScale)
        self.minScale = clampedMin
        self.maxScale = clampedMax
        self.defaultScale = min(max(defaultScale, clampedMin), clampedMax)
        let clampedCurrent = min(max(currentScale, clampedMin), clampedMax)
        self.currentScale = clampedCurrent

        if !self.slider.isTracking {
            let progress = self.normalizedValue(for: clampedCurrent)
            if abs(self.slider.value - progress) > 0.001 {
                self.slider.value = progress
            }
        }
        self.updateLabel(animated: self.window != nil, emphasize: self.nearestDetent(for: clampedCurrent) != nil)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = self.bounds
        self.backgroundEffectView.frame = bounds
        self.tintOverlayView.frame = bounds
        let scale = self.traitCollection.displayScale > 0.0 ? self.traitCollection.displayScale : 2.0
        self.layer.borderWidth = 1.0 / scale
        self.layer.cornerRadius = min(Self.preferredHeight, bounds.height) * 0.5

        let buttonWidth: CGFloat = 48.0
        let leftInset: CGFloat = 6.0
        let rightInset: CGFloat = 12.0
        self.resetButton.frame = CGRect(x: leftInset, y: 0.0, width: buttonWidth, height: bounds.height)
        self.valueLabel.frame = self.resetButton.bounds
        let sliderX = leftInset + buttonWidth + 2.0
        let sliderWidth = max(0.0, bounds.width - sliderX - rightInset)
        self.slider.frame = CGRect(x: sliderX, y: 0.0, width: sliderWidth, height: bounds.height)
    }

    @objc private func sliderTouchDown() {
        self.impactFeedback.prepare()
        self.lastDetentStep = self.nearestDetent(for: self.currentScale)
    }

    @objc private func sliderChanged() {
        let newScale = self.scaleValue(for: self.slider.value)
        self.currentScale = newScale

        let detent = self.nearestDetent(for: newScale)
        self.updateLabel(animated: true, emphasize: detent != nil)
        if detent != self.lastDetentStep {
            if detent != nil {
                self.impactFeedback.impactOccurred()
                self.impactFeedback.prepare()
            }
            self.lastDetentStep = detent
        }

        self.onScaleChanged?(newScale)
    }

    @objc private func resetPressed() {
        let targetScale = self.defaultScale
        self.currentScale = targetScale
        self.slider.setValue(self.normalizedValue(for: targetScale), animated: true)
        self.updateLabel(animated: true, emphasize: true)
        self.impactFeedback.impactOccurred()
        self.onScaleChanged?(targetScale)
    }

    private func scaleValue(for normalized: Float) -> Float {
        let t = max(0.0, min(1.0, normalized))
        let ratio = self.maxScale / self.minScale
        let value = self.minScale * powf(ratio, t)
        return min(max(value, self.minScale), self.maxScale)
    }

    private func normalizedValue(for scale: Float) -> Float {
        let clamped = min(max(scale, self.minScale), self.maxScale)
        let ratio = self.maxScale / self.minScale
        guard ratio > 1.0001 else {
            return 0.0
        }
        return max(0.0, min(1.0, logf(clamped / self.minScale) / logf(ratio)))
    }

    private func nearestDetent(for scale: Float) -> Float? {
        let stops: [Float] = [0.5, 1.0, 2.0, 3.0, 5.0, 8.0, 10.0]
        for stop in stops where stop >= self.minScale - 0.02 && stop <= self.maxScale + 0.02 {
            if abs(scale - stop) <= 0.04 {
                return stop
            }
        }
        return nil
    }

    private func updateLabel(animated: Bool, emphasize: Bool = false) {
        let text: String
        if abs(self.currentScale - roundf(self.currentScale)) < 0.05 && self.currentScale >= 1.0 {
            text = "\(Int(roundf(self.currentScale)))×"
        } else {
            let rounded = roundf(self.currentScale * 10.0) / 10.0
            if abs(rounded - roundf(rounded)) < 0.01 {
                text = "\(Int(roundf(rounded)))×"
            } else {
                text = String(format: "%.1f×", rounded)
            }
        }
        let isDefault = abs(self.currentScale - self.defaultScale) <= 0.05
        let color = isDefault ? UIColor.white : UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1.0)
        self.valueLabel.textColor = color

        guard text != self.displayedText else {
            return
        }
        let direction: CGFloat = self.currentScale >= self.lastDisplayedScale ? 1.0 : -1.0
        let hadPrevious = !self.displayedText.isEmpty
        self.displayedText = text
        self.lastDisplayedScale = self.currentScale
        self.valueLabel.text = text

        if animated && hadPrevious && self.window != nil {
            self.animateValueBounce(direction: direction, emphasize: emphasize)
        }
    }

    private func animateValueBounce(direction: CGFloat, emphasize: Bool) {
        let peakScale: CGFloat = emphasize ? 1.24 : 1.14
        let offsetY: CGFloat = (emphasize ? 4.0 : 2.8) * direction
        let fromTransform = CATransform3DConcat(
            CATransform3DMakeScale(peakScale, peakScale, 1.0),
            CATransform3DMakeTranslation(0.0, offsetY, 0.0)
        )
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: fromTransform)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 0.75
        spring.stiffness = 420.0
        spring.damping = 15.0
        spring.initialVelocity = 0.0
        spring.duration = spring.settlingDuration
        spring.isRemovedOnCompletion = true
        self.valueLabel.layer.removeAnimation(forKey: "zoomNumberBounce")
        self.valueLabel.layer.add(spring, forKey: "zoomNumberBounce")
    }

    private static func makeThumbImage() -> UIImage {
        let size = CGSize(width: 20.0, height: 20.0)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let cgContext = context.cgContext
            let circleRect = CGRect(x: 2.0, y: 2.0, width: 16.0, height: 16.0)
            cgContext.setShadow(offset: CGSize(width: 0.0, height: 1.0), blur: 3.0, color: UIColor(white: 0.0, alpha: 0.45).cgColor)
            cgContext.setFillColor(UIColor.white.cgColor)
            cgContext.fillEllipse(in: circleRect)
        }
    }
}
