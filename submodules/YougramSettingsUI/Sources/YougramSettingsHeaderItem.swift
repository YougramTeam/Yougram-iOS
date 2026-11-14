import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AppBundle

/// The top of Settings ▸ Yougram: the app icon, "Yougram <version>" and a one-line description.
final class YougramSettingsHeaderItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let title: String
    let text: String
    let sectionId: ItemListSectionId

    init(theme: PresentationTheme, title: String, text: String, sectionId: ItemListSectionId) {
        self.theme = theme
        self.title = title
        self.text = text
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = YougramSettingsHeaderItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? YougramSettingsHeaderItemNode else {
                assertionFailure()
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
                Queue.mainQueue().async {
                    completion(layout, { _ in
                        apply()
                    })
                }
            }
        }
    }
}

private let iconSize: CGFloat = 92.0
private let titleFont = Font.semibold(22.0)
private let textFont = Font.regular(14.0)

final class YougramSettingsHeaderItemNode: ListViewItemNode {
    private let iconNode: ASImageNode
    private let titleNode: TextNode
    private let textNode: TextNode

    init() {
        self.iconNode = ASImageNode()
        self.iconNode.displaysAsynchronously = false
        self.iconNode.isUserInteractionEnabled = false
        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.textNode = TextNode()
        self.textNode.isUserInteractionEnabled = false

        super.init(layerBacked: false)

        self.addSubnode(self.iconNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.textNode)
        self.isAccessibilityElement = true
        self.accessibilityTraits = .header
    }

    func asyncLayout() -> (_ item: YougramSettingsHeaderItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makeTextLayout = TextNode.asyncLayout(self.textNode)

        return { [weak self] item, params, neighbors in
            let width = params.width - params.leftInset - params.rightInset - 48.0
            let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.title, font: titleFont, textColor: item.theme.list.itemPrimaryTextColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: width, height: .greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: UIEdgeInsets()))
            let (textLayout, textApply) = makeTextLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.text, font: textFont, textColor: item.theme.list.freeTextColor), backgroundColor: nil, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: width, height: .greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: UIEdgeInsets()))

            let topInset: CGFloat = 8.0
            let height = topInset + iconSize + 14.0 + titleLayout.size.height + 6.0 + textLayout.size.height + 8.0
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: itemListNeighborsGroupedInsets(neighbors, params))

            return (layout, {
                guard let self else {
                    return
                }
                if self.iconNode.image == nil {
                    self.iconNode.image = yougramRoundedAppIcon(size: iconSize)
                }
                let _ = titleApply()
                let _ = textApply()
                let centerX = params.leftInset + (params.width - params.leftInset - params.rightInset) / 2.0
                self.iconNode.frame = CGRect(x: floor(centerX - iconSize / 2.0), y: topInset, width: iconSize, height: iconSize)
                let titleY = topInset + iconSize + 14.0
                self.titleNode.frame = CGRect(origin: CGPoint(x: floor(centerX - titleLayout.size.width / 2.0), y: titleY), size: titleLayout.size)
                self.textNode.frame = CGRect(origin: CGPoint(x: floor(centerX - textLayout.size.width / 2.0), y: titleY + titleLayout.size.height + 6.0), size: textLayout.size)
                self.accessibilityLabel = "\(item.title). \(item.text)"
            })
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}

/// The current home-screen icon's artwork, rounded like the home screen draws it.
/// The alternate icons ship as loose PNGs in the bundle ("Purple@3x.png" is the default).
func yougramRoundedAppIcon(size: CGFloat) -> UIImage? {
    let name = UIApplication.shared.alternateIconName ?? "Purple"
    guard let source = UIImage(named: name, in: getAppBundle(), compatibleWith: nil) ?? UIImage(named: "Purple", in: getAppBundle(), compatibleWith: nil) else {
        return nil
    }
    // contextGenerator: Core Graphics coordinates, so the CGImage draws upright.
    return generateImage(CGSize(width: size, height: size), contextGenerator: { contextSize, context in
        context.clear(CGRect(origin: .zero, size: contextSize))
        let rect = CGRect(origin: .zero, size: contextSize)
        context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: contextSize.width * 0.225).cgPath)
        context.clip()
        if let cgImage = source.cgImage {
            context.draw(cgImage, in: rect)
        }
    })
}
