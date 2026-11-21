import UIKit
import PasscodeCore
import UserNotifications
import UserNotificationsUI
import TelegramUI
import BuildConfig

@objc(NotificationViewController)
@available(iOSApplicationExtension 10.0, iOS 10.0, *)
class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var impl: NotificationViewControllerImpl?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        if self.impl == nil {
            let appBundleIdentifier = Bundle.main.bundleIdentifier!
            guard let lastDotRange = appBundleIdentifier.range(of: ".", options: [.backwards]) else {
                return
            }
            
            let baseAppBundleId = String(appBundleIdentifier[..<lastDotRange.lowerBound])
            
            let buildConfig = BuildConfig(baseAppBundleId: baseAppBundleId)
            
            let languagesCategory = "ios"
            
            let appGroupName = BuildConfig.resolvedAppGroupName(baseAppBundleId: baseAppBundleId) ?? "group.\(baseAppBundleId)"
            try? PasscodeEnvironment.shared.configure(PasscodeConfiguration(appGroupIdentifier: appGroupName, processRole: .appExtension))
            let appGroupUrl = BuildConfig.appContainerURL(baseAppBundleId: baseAppBundleId)
            
            let rootPath = appGroupUrl.path + "/telegram-data"
            
            let encryptionParameters: (Data, Data)
            switch resolveExtensionEncryptionKeyPair(rootPath: rootPath) {
            case .disabled:
                let deviceSpecificEncryptionParameters = BuildConfig.deviceSpecificEncryptionParameters(rootPath, baseAppBundleId: baseAppBundleId)
                encryptionParameters = (deviceSpecificEncryptionParameters.key, deviceSpecificEncryptionParameters.salt)
            case let .unlocked(key, salt):
                encryptionParameters = (key, salt)
            case .locked:
                let label = UILabel()
                label.text = "Locked"
                label.textAlignment = .center
                label.translatesAutoresizingMaskIntoConstraints = false
                self.view.addSubview(label)
                NSLayoutConstraint.activate([
                    label.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: self.view.centerYAnchor)
                ])
                return
            }
            
            let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
            
            self.impl = NotificationViewControllerImpl(initializationData: NotificationViewControllerInitializationData(appBundleId: baseAppBundleId, appBuildType: buildConfig.isAppStoreBuild ? .public : .internal, appGroupPath: appGroupUrl.path, apiId: buildConfig.apiId, apiHash: buildConfig.apiHash, languagesCategory: languagesCategory, encryptionParameters: encryptionParameters, appVersion: appVersion, bundleData: buildConfig.bundleData(withAppToken: nil, tokenType: nil, tokenEnvironment: nil, signatureDict: nil), useBetaFeatures: !buildConfig.isAppStoreBuild), setPreferredContentSize: { [weak self] size in
                self?.preferredContentSize = size
            })
        }
        
        self.impl?.viewDidLoad(view: self.view)
    }
    
    func didReceive(_ notification: UNNotification) {
        self.impl?.didReceive(notification, view: self.view)
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        
        self.impl?.viewWillTransition(to: size)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        purgeExtensionEphemeralCache()
    }

    deinit {
        purgeExtensionEphemeralCache()
    }
}
