import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import ItemListPeerItem
import SwiftSignalKit
import AccountContext
import TelegramCore
import ItemListUI
import MergeLists

/// Settings ▸ accounts when there are many of them (Yougram has no account limit): a search
/// field over a list of fixed maximum height that scrolls on its own, so the Settings screen
/// doesn't grow with every account. The list is a virtualized ListView, so only the visible
/// rows exist even with hundreds of accounts.
final class PeerInfoScreenAccountsBoxItem: PeerInfoScreenItem {
    struct Account {
        let id: AccountRecordId
        let context: ItemListPeerItem.Context
        let peer: EnginePeer
        let badge: String?
    }

    let id: AnyHashable
    let accounts: [Account]
    let searchPlaceholder: String
    let noResultsText: String
    let switchToAccount: (AccountRecordId) -> Void
    let logoutAccount: (AccountRecordId) -> Void
    let contextAction: (AccountRecordId, ASDisplayNode, ContextGesture?) -> Void

    init(
        id: AnyHashable,
        accounts: [Account],
        searchPlaceholder: String,
        noResultsText: String,
        switchToAccount: @escaping (AccountRecordId) -> Void,
        logoutAccount: @escaping (AccountRecordId) -> Void,
        contextAction: @escaping (AccountRecordId, ASDisplayNode, ContextGesture?) -> Void
    ) {
        self.id = id
        self.accounts = accounts
        self.searchPlaceholder = searchPlaceholder
        self.noResultsText = noResultsText
        self.switchToAccount = switchToAccount
        self.logoutAccount = logoutAccount
        self.contextAction = contextAction
    }

    func node() -> PeerInfoScreenItemNode {
        return PeerInfoScreenAccountsBoxItemNode()
    }
}

/// Whether an account matches a search query: name, username, phone number or user id.
func yougramAccountMatches(peer: EnginePeer, query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if query.isEmpty {
        return true
    }
    let digits = query.filter(\.isNumber)
    if peer.debugDisplayTitle.lowercased().contains(query) {
        return true
    }
    if let username = peer.addressName?.lowercased(), username.contains(query.hasPrefix("@") ? String(query.dropFirst()) : query) {
        return true
    }
    if !digits.isEmpty {
        if case let .user(user) = peer, let phone = user.phone, phone.contains(digits) {
            return true
        }
        if "\(peer.id.id._internalGetInt64Value())".contains(digits) {
            return true
        }
    }
    return false
}

private struct AccountsBoxEntry: Comparable, Identifiable {
    let index: Int
    let account: PeerInfoScreenAccountsBoxItem.Account
    let theme: PresentationTheme

    var stableId: Int64 {
        return self.account.id.int64
    }

    static func ==(lhs: AccountsBoxEntry, rhs: AccountsBoxEntry) -> Bool {
        return lhs.index == rhs.index && lhs.account.id == rhs.account.id && lhs.account.peer == rhs.account.peer && lhs.account.badge == rhs.account.badge && lhs.theme === rhs.theme
    }

    static func <(lhs: AccountsBoxEntry, rhs: AccountsBoxEntry) -> Bool {
        return lhs.index < rhs.index
    }
}

private final class PeerInfoScreenAccountsBoxItemNode: PeerInfoScreenItemNode, UITextFieldDelegate {
    private let searchBackgroundNode: ASDisplayNode
    private var searchField: UITextField?
    private var searchIconView: UIImageView?
    private let listView: ListViewImpl
    private let emptyTextNode: ImmediateTextNode
    private let maskNode: ASImageNode

    private var item: PeerInfoScreenAccountsBoxItem?
    private var presentationData: PresentationData?
    private var query: String = ""
    private var entries: [AccountsBoxEntry] = []
    private var measuredRowHeight: (width: CGFloat, height: CGFloat)?
    private var lastLayout: (width: CGFloat, safeInsets: UIEdgeInsets, listHeight: CGFloat)?

    private static let searchHeight: CGFloat = 52.0
    private static let maximumVisibleRows: CGFloat = 5.5

    override init() {
        self.searchBackgroundNode = ASDisplayNode()
        self.searchBackgroundNode.cornerRadius = 10.0
        self.listView = ListViewImpl()
        self.listView.clipsToBounds = true
        self.emptyTextNode = ImmediateTextNode()
        self.emptyTextNode.isUserInteractionEnabled = false
        self.maskNode = ASImageNode()
        self.maskNode.isUserInteractionEnabled = false

        super.init()

        self.clipsToBounds = true
        self.addSubnode(self.searchBackgroundNode)
        self.addSubnode(self.listView)
        self.addSubnode(self.emptyTextNode)
    }

