import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import Display
import AccountContext
import TelegramPresentationData
import OverlayStatusController
import PresentationDataUtils

/// The media of a message that "Save to Gallery" and "Save to Files" offer. Every surface that offers them (the
/// message menu, profile shared media) resolves a message through `messageSaveableMedia(message:)`, so they agree on
/// what is saved. Copy protection and secret media are not checked here: each surface keeps its own gate.
public struct MessageSaveableMedia {
    /// A photo or video the Photos library takes, or nil.
    public let gallery: AnyMediaReference?
    /// Whether `gallery` is a video (it is saved as a video asset, otherwise as a photo asset).
    public let galleryIsVideo: Bool
    /// The photo or file exported to the Files app, or nil.
    public let file: AnyMediaReference?
}

/// Image types `saveToCameraRoll` can hand to Photos as a photo asset.
private let photosCompatibleImageMimeTypes: Set<String> = [
    "image/jpeg",
    "image/jpg",
    "image/png",
    "image/heic",
    "image/heif",
    "image/gif",
    "image/webp"
]

/// Video types Photos takes for a file sent as a document (without a video attribute).
private let photosCompatibleVideoMimeTypes: Set<String> = [
    "video/mp4",
    "video/quicktime",
    "video/x-m4v"
]

private func isStickerLike(_ file: TelegramMediaFile) -> Bool {
    return file.isSticker || file.isAnimatedSticker || file.isVideoSticker || file.isCustomEmoji
}

/// Whether Photos takes `file`, and as which kind of asset.
private func galleryKind(file: TelegramMediaFile) -> (isSaveable: Bool, isVideo: Bool) {
    if isStickerLike(file) {
        return (false, false)
    }
    let mimeType = file.mimeType.lowercased()
    if file.isVideo {
        if mimeType == "video/webm" || mimeType == "video/x-matroska" {
            return (false, false)
        }
        return (true, true)
    }
    if photosCompatibleVideoMimeTypes.contains(mimeType) {
        return (true, true)
    }
    if photosCompatibleImageMimeTypes.contains(mimeType) {
        return (true, false)
    }
    return (false, false)
}

public func messageSaveableMedia(message: EngineRawMessage) -> MessageSaveableMedia {
    // Paid media is never saved.
    if message.paidContent != nil {
        return MessageSaveableMedia(gallery: nil, galleryIsVideo: false, file: nil)
    }
    let messageReference = MessageReference(message)
    for media in message.effectiveMedia {
        if let image = media as? TelegramMediaImage {
            guard let _ = largestImageRepresentation(image.representations) else {
                continue
            }
            let reference: AnyMediaReference = .message(message: messageReference, media: image)
            return MessageSaveableMedia(gallery: reference, galleryIsVideo: false, file: reference)
        } else if let file = media as? TelegramMediaFile {
            let reference: AnyMediaReference = .message(message: messageReference, media: file)
            let kind = galleryKind(file: file)
            return MessageSaveableMedia(gallery: kind.isSaveable ? reference : nil, galleryIsVideo: kind.isVideo, file: reference)
        } else if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content {
            // A link preview: its video when Photos takes it, otherwise its photo.
            if let file = content.file {
                let kind = galleryKind(file: file)
                if kind.isSaveable && kind.isVideo {
                    let reference: AnyMediaReference = .message(message: messageReference, media: file)
                    return MessageSaveableMedia(gallery: reference, galleryIsVideo: true, file: reference)
                }
            }
            if let image = content.image, let _ = largestImageRepresentation(image.representations) {
                let reference: AnyMediaReference = .message(message: messageReference, media: image)
                return MessageSaveableMedia(gallery: reference, galleryIsVideo: false, file: reference)
            }
            if let file = content.file {
                let reference: AnyMediaReference = .message(message: messageReference, media: file)
                let kind = galleryKind(file: file)
                return MessageSaveableMedia(gallery: kind.isSaveable ? reference : nil, galleryIsVideo: kind.isVideo, file: reference)
            }
        }
    }
    return MessageSaveableMedia(gallery: nil, galleryIsVideo: false, file: nil)
}

