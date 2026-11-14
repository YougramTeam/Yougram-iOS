import Foundation
import UIKit
import AVFoundation
import UniformTypeIdentifiers
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import SaveToCameraRoll

private func sanitizedFileNameComponent(_ value: String) -> String? {
    let result = (value as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_")
    if result.isEmpty || result == "." || result == ".." {
        return nil
    }
    return result
}

/// Extensions the system does not know for the types Telegram sends.
private let knownFileExtensions: [String: String] = [
    "audio/ogg": "ogg",
    "audio/opus": "opus",
    "application/x-tgsticker": "tgs",
    "video/webm": "webm",
    "image/webp": "webp",
    "image/jpeg": "jpg"
]

private func fileExtension(mimeType: String) -> String? {
    let mimeType = mimeType.lowercased()
    if let value = knownFileExtensions[mimeType] {
        return value
    }
    if let value = UTType(mimeType: mimeType)?.preferredFilenameExtension, !value.isEmpty {
        return value
    }
    return nil
}

private func exportDateString(mediaReference: AnyMediaReference) -> String {
    var timestamp = Int32(Date().timeIntervalSince1970)
    if case let .message(message, _) = mediaReference, let value = message.timestamp, value != 0 {
        timestamp = value
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
}

/// "Performer – Title.ext" from the file's audio attribute, or from the audio's own metadata.
private func musicFileName(file: TelegramMediaFile, dataPath: String, fileExtension: String) -> String? {
    var title: String?
    var performer: String?
    for attribute in file.attributes {
        if case let .Audio(_, _, titleValue, performerValue, _) = attribute {
            if let titleValue, !titleValue.isEmpty {
                title = titleValue
            }
            if let performerValue, !performerValue.isEmpty {
                performer = performerValue
            }
        }
    }

    var nameComponents: [String] = []
    if let title {
        if let performer, let value = sanitizedFileNameComponent(performer) {
            nameComponents.append(value)
        }
        if let value = sanitizedFileNameComponent(title) {
            nameComponents.append(value)
        }
    } else {
        // AVFoundation reads the metadata of a path whose extension names the type.
        let metadataFile = EngineTempBox.shared.file(path: dataPath, fileName: "audio.\(fileExtension)")
        let audioAsset = AVURLAsset(url: URL(fileURLWithPath: metadataFile.path))
        var artist: String?
        var title: String?
        for data in audioAsset.commonMetadata {
            if data.commonKey == .commonKeyArtist {
                artist = data.stringValue
            }
            if data.commonKey == .commonKeyTitle {
                title = data.stringValue
            }
        }
        EngineTempBox.shared.dispose(metadataFile)

        if let artist, !artist.isEmpty, let value = sanitizedFileNameComponent(artist) {
            nameComponents.append(value)
        }
        if let title, !title.isEmpty, let value = sanitizedFileNameComponent(title) {
            nameComponents.append(value)
        }
    }
    if nameComponents.isEmpty {
        return nil
    }
    return "\(nameComponents.joined(separator: " – ")).\(fileExtension)"
}

/// The name a media is exported under: the document's own name (with an extension from its type when it has none),
/// music as "Performer – Title", anything unnamed as "<kind>_<date>.<extension>".
private func exportFileName(mediaReference: AnyMediaReference, dataPath: String) -> String {
    let dateString = exportDateString(mediaReference: mediaReference)
    if mediaReference.media is TelegramMediaImage {
        return "photo_\(dateString).jpg"
    }
    guard let file = mediaReference.media as? TelegramMediaFile else {
        return "file_\(dateString)"
    }

    var fileExtensionValue: String?
    if let fileName = file.fileName, let value = sanitizedFileNameComponent((fileName as NSString).pathExtension) {
        fileExtensionValue = value
    }
    if fileExtensionValue == nil {
        fileExtensionValue = fileExtension(mimeType: file.mimeType)
    }

    if file.isMusic {
        let musicExtension = fileExtensionValue ?? "mp3"
        if let value = musicFileName(file: file, dataPath: dataPath, fileExtension: musicExtension) {
            return value
        }
        if let fileName = file.fileName, let value = sanitizedFileNameComponent((fileName as NSString).deletingPathExtension) {
            return "\(value).\(musicExtension)"
        }
        return "audio_\(dateString).\(musicExtension)"
    }

    if let fileName = file.fileName, let value = sanitizedFileNameComponent(fileName) {
        if (value as NSString).pathExtension.isEmpty, let fileExtensionValue {
            return "\(value).\(fileExtensionValue)"
        }
        return value
    }

    let mimeType = file.mimeType.lowercased()
    let kind: String
    if file.isSticker || file.isAnimatedSticker || file.isVideoSticker || file.isCustomEmoji {
        kind = "sticker"
    } else if file.isInstantVideo {
        kind = "video_message"
    } else if file.isVoice {
        kind = "audio"
    } else if file.isAnimated {
        kind = "animation"
    } else if file.isVideo || mimeType.hasPrefix("video/") {
        kind = "video"
    } else if mimeType.hasPrefix("image/") {
        kind = "photo"
    } else if mimeType.hasPrefix("audio/") {
        kind = "audio"
    } else {
        kind = "file"
    }
    if let fileExtensionValue {
        return "\(kind)_\(dateString).\(fileExtensionValue)"
    } else {
        return "\(kind)_\(dateString)"
    }
}

/// "Save to Files": fetches the photo or file (with a cancellable loading overlay while it downloads) and offers it in
/// the system export picker, which remembers the last folder chosen. The app cannot expose a folder of its own (its
/// Documents folder holds internal data), so there is no fixed Downloads folder. Callers gate this exactly like their
/// other saving (copy protection, secret media); this function does not check.
/// A streamed video's original is exported only once downloaded, unless `allowsStreamedVideoOriginal` (see
/// `fetchMediaDataInteractively`).
public func exportMediaToFiles(context: AccountContext, userLocation: MediaResourceUserLocation, mediaReference: AnyMediaReference, allowsStreamedVideoOriginal: Bool = false, present: @escaping (ViewController, Any?) -> Void) -> Disposable {
    return fetchMediaDataInteractively(context: context, userLocation: userLocation, mediaReference: mediaReference, allowsStreamedVideoOriginal: allowsStreamedVideoOriginal, present: present, completion: { data in
        let fileName = exportFileName(mediaReference: mediaReference, dataPath: data.path)
        // A hard link under the export name; the temp box is emptied on the next launch.
        let tempFile = EngineTempBox.shared.file(path: data.path, fileName: fileName)
        if !FileManager.default.fileExists(atPath: tempFile.path) {
            let _ = try? FileManager.default.copyItem(atPath: data.path, toPath: tempFile.path)
        }
        guard FileManager.default.fileExists(atPath: tempFile.path) else {
            return
        }

        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let controller = legacyICloudFilePicker(theme: presentationData.theme, mode: .export, url: URL(fileURLWithPath: tempFile.path), documentTypes: [], forceDarkTheme: false, dismissed: {}, completion: { _ in
        })
        present(controller, nil)
    })
}
