import Foundation
import UIKit
import Display
import TelegramPresentationData

private final class YougramPlainIconCache {
    static let shared = YougramPlainIconCache()

    private let lock = NSLock()
    private var cache: [String: UIImage] = [:]

    func image(symbolName: String, color: UIColor) -> UIImage? {
        let key = "\(symbolName)|\(color.argb)"
        self.lock.lock()
        if let existing = self.cache[key] {
            self.lock.unlock()
            return existing
        }
        self.lock.unlock()

        let configuration = UIImage.SymbolConfiguration(pointSize: 19.0, weight: .regular)
        guard let symbolImage = UIImage(systemName: symbolName, withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal) else {
            return nil
        }

        let canvasSize = CGSize(width: 26.0, height: 26.0)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let rendered = renderer.image { _ in
            let maxSide: CGFloat = 24.0
            let rawSize = symbolImage.size
            let scale: CGFloat
            if rawSize.width > 0.0 && rawSize.height > 0.0 {
                scale = min(1.0, min(maxSide / rawSize.width, maxSide / rawSize.height))
            } else {
                scale = 1.0
            }
            let drawSize = CGSize(width: rawSize.width * scale, height: rawSize.height * scale)
            let drawOrigin = CGPoint(
                x: (canvasSize.width - drawSize.width) * 0.5,
                y: (canvasSize.height - drawSize.height) * 0.5
            )
            symbolImage.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }.withRenderingMode(.alwaysOriginal)

        self.lock.lock()
        self.cache[key] = rendered
        self.lock.unlock()
        return rendered
    }
}

func yougramPlainIcon(symbolName: String, color: UIColor) -> UIImage? {
    return YougramPlainIconCache.shared.image(symbolName: symbolName, color: color)
}

func yougramIcon(_ symbolName: String, theme: PresentationTheme, enabled: Bool = true, destructive: Bool = false) -> UIImage? {
    let color: UIColor
    if destructive {
        color = theme.list.itemDestructiveColor
    } else if enabled {
        color = theme.list.itemAccentColor
    } else {
        color = theme.list.itemDisabledTextColor
    }
    return yougramPlainIcon(symbolName: symbolName, color: color)
}
