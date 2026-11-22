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
import UndoUI

private struct ChatExportScreenState: Equatable {
    var options: YougramChatExportOptions
    var isExporting: Bool
    var progress: YougramChatExportProgress?
    var lastResult: YougramChatExportResult?
    var errorMessage: String?
}

private enum ChatExportSection: Int32 {
    case format = 0
    case dateRange = 1
    case media = 2
    case advanced = 3
    case actions = 4
}

private enum ChatExportEntry: ItemListNodeEntry {
    case formatHeader(Int32, String)
    case formatOption(Int32, YougramChatExportFormat, String, Bool)
    case dateHeader(Int32, String)
    case fromDateRow(Int32, String, Bool)
    case toDateRow(Int32, String, Bool)
    case dateInfo(Int32, String)
    case mediaHeader(Int32, String)
    case includeMediaToggle(Int32, Bool, Bool)
    case photosOnlyToggle(Int32, Bool, Bool)
    case maxFileSizeRow(Int32, String, Bool)
    case maxTotalSizeRow(Int32, String, Bool)
    case advancedHeader(Int32, String)
    case fetchCloudToggle(Int32, Bool, Bool, Bool)
    case includeServiceToggle(Int32, Bool, Bool)
    case includeDeletedToggle(Int32, Bool, Bool)
    case exportButton(Int32, String)
    case cancelButton(Int32, String)
    case shareLastButton(Int32, String)
    case statusText(Int32, String)

    var section: ItemListSectionId {
        switch self {
        case .formatHeader, .formatOption:
            return ChatExportSection.format.rawValue
        case .dateHeader, .fromDateRow, .toDateRow, .dateInfo:
            return ChatExportSection.dateRange.rawValue
        case .mediaHeader, .includeMediaToggle, .photosOnlyToggle, .maxFileSizeRow, .maxTotalSizeRow:
            return ChatExportSection.media.rawValue
        case .advancedHeader, .fetchCloudToggle, .includeServiceToggle, .includeDeletedToggle:
            return ChatExportSection.advanced.rawValue
        case .exportButton, .cancelButton, .shareLastButton, .statusText:
            return ChatExportSection.actions.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case let .formatHeader(id, _),
             let .formatOption(id, _, _, _),
             let .dateHeader(id, _),
             let .fromDateRow(id, _, _),
             let .toDateRow(id, _, _),
             let .dateInfo(id, _),
             let .mediaHeader(id, _),
             let .includeMediaToggle(id, _, _),
             let .photosOnlyToggle(id, _, _),
             let .maxFileSizeRow(id, _, _),
             let .maxTotalSizeRow(id, _, _),
             let .advancedHeader(id, _),
             let .fetchCloudToggle(id, _, _, _),
             let .includeServiceToggle(id, _, _),
             let .includeDeletedToggle(id, _, _),
             let .exportButton(id, _),
             let .cancelButton(id, _),
             let .shareLastButton(id, _),
             let .statusText(id, _):
            return id
        }
    }

    static func <(lhs: ChatExportEntry, rhs: ChatExportEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let args = arguments as! ChatExportArguments
        let theme = presentationData.theme
        let sectionId = self.section

        switch self {
        case let .formatHeader(_, text),
             let .dateHeader(_, text),
             let .mediaHeader(_, text),
             let .advancedHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: sectionId)

        case let .formatOption(_, format, title, isSelected):
            let iconName = isSelected ? "checkmark.circle.fill" : "circle"
            let icon = yougramIcon(iconName, theme: theme, enabled: isSelected)
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: icon,
                title: title,
                label: ".\(format.fileExtension)",
                labelStyle: .text,
                sectionId: sectionId,
                style: .blocks,
                disclosureStyle: .none,
                action: {
                    args.selectFormat(format)
                }
            )

