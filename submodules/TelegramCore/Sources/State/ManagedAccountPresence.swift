import Foundation
internal import TelegramApi
import Postbox
import SwiftSignalKit
import MtProtoKit

private typealias SignalKitTimer = SwiftSignalKit.Timer


private final class AccountPresenceManagerImpl {
    private let queue: Queue
    private let network: Network
    let isPerformingUpdate = ValuePromise<Bool>(false, ignoreRepeated: true)
    
    private var shouldKeepOnlinePresenceDisposable: Disposable?
    private let currentRequestDisposable = MetaDisposable()
    private var onlineTimer: SignalKitTimer?
    
    private var wasOnline: Bool = false
    /// Yougram: whether the last status sent was online, so Ghost Mode knows whether there is one to end.
    private var sentOnline: Bool = false
    /// Yougram: Ghost Mode's "Go Offline Automatically" has appeared online once since the app came to the front.
    private var didGoOfflineAutomatically: Bool = false
    private var ghostModeObserver: NSObjectProtocol?

    init(queue: Queue, shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network) {
        self.queue = queue
        self.network = network
        
        self.shouldKeepOnlinePresenceDisposable = (shouldKeepOnlinePresence
        |> distinctUntilChanged
        |> deliverOn(self.queue)).start(next: { [weak self] value in
            guard let `self` = self else {
                return
            }
            if self.wasOnline != value {
                self.wasOnline = value
                self.updatePresence(value)
            }
        })

        // Yougram: react immediately when Ghost Mode settings change while app is open.
        self.ghostModeObserver = NotificationCenter.default.addObserver(forName: YougramCoreOptions.ghostModeDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else {
                return
            }
            self.queue.async { [weak self] in
                guard let self else {
                    return
                }
                self.updatePresence(self.wasOnline)
            }
        }
    }
    
    deinit {
        assert(self.queue.isCurrent())
        self.shouldKeepOnlinePresenceDisposable?.dispose()
        self.currentRequestDisposable.dispose()
        self.onlineTimer?.invalidate()
        if let ghostModeObserver = self.ghostModeObserver {
            NotificationCenter.default.removeObserver(ghostModeObserver)
        }
    }
    
    private func updatePresence(_ isOnline: Bool) {
        let ghostMode = YougramCoreOptions.ghostMode
        let request: Signal<Api.Bool, MTRpcError>
        if isOnline {
            self.onlineTimer?.invalidate()
            let timer = SignalKitTimer(timeout: 30.0, repeat: false, completion: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.updatePresence(true)
            }, queue: self.queue)
            self.onlineTimer = timer
            timer.start()
            // Yougram: Ghost Mode. The timer keeps running either way, so a changed option takes effect immediately or within 30 s.
            if ghostMode.hideOnline {
                self.didGoOfflineAutomatically = false
                // No online status. One already sent is ended once; with none, nothing is sent, since an offline
                // status would also show the user as last seen just now.
                if !self.sentOnline {
                    return
                }
                self.sentOnline = false
                request = self.network.request(Api.functions.account.updateStatus(offline: .boolTrue))
            } else if ghostMode.autoOffline {
                // Online once, then offline at once: repeated every 30 s it would blink online.
                if self.didGoOfflineAutomatically {
                    return
                }
                self.didGoOfflineAutomatically = true
                if self.sentOnline {
                    self.sentOnline = false
                    request = self.network.request(Api.functions.account.updateStatus(offline: .boolTrue))
                } else {
                    self.sentOnline = false
                    request = self.network.request(Api.functions.account.updateStatus(offline: .boolFalse))
                    |> then(self.network.request(Api.functions.account.updateStatus(offline: .boolTrue)))
                }
            } else {
                self.didGoOfflineAutomatically = false
                self.sentOnline = true
                request = self.network.request(Api.functions.account.updateStatus(offline: .boolFalse))
            }
        } else {
            self.onlineTimer?.invalidate()
            self.onlineTimer = nil
            self.didGoOfflineAutomatically = false
            // Yougram: with Ghost Mode keeping the status offline there is nothing to end, and an offline status would
            // show the user as last seen just now.
            if (ghostMode.hideOnline || ghostMode.autoOffline) && !self.sentOnline {
                return
            }
            self.sentOnline = false
            request = self.network.request(Api.functions.account.updateStatus(offline: .boolTrue))
        }
        self.isPerformingUpdate.set(true)
        self.currentRequestDisposable.set((request
        |> `catch` { _ -> Signal<Api.Bool, NoError> in
            return .single(.boolFalse)
        }
        |> deliverOn(self.queue)).start(completed: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.isPerformingUpdate.set(false)
        }))
    }
}

final class AccountPresenceManager {
    private let queue = Queue()
    private let impl: QueueLocalObject<AccountPresenceManagerImpl>
    
    init(shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network) {
        let queue = self.queue
        self.impl = QueueLocalObject(queue: self.queue, generate: {
            return AccountPresenceManagerImpl(queue: queue, shouldKeepOnlinePresence: shouldKeepOnlinePresence, network: network)
        })
    }
    
    func isPerformingUpdate() -> Signal<Bool, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.isPerformingUpdate.get().start(next: { value in
                    subscriber.putNext(value)
                }))
            }
            return disposable
        }
    }
}
