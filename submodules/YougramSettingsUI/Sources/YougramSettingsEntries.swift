import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext

/// Where a disclosure row leads.
enum YougramSettingsLink: Equatable {
    case general
    case appearance
    case chats
    case privacy
    case ghostMode
    case localHistory
    case localEncryption
    case accountsBackup
    case contextMenu
    case duressCode
    case url(String)
}

enum YougramLinkLabelStyle: Equatable {
    case text
    case detailText
}

/// The one entry type every Yougram settings screen is built from.
enum YougramSettingsEntry: ItemListNodeEntry {
    case searchInput(id: Int32, section: Int32, text: String, placeholder: String)
    case appHeader(id: Int32, section: Int32, version: String, text: String)
    case header(id: Int32, section: Int32, text: String)
    case toggle(id: Int32, section: Int32, icon: UIImage?, title: String, subtitle: String?, value: Bool, key: WritableKeyPath<YougramSettings, Bool>, enabled: Bool, requiresRestart: Bool)
    case contextMenuToggle(id: Int32, section: Int32, title: String, value: Bool, action: YougramContextMenuAction)
    /// A switch whose value lives outside YougramSettings; changes go to `customToggle(tag:)`.
    case taggedToggle(id: Int32, section: Int32, icon: UIImage?, title: String, value: Bool, tag: String)
    case info(id: Int32, section: Int32, text: String)
    case link(id: Int32, section: Int32, icon: UIImage?, title: String, label: String, labelStyle: YougramLinkLabelStyle, target: YougramSettingsLink)
    case action(id: Int32, section: Int32, title: String, destructive: Bool, tag: String)
    case backup(id: Int32, section: Int32, title: String, label: String, peerId: Int64)

    var section: ItemListSectionId {
        switch self {
        case let .searchInput(_, section, _, _), let .appHeader(_, section, _, _), let .header(_, section, _),
             let .toggle(_, section, _, _, _, _, _, _, _), let .contextMenuToggle(_, section, _, _, _),
             let .taggedToggle(_, section, _, _, _, _), let .info(_, section, _),
             let .link(_, section, _, _, _, _, _), let .action(_, section, _, _, _), let .backup(_, section, _, _, _):
            return section
        }
    }

    var stableId: Int32 {
        switch self {
        case let .searchInput(id, _, _, _), let .appHeader(id, _, _, _), let .header(id, _, _),
             let .toggle(id, _, _, _, _, _, _, _, _), let .contextMenuToggle(id, _, _, _, _),
             let .taggedToggle(id, _, _, _, _, _), let .info(id, _, _),
             let .link(id, _, _, _, _, _, _), let .action(id, _, _, _, _), let .backup(id, _, _, _, _):
            return id
        }
    }

    static func <(lhs: YougramSettingsEntry, rhs: YougramSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! YougramSettingsArguments
        switch self {
        case let .searchInput(_, section, text, placeholder):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(),
                text: text,
                placeholder: placeholder,
                type: .regular(capitalization: false, autocorrection: false),
                returnKeyType: .search,
                clearType: .always,
                sectionId: section,
                textUpdated: { value in
                    arguments.updateSearchQuery(value)
                },
                action: {},
                cleared: {
                    arguments.updateSearchQuery("")
                }
            )
        case let .appHeader(_, section, version, text):
            return YougramSettingsHeaderItem(theme: presentationData.theme, title: version, text: text, sectionId: section)
        case let .header(_, section, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .toggle(_, section, icon, title, subtitle, value, key, enabled, requiresRestart):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: title, text: subtitle, value: value, enabled: enabled, sectionId: section, style: .blocks, updated: { value in
                arguments.updateToggle(key, value, requiresRestart)
            })
        case let .contextMenuToggle(_, section, title, value, action):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: section, style: .blocks, updated: { value in
                arguments.updateContextMenuAction(action, value)
            })
        case let .taggedToggle(_, section, icon, title, value, tag):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: title, value: value, sectionId: section, style: .blocks, updated: { value in
                arguments.customToggle(tag, value)
            })
        case let .info(_, section, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .link(_, section, icon, title, label, labelStyle, target):
            let resolvedLabelStyle: ItemListDisclosureLabelStyle
            switch labelStyle {
            case .text:
                resolvedLabelStyle = .text
            case .detailText:
                resolvedLabelStyle = .detailText
            }
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: title, label: label, labelStyle: resolvedLabelStyle, sectionId: section, style: .blocks, action: {
                arguments.open(target)
            })
        case let .action(_, section, title, destructive, tag):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: destructive ? .destructive : .generic, alignment: .natural, sectionId: section, style: .blocks, action: {
                arguments.performAction(tag)
            })
        case let .backup(_, section, title, label, peerId):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, sectionId: section, style: .blocks, disclosureStyle: .none, action: {
                arguments.performAction("deleteBackup:\(peerId)")
            })
        }
    }
}