        case let .fromDateRow(_, label, enabled):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: yougramIcon("calendar", theme: theme, enabled: enabled),
                title: "From Date",
                enabled: enabled,
                label: label,
                labelStyle: .text,
                sectionId: sectionId,
                style: .blocks,
                action: {
                    args.pickFromDate()
                }
            )

        case let .toDateRow(_, label, enabled):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: yougramIcon("calendar.badge.clock", theme: theme, enabled: enabled),
                title: "To Date",
                enabled: enabled,
                label: label,
                labelStyle: .text,
                sectionId: sectionId,
                style: .blocks,
                action: {
                    args.pickToDate()
                }
            )

        case let .dateInfo(_, text), let .statusText(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: sectionId)

        case let .includeMediaToggle(_, value, enabled):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: yougramIcon("photo.on.rectangle", theme: theme, enabled: enabled),
                title: "Include Cached Media",
                value: value,
                enabled: enabled,
                sectionId: sectionId,
                style: .blocks,
                updated: { updated in
                    args.toggleIncludeMedia(updated)
                }
            )

        case let .photosOnlyToggle(_, value, enabled):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: yougramIcon("photo", theme: theme, enabled: enabled),
                title: "Photos Only",
                value: value,
                enabled: enabled,
                sectionId: sectionId,
                style: .blocks,
                updated: { updated in
                    args.togglePhotosOnly(updated)
                }
            )

        case let .maxFileSizeRow(_, label, enabled):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: yougramIcon("doc.badge.gearshape", theme: theme, enabled: enabled),
                title: "Max Single File Size",
                enabled: enabled,
                label: label,
                labelStyle: .text,
                sectionId: sectionId,
                style: .blocks,
                action: {
                    args.pickMaxFileSize()
                }
            )

        case let .maxTotalSizeRow(_, label, enabled):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: yougramIcon("externaldrive", theme: theme, enabled: enabled),
                title: "Total Export Size Limit",
                enabled: enabled,
                label: label,
                labelStyle: .text,
                sectionId: sectionId,
                style: .blocks,
                action: {
                    args.pickMaxTotalSize()
                }
            )

        case let .fetchCloudToggle(_, value, isSecretChat, enabled):
            let subtitle: String? = isSecretChat ? "Not available for secret chats (device-only)." : "Fetches older server history outside local cache."
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: yougramIcon("icloud.and.arrow.down", theme: theme, enabled: enabled && !isSecretChat),
                title: "Fetch Cloud History",
                text: subtitle,
                value: isSecretChat ? false : value,
                enabled: enabled && !isSecretChat,
                sectionId: sectionId,
                style: .blocks,
                updated: { updated in
                    args.toggleFetchCloud(updated)
                }
            )

        case let .includeServiceToggle(_, value, enabled):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: yougramIcon("info.circle", theme: theme, enabled: enabled),
                title: "Include Service Messages",
                value: value,
                enabled: enabled,
                sectionId: sectionId,
                style: .blocks,
                updated: { updated in
                    args.toggleIncludeService(updated)
                }
            )

        case let .includeDeletedToggle(_, value, enabled):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: yougramIcon("trash", theme: theme, enabled: enabled),
                title: "Include Saved Deleted Messages",
                value: value,
                enabled: enabled,
                sectionId: sectionId,
                style: .blocks,
                updated: { updated in
                    args.toggleIncludeDeleted(updated)
                }
            )

        case let .exportButton(_, title):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                kind: .generic,
                alignment: .natural,
                sectionId: sectionId,
                style: .blocks,
                action: {
                    args.startExport()
                }
            )

        case let .cancelButton(_, title):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                kind: .destructive,
                alignment: .natural,
                sectionId: sectionId,
                style: .blocks,
                action: {
                    args.cancelExport()
                }
            )

        case let .shareLastButton(_, title):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                kind: .generic,
                alignment: .natural,
                sectionId: sectionId,
                style: .blocks,
                action: {
                    args.shareLastExport()
                }
            )
        }
    }
}

private final class ChatExportArguments {
    let selectFormat: (YougramChatExportFormat) -> Void
    let pickFromDate: () -> Void
    let pickToDate: () -> Void
    let toggleIncludeMedia: (Bool) -> Void
    let togglePhotosOnly: (Bool) -> Void
    let pickMaxFileSize: () -> Void
    let pickMaxTotalSize: () -> Void
    let toggleFetchCloud: (Bool) -> Void
    let toggleIncludeService: (Bool) -> Void
    let toggleIncludeDeleted: (Bool) -> Void
    let startExport: () -> Void
    let cancelExport: () -> Void
    let shareLastExport: () -> Void

