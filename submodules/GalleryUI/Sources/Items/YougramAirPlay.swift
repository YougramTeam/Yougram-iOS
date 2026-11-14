import Foundation
import UIKit
import AVFoundation
import AVKit
import SwiftSignalKit
import Display
import AccountContext
import TelegramAudio

private var yougramAirPlaySessionKey: UInt8 = 0

/// Yougram: what the system player needs while it is on screen, the player and Telegram's audio session.
/// The player controller keeps it (an associated object), so it ends when the controller goes away.
private final class YougramAirPlaySession: NSObject, AVRoutePickerViewDelegate {
    let player: AVPlayer
    private var audioSessionDisposable: Disposable?

    init(audioSession: ManagedAudioSession, url: URL, startTimestamp: Double) {
        let player = AVPlayer(url: url)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        self.player = player

        super.init()

        if startTimestamp > 1.0 {
            player.seek(to: CMTime(seconds: startTimestamp, preferredTimescale: 600))
        }
        self.audioSessionDisposable = audioSession.push(audioSessionType: .play(mixWithOthers: false), activate: { [weak player] _ in
            Queue.mainQueue().async {
                player?.play()
            }
        }, deactivate: { [weak player] _ in
            Queue.mainQueue().async {
                player?.pause()
            }
            return .complete()
        })
    }

    deinit {
        self.player.pause()
        self.audioSessionDisposable?.dispose()
    }

    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        routePickerView.removeFromSuperview()
    }
}

/// Yougram: plays the downloaded video at `path` (with a file extension AVFoundation understands) in the system
/// player with external playback on, and opens the AirPlay route picker over it. The player's own AirPlay button
/// does the same if the picker cannot be opened.
func presentYougramAirPlayPlayer(context: AccountContext, path: String, startTimestamp: Double) {
    guard let window = context.sharedContext.mainWindow else {
        return
    }
    let session = YougramAirPlaySession(audioSession: context.sharedContext.mediaManager.audioSession, url: URL(fileURLWithPath: path), startTimestamp: startTimestamp)

    let controller = AVPlayerViewController()
    controller.player = session.player
    controller.modalPresentationStyle = .fullScreen
    controller.overrideUserInterfaceStyle = .dark
    objc_setAssociatedObject(controller, &yougramAirPlaySessionKey, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    window.presentNative(controller)

    // AVRoutePickerView has no public call to show its routes; activating its button is what a tap does.
    Queue.mainQueue().after(0.6, { [weak controller, weak session] in
        guard let controller, let session, controller.viewIfLoaded?.window != nil else {
            return
        }
        let routePickerView = AVRoutePickerView(frame: CGRect(origin: CGPoint(), size: CGSize(width: 1.0, height: 1.0)))
        routePickerView.delegate = session
        routePickerView.prioritizesVideoDevices = true
        controller.view.addSubview(routePickerView)
        if let button = routePickerView.subviews.first(where: { $0 is UIButton }) as? UIButton {
            button.sendActions(for: .touchUpInside)
        } else {
            routePickerView.removeFromSuperview()
        }
    })
}
