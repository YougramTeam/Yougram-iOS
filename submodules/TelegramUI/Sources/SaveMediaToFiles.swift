import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import LegacyMediaPickerUI

/// The music player's "Save to Files". The export, music's "Performer – Title" naming included, is
/// `exportMediaToFiles` (LegacyMediaPickerUI), which every surface's "Save to Files" uses.
func saveMediaToFiles(context: AccountContext, fileReference: FileMediaReference, present: @escaping (ViewController, Any?) -> Void) -> Disposable {
    return exportMediaToFiles(context: context, userLocation: .other, mediaReference: fileReference.abstract, present: present)
}