    init(
        selectFormat: @escaping (YougramChatExportFormat) -> Void,
        pickFromDate: @escaping () -> Void,
        pickToDate: @escaping () -> Void,
        toggleIncludeMedia: @escaping (Bool) -> Void,
        togglePhotosOnly: @escaping (Bool) -> Void,
        pickMaxFileSize: @escaping () -> Void,
        pickMaxTotalSize: @escaping () -> Void,
        toggleFetchCloud: @escaping (Bool) -> Void,
        toggleIncludeService: @escaping (Bool) -> Void,
        toggleIncludeDeleted: @escaping (Bool) -> Void,
        startExport: @escaping () -> Void,
        cancelExport: @escaping () -> Void,
        shareLastExport: @escaping () -> Void
    ) {
        self.selectFormat = selectFormat
        self.pickFromDate = pickFromDate
        self.pickToDate = pickToDate
        self.toggleIncludeMedia = toggleIncludeMedia
        self.togglePhotosOnly = togglePhotosOnly
        self.pickMaxFileSize = pickMaxFileSize
        self.pickMaxTotalSize = pickMaxTotalSize
        self.toggleFetchCloud = toggleFetchCloud
        self.toggleIncludeService = toggleIncludeService
        self.toggleIncludeDeleted = toggleIncludeDeleted
        self.startExport = startExport
        self.cancelExport = cancelExport
        self.shareLastExport = shareLastExport
    }
}

private final class ChatExportStagingManager {
    private let lock = NSLock()
    private var trackedDirs: Set<URL> = []
    private var activeShareURLs: Set<URL> = []
    private var isControllerDisposed = false

    func track(_ stagingDir: URL) {
        self.lock.lock()
        defer { self.lock.unlock() }
        for existing in self.trackedDirs where existing != stagingDir {
            if !self.activeShareURLs.contains(existing) {
                try? FileManager.default.removeItem(at: existing)
                self.trackedDirs.remove(existing)
            }
        }
        self.trackedDirs.insert(stagingDir)
    }

    func beginShare(_ stagingDir: URL) {
        self.lock.lock()
        self.activeShareURLs.insert(stagingDir)
        self.trackedDirs.insert(stagingDir)
        self.lock.unlock()
    }

