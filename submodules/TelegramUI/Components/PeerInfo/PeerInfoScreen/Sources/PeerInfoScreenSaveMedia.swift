import Foundation
import UIKit
import Display
import AccountContext
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AppBundle
import ContextUI
import UndoUI
import SaveToCameraRoll
import LegacyMediaPickerUI

extension PeerInfoScreenNode {
    /// "Save to Gallery" (photos and videos) and "Save to Files" (any file, and photos) for the shared-media context
    /// menus, resolved like the message menu's (`messageSaveableMedia`). The caller applies the gate: not copy
    /// protected (`message.isCopyProtected() || peerInfoIsCopyProtected(...)`, as for Forward) and no secret media.
    func sharedMediaSaveContextMenuItems(message: EngineRawMessage) -> [ContextMenuItem] {
        let saveableMedia = messageSaveableMedia(message: message)
        let strings = self.presentationData.strings
        let peerId = message.id.peerId

        var items: [ContextMenuItem] = []
        if let mediaReference = saveableMedia.gallery {
            let isVideo = saveableMedia.galleryIsVideo
            items.append(.action(ContextMenuActionItem(text: isVideo ? strings.Gallery_SaveVideo : strings.Gallery_SaveImage, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Download"), color: theme.contextMenu.primaryColor) }, action: { [weak self] c, _ in
                c?.dismiss(completion: {
                    self?.saveSharedMediaToCameraRoll(mediaReference: mediaReference, isVideo: isVideo, peerId: peerId)
                })
            })))
        }
        if let mediaReference = saveableMedia.file {
            items.append(.action(ContextMenuActionItem(text: strings.Conversation_SaveToFiles, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Save"), color: theme.contextMenu.primaryColor) }, action: { [weak self] c, _ in
                c?.dismiss(completion: {
                    self?.exportSharedMediaToFiles(mediaReference: mediaReference, peerId: peerId)
                })
            })))
        }
        return items
    }

    private func saveSharedMediaToCameraRoll(mediaReference: AnyMediaReference, isVideo: Bool, peerId: EnginePeer.Id) {
        let context = self.context
        let _ = saveToCameraRollInteractively(context: context, userLocation: .peer(peerId), mediaReference: mediaReference, present: { [weak self] c, a in
            self?.controller?.present(c, in: .window(.root), with: a)
        }, completed: { [weak self] in
            guard let self else {
                return
            }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            self.controller?.present(UndoOverlayController(presentationData: presentationData, content: .mediaSaved(text: isVideo ? presentationData.strings.Gallery_VideoSaved : presentationData.strings.Gallery_ImageSaved), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return true }), in: .current)
        })
    }

    private func exportSharedMediaToFiles(mediaReference: AnyMediaReference, peerId: EnginePeer.Id) {
        let _ = exportMediaToFiles(context: self.context, userLocation: .peer(peerId), mediaReference: mediaReference, present: { [weak self] c, a in
            self?.controller?.present(c, in: .window(.root), with: a)
        })
    }
}