/// Fetches the media (if it is not local yet) while a cancellable loading overlay is shown, then calls `completion` on
/// the main queue with the complete data. The overlay appears only when fetching takes more than a moment. Disposing
/// the result, or cancelling the overlay, stops the fetch; the result can also be dropped, the operation keeps itself
/// alive until it ends.
///
/// A streamed video's original file (one with other qualities) is only saved once it is downloaded, as upstream's
/// gallery does; otherwise this shows "Please wait for the video to be fully downloaded." Only the gallery's quality
/// picker, which offers the original to Premium users as upstream does, passes `allowsStreamedVideoOriginal`.
public func fetchMediaDataInteractively(context: AccountContext, userLocation: MediaResourceUserLocation, mediaReference: AnyMediaReference, allowsStreamedVideoOriginal: Bool = false, present: @escaping (ViewController, Any?) -> Void, completion: @escaping (EngineMediaResource.ResourceData) -> Void) -> Disposable {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    if !allowsStreamedVideoOriginal, let file = mediaReference.media as? TelegramMediaFile, file.isVideo, !file.alternativeRepresentations.isEmpty {
        let disposable = MetaDisposable()
        disposable.set((context.engine.resources.status(resource: EngineMediaResource(file.resource))
        |> take(1)
        |> deliverOnMainQueue).startStandalone(next: { status in
            if case .Local = status {
                disposable.set(fetchMediaDataInteractively(context: context, userLocation: userLocation, mediaReference: mediaReference, allowsStreamedVideoOriginal: true, present: present, completion: completion))
            } else {
                present(textAlertController(context: context, title: nil, text: presentationData.strings.Gallery_WaitForVideoDownoad, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), nil)
            }
        }))
        return disposable
    }
    let disposable = MetaDisposable()

    let progressSignal = Signal<Never, NoError> { _ in
        let controller = OverlayStatusController(style: presentationData.theme.actionSheet.backgroundType == .light ? .light : .dark, type: .loading(cancelled: {
            disposable.dispose()
        }))
        present(controller, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
        return ActionDisposable { [weak controller] in
            Queue.mainQueue().async() {
                controller?.dismiss()
            }
        }
    }
    |> runOn(Queue.mainQueue())
    |> delay(0.15, queue: Queue.mainQueue())
    let progressDisposable = progressSignal.startStandalone()

    let signal = fetchMediaData(context: context, userLocation: userLocation, mediaReference: mediaReference)
    |> mapToSignal { state, _ -> Signal<EngineMediaResource.ResourceData, NoError> in
        if case let .data(data) = state, data.isComplete {
            return .single(data)
        } else {
            return .complete()
        }
    }
    |> take(1)
    |> afterDisposed {
        Queue.mainQueue().async {
            progressDisposable.dispose()
        }
    }

    disposable.set((signal
    |> deliverOnMainQueue).startStandalone(next: { data in
        progressDisposable.dispose()
        completion(data)
    }, completed: {
        progressDisposable.dispose()
    }))

    return disposable
}

/// "Save to Gallery" for media that may not be downloaded yet: fetches it with `fetchMediaDataInteractively`'s
/// overlay, then saves it with `saveToCameraRoll`. `completed` is called on the main queue once it is saved. Only pass
/// a photo, or a file Photos takes (`MessageSaveableMedia.gallery`).
public func saveToCameraRollInteractively(context: AccountContext, userLocation: MediaResourceUserLocation, mediaReference: AnyMediaReference, allowsStreamedVideoOriginal: Bool = false, present: @escaping (ViewController, Any?) -> Void, completed: @escaping () -> Void) -> Disposable {
    let saveDisposable = MetaDisposable()
    let fetchDisposable = fetchMediaDataInteractively(context: context, userLocation: userLocation, mediaReference: mediaReference, allowsStreamedVideoOriginal: allowsStreamedVideoOriginal, present: present, completion: { _ in
        saveDisposable.set((saveToCameraRoll(context: context, userLocation: userLocation, mediaReference: mediaReference)
        |> deliverOnMainQueue).startStandalone(completed: {
            completed()
        }))
    })
    return ActionDisposable {
        fetchDisposable.dispose()
        saveDisposable.dispose()
    }
}