    func endShare(_ stagingDir: URL) {
        self.lock.lock()
        self.activeShareURLs.remove(stagingDir)
        let shouldCleanAll = self.isControllerDisposed
        let dirs = self.trackedDirs
        if shouldCleanAll {
            self.trackedDirs.removeAll()
        }
        self.lock.unlock()

        if shouldCleanAll {
            for dir in dirs {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    func controllerDisposed() {
        self.lock.lock()
        self.isControllerDisposed = true
        var toRemove: [URL] = []
        for dir in self.trackedDirs where !self.activeShareURLs.contains(dir) {
            toRemove.append(dir)
            self.trackedDirs.remove(dir)
        }
        self.lock.unlock()

        for dir in toRemove {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

private func formatSizeLabel(_ bytes: Int64?) -> String {
    guard let bytes else {
        return "Unlimited"
    }
    let mb = Double(bytes) / (1024.0 * 1024.0)
    if mb >= 1024.0 {
        return String(format: "%.1f GB", mb / 1024.0)
    } else if abs(mb.rounded() - mb) < 0.05 {
        return "\(Int(mb.rounded())) MB"
    } else {
        return String(format: "%.1f MB", mb)
    }
}

private func formatByteDisplay(_ bytes: Int64) -> String {
    let kb: Double = 1024.0
    let mb: Double = kb * 1024.0
    let gb: Double = mb * 1024.0
    let value = Double(bytes)
    if value >= gb {
        return String(format: "%.2f GB", value / gb)
    } else if value >= mb {
        return String(format: "%.1f MB", value / mb)
    } else if value >= kb {
        return String(format: "%.1f KB", value / kb)
    } else {
        return "\(bytes) B"
    }
}

private func formatDateLabel(_ timestamp: Int32?, emptyText: String, formatter: DateFormatter) -> String {
    guard let timestamp else {
        return emptyText
    }
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
}

private func startOfDayTimestamp(_ date: Date) -> Int32 {
    let start = Calendar.current.startOfDay(for: date)
    return Int32(clamping: Int64(start.timeIntervalSince1970))
}

private func endOfDayTimestamp(_ date: Date) -> Int32 {
    let start = Calendar.current.startOfDay(for: date)
    if let end = Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: start) {
        return Int32(clamping: Int64(end.timeIntervalSince1970))
    }
    return Int32(clamping: Int64(start.timeIntervalSince1970) + 86399)
}

private func progressDescription(_ progress: YougramChatExportProgress?) -> String {
    guard let progress else {
        return "Preparing export…"
    }
    switch progress.phase {
    case .loadingLocal:
        return "Reading local chat messages…"
    case let .fetchingCloud(fetchedCount):
        return "Fetching cloud history (\(fetchedCount) fetched)…"
    case let .writing(processed, total):
        return "Writing messages (\(processed) / \(total))…"
    case .packaging:
        return "Packaging exported files…"
    }
}

private func resultSummaryText(_ result: YougramChatExportResult) -> String {
    var lines: [String] = []
    lines.append("Exported \(result.exportedMessageCount) messages (\(formatByteDisplay(result.totalBytes))).")
    if result.exportedMediaCount > 0 {
        lines.append("Included \(result.exportedMediaCount) media files (packaged as ZIP).")
    }
    if result.skippedMediaSizeLimitCount > 0 {
        lines.append("Skipped \(result.skippedMediaSizeLimitCount) files due to size limits.")
    }
    if result.skippedMediaNotCachedCount > 0 {
        lines.append("Skipped \(result.skippedMediaNotCachedCount) uncached media items.")
    }
    if result.truncatedByTotalSizeLimit {
        lines.append("Stopped early after reaching the total export size limit.")
    }
    if let warning = result.cloudFetchWarning {
        lines.append(warning)
    }
    return lines.joined(separator: "\n")
}

private func chatExportEntries(
    state: ChatExportScreenState,
    isSecretChat: Bool,
    dateFormatter: DateFormatter
) -> [ChatExportEntry] {
    var entries: [ChatExportEntry] = []
    var nextId: Int32 = 0
    func next() -> Int32 {
        defer { nextId += 1 }
        return nextId
    }

    let enabled = !state.isExporting
    let opts = state.options

    entries.append(.formatHeader(next(), "EXPORT FORMAT"))
    entries.append(.formatOption(next(), .html, "HTML (Interactive Web Page)", opts.format == .html))
    entries.append(.formatOption(next(), .json, "JSON (Structured Data)", opts.format == .json))
    entries.append(.formatOption(next(), .txt, "Plain Text", opts.format == .txt))

    entries.append(.dateHeader(next(), "DATE RANGE"))
    entries.append(.fromDateRow(next(), formatDateLabel(opts.fromDate, emptyText: "Beginning", formatter: dateFormatter), enabled))
    entries.append(.toDateRow(next(), formatDateLabel(opts.toDate, emptyText: "Present", formatter: dateFormatter), enabled))
    entries.append(.dateInfo(next(), "Filter exported messages by local calendar date."))

    entries.append(.mediaHeader(next(), "MEDIA & SIZE LIMITS"))
    entries.append(.includeMediaToggle(next(), opts.includeCachedMedia, enabled))
    if opts.includeCachedMedia {
        entries.append(.photosOnlyToggle(next(), opts.photosOnly, enabled))
        entries.append(.maxFileSizeRow(next(), formatSizeLabel(opts.maxSingleFileSizeBytes), enabled))
    }
    entries.append(.maxTotalSizeRow(next(), formatSizeLabel(opts.maxTotalExportSizeBytes), enabled))

    entries.append(.advancedHeader(next(), "OPTIONS"))
    entries.append(.fetchCloudToggle(next(), opts.fetchCloudHistory, isSecretChat, enabled))
    entries.append(.includeServiceToggle(next(), opts.includeServiceMessages, enabled))
    entries.append(.includeDeletedToggle(next(), opts.includeYougramDeletedMessages, enabled))

    if state.isExporting {
        entries.append(.statusText(next(), progressDescription(state.progress)))
        entries.append(.cancelButton(next(), "Cancel Export"))
    } else {
        entries.append(.exportButton(next(), "Export Chat History"))
        if let result = state.lastResult {
            entries.append(.shareLastButton(next(), "Share Last Export (\(result.shareURL.lastPathComponent))"))
            entries.append(.statusText(next(), resultSummaryText(result)))
        } else if let errorMessage = state.errorMessage {
            entries.append(.statusText(next(), errorMessage))
        }
    }

    return entries
}

public func yougramChatExportController(
    context: AccountContext,
    peerId: EnginePeer.Id,
    peerTitle: String
) -> ViewController {
    let isSecretChat = peerId.namespace == Namespaces.Peer.SecretChat
    let initialState = ChatExportScreenState(
        options: YougramChatExportOptions(),
        isExporting: false,
        progress: nil,
        lastResult: nil,
        errorMessage: nil
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((ChatExportScreenState) -> ChatExportScreenState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.dateFormat = "yyyy-MM-dd"

    let exportDisposable = MetaDisposable()
    let stagingManager = ChatExportStagingManager()

    var presentControllerImpl: ((ViewController) -> Void)?
    var presentSystemControllerImpl: ((UIViewController) -> Void)?

    let showToast: (String) -> Void = { text in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(UndoOverlayController(
            presentationData: presentationData,
            content: .info(title: nil, text: text, timeout: nil, customUndoText: nil),
            elevatedLayout: false,
            action: { _ in return false }
        ))
    }

    let presentShareSheet: (YougramChatExportResult) -> Void = { result in
        stagingManager.beginShare(result.stagingDirectoryURL)
        let activityController = UIActivityViewController(activityItems: [result.shareURL], applicationActivities: nil)
        activityController.completionWithItemsHandler = { _, _, _, _ in
            stagingManager.endShare(result.stagingDirectoryURL)
        }
        presentSystemControllerImpl?(activityController)
    }

    let presentCustomDatePicker: (String, Date, @escaping (Date) -> Void) -> Void = { title, initialDate, completion in
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        let picker = UIDatePicker()
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.datePickerMode = .date
        if #available(iOS 13.4, *) {
            picker.preferredDatePickerStyle = .wheels
        }
        picker.maximumDate = Date()
        picker.date = initialDate
        alert.view.addSubview(picker)

        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: alert.view.leadingAnchor, constant: 8.0),
            picker.trailingAnchor.constraint(equalTo: alert.view.trailingAnchor, constant: -8.0),
            picker.topAnchor.constraint(equalTo: alert.view.topAnchor, constant: 48.0),
            picker.heightAnchor.constraint(equalToConstant: 180.0),
            alert.view.bottomAnchor.constraint(equalTo: picker.bottomAnchor, constant: 56.0)
        ])

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Apply", style: .default, handler: { _ in
            completion(picker.date)
        }))
        presentSystemControllerImpl?(alert)
    }