final class YougramSettingsArguments {
    let updateToggle: (WritableKeyPath<YougramSettings, Bool>, Bool, Bool) -> Void
    let updateContextMenuAction: (YougramContextMenuAction, Bool) -> Void
    let customToggle: (String, Bool) -> Void
    let updateSearchQuery: (String) -> Void
    let open: (YougramSettingsLink) -> Void
    let performAction: (String) -> Void

    init(
        updateToggle: @escaping (WritableKeyPath<YougramSettings, Bool>, Bool, Bool) -> Void,
        updateContextMenuAction: @escaping (YougramContextMenuAction, Bool) -> Void = { _, _ in },
        customToggle: @escaping (String, Bool) -> Void = { _, _ in },
        updateSearchQuery: @escaping (String) -> Void = { _ in },
        open: @escaping (YougramSettingsLink) -> Void = { _ in },
        performAction: @escaping (String) -> Void = { _ in }
    ) {
        self.updateToggle = updateToggle
        self.updateContextMenuAction = updateContextMenuAction
        self.customToggle = customToggle
        self.updateSearchQuery = updateSearchQuery
        self.open = open
        self.performAction = performAction
    }
}

/// Builds rows with increasing ids, so screens list rows in the order they're written.
struct YougramEntriesBuilder {
    private(set) var entries: [YougramSettingsEntry] = []
    private var nextId: Int32 = 0
    private var section: Int32 = 0

    mutating func newSection() {
        if !self.entries.isEmpty {
            self.section += 1
        }
    }

    private mutating func id() -> Int32 {
        self.nextId += 1
        return self.nextId
    }

    mutating func searchInput(text: String, placeholder: String) {
        self.entries.append(.searchInput(id: 0, section: self.section, text: text, placeholder: placeholder))
    }

    mutating func appHeader(version: String, text: String) {
        self.entries.append(.appHeader(id: self.id(), section: self.section, version: version, text: text))
    }

    mutating func header(_ text: String) {
        self.entries.append(.header(id: self.id(), section: self.section, text: text))
    }

    mutating func toggle(_ title: String, _ settings: YougramSettings, _ key: WritableKeyPath<YougramSettings, Bool>, icon: UIImage? = nil, subtitle: String? = nil, enabled: Bool = true, displayValue: Bool? = nil, requiresRestart: Bool = false) {
        let resolvedValue = displayValue ?? (enabled ? settings[keyPath: key] : false)
        self.entries.append(.toggle(id: self.id(), section: self.section, icon: icon, title: title, subtitle: subtitle, value: resolvedValue, key: key, enabled: enabled, requiresRestart: requiresRestart))
    }

    mutating func contextMenuToggle(_ title: String, _ settings: YougramSettings, _ action: YougramContextMenuAction) {
        self.entries.append(.contextMenuToggle(id: self.id(), section: self.section, title: title, value: !settings.isContextMenuActionHidden(action.rawValue), action: action))
    }

    mutating func taggedToggle(_ title: String, value: Bool, icon: UIImage? = nil, tag: String) {
        self.entries.append(.taggedToggle(id: self.id(), section: self.section, icon: icon, title: title, value: value, tag: tag))
    }

    mutating func info(_ text: String) {
        self.entries.append(.info(id: self.id(), section: self.section, text: text))
    }

    mutating func link(_ title: String, icon: UIImage? = nil, label: String = "", labelStyle: YougramLinkLabelStyle = .text, to target: YougramSettingsLink) {
        self.entries.append(.link(id: self.id(), section: self.section, icon: icon, title: title, label: label, labelStyle: labelStyle, target: target))
    }

    mutating func action(_ title: String, destructive: Bool = false, tag: String) {
        self.entries.append(.action(id: self.id(), section: self.section, title: title, destructive: destructive, tag: tag))
    }

    mutating func backup(_ title: String, label: String, peerId: Int64) {
        self.entries.append(.backup(id: self.id(), section: self.section, title: title, label: label, peerId: peerId))
    }
}
