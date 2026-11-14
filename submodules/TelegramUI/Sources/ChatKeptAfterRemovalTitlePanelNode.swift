import Foundation
import UIKit
import Display
import AsyncDisplayKit
import TelegramCore
import TelegramPresentationData
import ChatPresentationInterfaceState
import LegacyChatHeaderPanelComponent

/// Yougram: the banner of a chat kept after the user was removed from it (`YougramCoreOptions.keepChatsAfterRemoval`):
/// a channel or supergroup they were banned from, or a basic group they were removed from. A banned channel that the
/// chat still shows as private (one outside the chat list, `ChatControllerContentData`) has nothing stored to show and
/// gets no banner.
func chatKeptAfterRemovalBannerText(_ interfaceState: ChatPresentationInterfaceState) -> String? {
    guard YougramCoreOptions.keepChatsAfterRemoval else {
        return nil
    }
    if let channel = interfaceState.renderedPeer?.peer as? TelegramChannel, case .kicked = channel.participationStatus {
        if interfaceState.isNotAccessible {
            return nil
        }
        return interfaceState.strings.Yougram_Chat_BannedFromChannel
    } else if let group = interfaceState.renderedPeer?.peer as? TelegramGroup, case .Removed = group.membership {
        return interfaceState.strings.Yougram_Chat_RemovedFromGroup
    }
    return nil
}

/// A centred, multi-line notice under the navigation bar; it has no actions.
final class ChatKeptAfterRemovalTitlePanelNode: ChatTitleAccessoryPanelNode {
    private let separatorNode: ASDisplayNode
    private let textNode: ImmediateTextNode

    private var theme: PresentationTheme?
    private var text: String?

    override init() {
        self.separatorNode = ASDisplayNode()
        self.separatorNode.isLayerBacked = true

        self.textNode = ImmediateTextNode()
        self.textNode.displaysAsynchronously = false
        self.textNode.maximumNumberOfLines = 0
        self.textNode.textAlignment = .center

        super.init()

        self.isAccessibilityElement = true
        self.accessibilityTraits = .staticText

        self.addSubnode(self.textNode)
        self.addSubnode(self.separatorNode)
    }

    override func updateLayout(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition, interfaceState: ChatPresentationInterfaceState) -> LayoutResult {
        let text = chatKeptAfterRemovalBannerText(interfaceState) ?? ""
        if interfaceState.theme !== self.theme || text != self.text {
            self.theme = interfaceState.theme
            self.text = text

            self.separatorNode.backgroundColor = interfaceState.theme.rootController.navigationBar.separatorColor
            self.textNode.attributedText = NSAttributedString(string: text, font: Font.regular(13.0), textColor: interfaceState.theme.rootController.navigationBar.secondaryTextColor)
            self.accessibilityLabel = text
        }

        let verticalInset: CGFloat = 10.0
        let textSize = self.textNode.updateLayout(CGSize(width: max(1.0, width - leftInset - rightInset - 16.0 * 2.0), height: CGFloat.greatestFiniteMagnitude))
        let panelHeight = max(40.0, textSize.height + verticalInset * 2.0)

        transition.updateFrame(node: self.textNode, frame: CGRect(origin: CGPoint(x: floor((width - textSize.width) / 2.0), y: floor((panelHeight - textSize.height) / 2.0)), size: textSize))
        transition.updateFrame(node: self.separatorNode, frame: CGRect(origin: CGPoint(), size: CGSize(width: width, height: UIScreenPixel)))

        return LayoutResult(backgroundHeight: panelHeight, insetHeight: panelHeight, hitTestSlop: 0.0)
    }
}