    let presentDateMenu: (Bool) -> Void = { isFrom in
        guard !stateValue.with({ $0.isExporting }) else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let sheet = ActionSheetController(presentationData: presentationData)
        let dismissAction: () -> Void = { [weak sheet] in
            sheet?.dismissAnimated()
        }

        let applyTimestamp: (Int32?) -> Void = { value in
            updateState { state in
                var state = state
                if isFrom {
                    state.options.fromDate = value
                    if let f = value, let t = state.options.toDate, f > t {
                        state.options.toDate = endOfDayTimestamp(Date(timeIntervalSince1970: TimeInterval(f)))
                    }
                } else {
                    state.options.toDate = value
                    if let t = value, let f = state.options.fromDate, t < f {
                        state.options.fromDate = startOfDayTimestamp(Date(timeIntervalSince1970: TimeInterval(t)))
                    }
                }
                return state
            }
        }

        var items: [ActionSheetItem] = [
            ActionSheetTextItem(title: isFrom ? "Export From Date" : "Export Until Date")
        ]

        if isFrom {
            let now = Date()
            let cal = Calendar.current
            items.append(ActionSheetButtonItem(title: "Beginning (No Limit)", color: .accent, action: {
                dismissAction()
                applyTimestamp(nil)
            }))
            items.append(ActionSheetButtonItem(title: "Last 7 Days", color: .accent, action: {
                dismissAction()
                if let date = cal.date(byAdding: .day, value: -7, to: now) {
                    applyTimestamp(startOfDayTimestamp(date))
                }
            }))
            items.append(ActionSheetButtonItem(title: "Last 30 Days", color: .accent, action: {
                dismissAction()
                if let date = cal.date(byAdding: .day, value: -30, to: now) {
                    applyTimestamp(startOfDayTimestamp(date))
                }
            }))
            items.append(ActionSheetButtonItem(title: "Last 3 Months", color: .accent, action: {
                dismissAction()
                if let date = cal.date(byAdding: .month, value: -3, to: now) {
                    applyTimestamp(startOfDayTimestamp(date))
                }
            }))
            items.append(ActionSheetButtonItem(title: "Last Year", color: .accent, action: {
                dismissAction()
                if let date = cal.date(byAdding: .year, value: -1, to: now) {
                    applyTimestamp(startOfDayTimestamp(date))
                }
            }))
        } else {
            let now = Date()
            let cal = Calendar.current
            items.append(ActionSheetButtonItem(title: "Present (No Limit)", color: .accent, action: {
                dismissAction()
                applyTimestamp(nil)
            }))
            items.append(ActionSheetButtonItem(title: "End of Today", color: .accent, action: {
                dismissAction()
                applyTimestamp(endOfDayTimestamp(now))
            }))
            items.append(ActionSheetButtonItem(title: "End of Yesterday", color: .accent, action: {
                dismissAction()
                if let yesterday = cal.date(byAdding: .day, value: -1, to: now) {
                    applyTimestamp(endOfDayTimestamp(yesterday))
                }
            }))
        }

        items.append(ActionSheetButtonItem(title: "Custom Date…", color: .accent, action: {
            dismissAction()
            let currentTimestamp = isFrom ? stateValue.with({ $0.options.fromDate }) : stateValue.with({ $0.options.toDate })
            let initialDate = currentTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
            presentCustomDatePicker(isFrom ? "From Date" : "To Date", initialDate) { chosen in
                applyTimestamp(isFrom ? startOfDayTimestamp(chosen) : endOfDayTimestamp(chosen))
            }
        }))

        sheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: {
                    dismissAction()
                })
            ])
        ])
        presentControllerImpl?(sheet)
    }

    let presentSizeMenu: (Bool) -> Void = { isSingleFileLimit in
        guard !stateValue.with({ $0.isExporting }) else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let sheet = ActionSheetController(presentationData: presentationData)
        let dismissAction: () -> Void = { [weak sheet] in
            sheet?.dismissAnimated()
        }

        let presetsMB: [Int64?] = isSingleFileLimit
            ? [nil, 1, 5, 10, 25, 50, 100]
            : [nil, 10, 25, 50, 100, 250, 500]

        var items: [ActionSheetItem] = [
            ActionSheetTextItem(title: isSingleFileLimit ? "Max Single Media File Size" : "Max Total Export Size")
        ]

        for mb in presetsMB {
            let bytes = mb.map { $0 * 1024 * 1024 }
            items.append(ActionSheetButtonItem(title: formatSizeLabel(bytes), color: .accent, action: {
                dismissAction()
                updateState { state in
                    var state = state
                    if isSingleFileLimit {
                        state.options.maxSingleFileSizeBytes = bytes
                    } else {
                        state.options.maxTotalExportSizeBytes = bytes
                    }
                    return state
                }
            }))
        }

        sheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: {
                    dismissAction()
                })
            ])
        ])
        presentControllerImpl?(sheet)
    }

    let arguments = ChatExportArguments(
        selectFormat: { format in
            guard !stateValue.with({ $0.isExporting }) else {
                return
            }
            updateState { state in
                var state = state
                state.options.format = format
                return state
            }
        },
        pickFromDate: {
            presentDateMenu(true)
        },
        pickToDate: {
            presentDateMenu(false)
        },
        toggleIncludeMedia: { value in
            updateState { state in
                var state = state
                state.options.includeCachedMedia = value
                return state
            }
        },
        togglePhotosOnly: { value in
            updateState { state in
                var state = state
                state.options.photosOnly = value
                return state
            }
        },
        pickMaxFileSize: {
            presentSizeMenu(true)
        },
        pickMaxTotalSize: {
            presentSizeMenu(false)
        },
        toggleFetchCloud: { value in
            updateState { state in
                var state = state
                state.options.fetchCloudHistory = value
                return state
            }
        },
        toggleIncludeService: { value in
            updateState { state in
                var state = state
                state.options.includeServiceMessages = value
                return state
            }
        },
        toggleIncludeDeleted: { value in
            updateState { state in
                var state = state
                state.options.includeYougramDeletedMessages = value
                return state
            }
        },
        startExport: {
            let current = stateValue.with { $0 }
            guard !current.isExporting else {
                return
            }
            var options = current.options
            if isSecretChat {
                options.fetchCloudHistory = false
            }

            updateState { state in
                var state = state
                state.isExporting = true
                state.progress = YougramChatExportProgress(phase: .loadingLocal)
                state.errorMessage = nil
                return state
            }

            exportDisposable.set(
                (context.engine.messages.yougramExportChat(
                    peerId: peerId,
                    fallbackTitle: peerTitle,
                    options: options
                )
                |> deliverOnMainQueue).start(
                    next: { event in
                        switch event {
                        case let .progress(progress):
                            updateState { state in
                                var state = state
                                state.progress = progress
                                return state
                            }
                        case let .completed(result):
                            stagingManager.track(result.stagingDirectoryURL)
                            updateState { state in
                                var state = state
                                state.isExporting = false
                                state.progress = nil
                                state.lastResult = result
                                state.errorMessage = nil
                                return state
                            }
                            presentShareSheet(result)
                        }
                    },
                    error: { error in
                        let message: String
                        switch error {
                        case .chatNotFound:
                            message = "Could not load this chat."
                        case .noMessagesMatched:
                            message = "No messages matched the selected filters."
                        case .writeFailed:
                            message = "Failed to write export files."
                        case .cancelled:
                            message = "Export cancelled."
                        }
                        updateState { state in
                            var state = state
                            state.isExporting = false
                            state.progress = nil
                            state.errorMessage = message
                            return state
                        }
                        showToast(message)
                    }
                )
            )
        },
        cancelExport: {
            exportDisposable.set(nil)
            updateState { state in
                var state = state
                state.isExporting = false
                state.progress = nil
                state.errorMessage = "Export cancelled."
                return state
            }
        },
        shareLastExport: {
            if let result = stateValue.with({ $0.lastResult }) {
                presentShareSheet(result)
            }
        }
    )

    let titleText = peerTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let navTitle = titleText.isEmpty ? "Export Chat" : "Export • \(titleText)"

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(navTitle),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: chatExportEntries(state: state, isSecretChat: isSecretChat, dateFormatter: dateFormatter),
            style: .blocks
        )
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        exportDisposable.dispose()
        stagingManager.controllerDisposed()
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    presentSystemControllerImpl = { [weak controller] systemVC in
        guard let controller else {
            return
        }
        if let popover = systemVC.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(
                x: controller.view.bounds.midX,
                y: max(40.0, controller.view.bounds.maxY - 80.0),
                width: 1.0,
                height: 1.0
            )
            popover.permittedArrowDirections = []
        }
        controller.present(systemVC, animated: true, completion: nil)
    }
    return controller
}