    override func didLoad() {
        super.didLoad()

        let field = UITextField()
        field.delegate = self
        field.font = Font.regular(17.0)
        field.returnKeyType = .search
        field.clearButtonMode = .whileEditing
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.addTarget(self, action: #selector(self.searchChanged), for: .editingChanged)
        self.searchField = field
        self.view.addSubview(field)

        let icon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        icon.contentMode = .scaleAspectFit
        self.searchIconView = icon
        self.view.addSubview(icon)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc private func searchChanged() {
        self.query = self.searchField?.text ?? ""
        self.reloadList()
    }

    private func filteredAccounts() -> [PeerInfoScreenAccountsBoxItem.Account] {
        guard let item = self.item else {
            return []
        }
        return item.accounts.filter { yougramAccountMatches(peer: $0.peer, query: self.query) }
    }

    private func rowItem(for account: PeerInfoScreenAccountsBoxItem.Account, item: PeerInfoScreenAccountsBoxItem, presentationData: PresentationData) -> ListViewItem {
        let logoutOption = ItemListPeerItemRevealOption(type: .destructive, title: presentationData.strings.Settings_Context_Logout, action: {
            item.logoutAccount(account.id)
        })
        return ItemListPeerItem(presentationData: ItemListPresentationData(presentationData), systemStyle: .glass, dateTimeFormat: presentationData.dateTimeFormat, nameDisplayOrder: presentationData.nameDisplayOrder, context: account.context, peer: account.peer, height: .generic, presence: nil, text: .none, label: account.badge.flatMap { .badge($0) } ?? .none, editing: ItemListPeerItemEditing(editable: true, editing: false, revealed: nil), revealOptions: ItemListPeerItemRevealOptions(options: [logoutOption]), switchValue: nil, enabled: true, selectable: true, animateFirstAvatarTransition: false, sectionId: 0, action: {
            item.switchToAccount(account.id)
        }, setPeerIdWithRevealedOptions: { _, _ in
        }, removePeer: { _ in
        }, contextAction: { node, gesture in
            item.contextAction(account.id, node, gesture)
        }, hasTopStripe: false, hasTopGroupInset: false, noInsets: true, noCorners: true, displayDecorations: false)
    }

    /// The height of one row, measured by laying out a real row (fonts scale with Dynamic Type).
    private func rowHeight(width: CGFloat, item: PeerInfoScreenAccountsBoxItem, presentationData: PresentationData) -> CGFloat {
        if let measured = self.measuredRowHeight, measured.width == width {
            return measured.height
        }
        guard let account = item.accounts.first else {
            return 52.0
        }
        var height: CGFloat = 52.0
        let params = ListViewItemLayoutParams(width: width, leftInset: 0.0, rightInset: 0.0, availableHeight: 1000.0)
        self.rowItem(for: account, item: item, presentationData: presentationData).nodeConfiguredForParams(async: { $0() }, params: params, synchronousLoads: false, neighbors: .none, completion: { node, _ in
            height = node.contentSize.height
        })
        self.measuredRowHeight = (width, height)
        return height
    }

    private func reloadList(updateAll: Bool = false) {
        guard let item = self.item, let presentationData = self.presentationData else {
            return
        }
        let accounts = self.filteredAccounts()
        let newEntries = accounts.enumerated().map { AccountsBoxEntry(index: $0.offset, account: $0.element, theme: presentationData.theme) }
        // Rows hold closures from the item, which is new on every Settings update: refresh all of them then.
        let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: self.entries, rightList: newEntries, allUpdated: updateAll)
        self.entries = newEntries

        let deletions = deleteIndices.map { ListViewDeleteItem(index: $0, directionHint: nil) }
        let insertions = indicesAndItems.map { ListViewInsertItem(index: $0.0, previousIndex: $0.2, item: self.rowItem(for: $0.1.account, item: item, presentationData: presentationData), directionHint: nil) }
        let updates = updateIndices.map { ListViewUpdateItem(index: $0.0, previousIndex: $0.2, item: self.rowItem(for: $0.1.account, item: item, presentationData: presentationData), directionHint: nil) }
        self.listView.transaction(deleteIndices: deletions, insertIndicesAndItems: insertions, updateIndicesAndItems: updates, options: [.Synchronous, .LowLatency], updateOpaqueState: nil)

        self.emptyTextNode.isHidden = !accounts.isEmpty
    }

    override func update(context: AccountContext, width: CGFloat, safeInsets: UIEdgeInsets, presentationData: PresentationData, item: PeerInfoScreenItem, topItem: PeerInfoScreenItem?, bottomItem: PeerInfoScreenItem?, hasCorners: Bool, transition: ContainedViewLayoutTransition) -> CGFloat {
        guard let item = item as? PeerInfoScreenAccountsBoxItem else {
            return 10.0
        }
        let themeChanged = self.presentationData?.theme !== presentationData.theme
        self.item = item
        self.presentationData = presentationData

        let theme = presentationData.theme
        let sideInset: CGFloat = 16.0 + safeInsets.left
        let contentWidth = width - safeInsets.left - safeInsets.right

        if themeChanged {
            self.searchBackgroundNode.backgroundColor = theme.list.itemInputField.backgroundColor
            self.searchField?.textColor = theme.list.itemInputField.primaryColor
            self.searchField?.tintColor = theme.list.itemAccentColor
            self.searchField?.keyboardAppearance = theme.rootController.keyboardColor.keyboardAppearance
            self.searchIconView?.tintColor = theme.list.itemInputField.controlColor
        }
        self.searchField?.attributedPlaceholder = NSAttributedString(string: item.searchPlaceholder, font: Font.regular(17.0), textColor: theme.list.itemInputField.placeholderColor)
        self.emptyTextNode.attributedText = NSAttributedString(string: item.noResultsText, font: Font.regular(15.0), textColor: theme.list.itemSecondaryTextColor)

        // Search field.
        let fieldFrame = CGRect(x: sideInset, y: 8.0, width: width - sideInset * 2.0 - safeInsets.right + safeInsets.left, height: 36.0)
        transition.updateFrame(node: self.searchBackgroundNode, frame: fieldFrame)
        self.searchIconView?.frame = CGRect(x: fieldFrame.minX + 8.0, y: fieldFrame.midY - 9.0, width: 18.0, height: 18.0)
        self.searchField?.frame = CGRect(x: fieldFrame.minX + 32.0, y: fieldFrame.minY, width: fieldFrame.width - 36.0, height: fieldFrame.height)

        // List: as tall as its rows, up to maximumVisibleRows; it scrolls itself beyond that.
        let rowHeight = self.rowHeight(width: contentWidth, item: item, presentationData: presentationData)
        let visibleCount = max(1, item.accounts.filter { yougramAccountMatches(peer: $0.peer, query: self.query) }.count)
        let listHeight = floor(min(CGFloat(visibleCount), Self.maximumVisibleRows) * rowHeight)
        let listFrame = CGRect(x: safeInsets.left, y: Self.searchHeight, width: contentWidth, height: listHeight)

        if self.lastLayout?.width != width || self.lastLayout?.listHeight != listHeight || self.lastLayout?.safeInsets != safeInsets {
            self.lastLayout = (width, safeInsets, listHeight)
            transition.updateFrame(node: self.listView, frame: listFrame)
            self.listView.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: nil, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: listFrame.size, insets: UIEdgeInsets(), duration: 0.0, curve: .Default(duration: nil)), stationaryItemRange: nil, updateOpaqueState: nil)
        }
        self.reloadList(updateAll: true)

        let emptySize = self.emptyTextNode.updateLayout(CGSize(width: contentWidth - 32.0, height: 100.0))
        self.emptyTextNode.frame = CGRect(origin: CGPoint(x: safeInsets.left + floor((contentWidth - emptySize.width) / 2.0), y: listFrame.minY + floor((listHeight - emptySize.height) / 2.0)), size: emptySize)

        let height = Self.searchHeight + listHeight

        let hasCorners = hasCorners && (topItem == nil || bottomItem == nil)
        self.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(theme, top: hasCorners && topItem == nil, bottom: hasCorners && bottomItem == nil, glass: true) : nil
        self.maskNode.frame = CGRect(origin: CGPoint(x: safeInsets.left, y: 0.0), size: CGSize(width: contentWidth, height: height))
        if self.maskNode.supernode == nil {
            self.addSubnode(self.maskNode)
        }
        return height
    }
}
