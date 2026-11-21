import UIKit
import Foundation
import LocalAuthentication
import PasscodeCore
import TelegramCore
import AppLock
import WalletContext

public final class YougramMigrationProgressController: UIViewController {
    private let encrypting: Bool
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let percentLabel = UILabel()

    public init(encrypting: Bool) {
        self.encrypting = encrypting
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
        if #available(iOS 13.0, *) {
            self.isModalInPresentation = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 13.0, *) {
            self.view.backgroundColor = .systemBackground
        } else {
            self.view.backgroundColor = .white
        }

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16.0
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(stack)

        if #available(iOS 13.0, *) {
            let config = UIImage.SymbolConfiguration(pointSize: 52.0, weight: .regular)
            self.iconView.image = UIImage(systemName: self.encrypting ? "lock.shield.fill" : "lock.open.fill", withConfiguration: config)
            self.iconView.tintColor = .systemBlue
        }
        stack.addArrangedSubview(self.iconView)

        self.titleLabel.text = self.encrypting ? "Encrypting Local Data" : "Decrypting Local Data"
        self.titleLabel.font = UIFont.systemFont(ofSize: 22.0, weight: .semibold)
        self.titleLabel.textAlignment = .center
        self.titleLabel.numberOfLines = 0
        stack.addArrangedSubview(self.titleLabel)

        self.subtitleLabel.text = self.encrypting
            ? "Encrypting databases, cached keys, and media at rest.\nPlease keep Yougram open until complete."
            : "Decrypting local databases and media back to standard storage.\nPlease keep Yougram open until complete."
        self.subtitleLabel.font = UIFont.systemFont(ofSize: 15.0)
        if #available(iOS 13.0, *) {
            self.subtitleLabel.textColor = .secondaryLabel
        } else {
            self.subtitleLabel.textColor = .gray
        }
        self.subtitleLabel.textAlignment = .center
        self.subtitleLabel.numberOfLines = 0
        stack.addArrangedSubview(self.subtitleLabel)

        self.progressView.progress = 0.0
        self.progressView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(self.progressView)
        NSLayoutConstraint.activate([
            self.progressView.widthAnchor.constraint(equalToConstant: 240.0)
        ])

        self.percentLabel.text = "0%"
        self.percentLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 14.0, weight: .medium)
        if #available(iOS 13.0, *) {
            self.percentLabel.textColor = .secondaryLabel
        } else {
            self.percentLabel.textColor = .gray
        }
        stack.addArrangedSubview(self.percentLabel)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: self.view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 32.0),
            stack.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -32.0)
        ])
    }

    public func updateProgress(_ value: Float) {
        let clamped = max(0.0, min(1.0, value))
        self.progressView.setProgress(clamped, animated: true)
        self.percentLabel.text = "\(Int(round(clamped * 100.0)))%"
    }
}

public final class YougramVaultUnlockController: UIViewController, UITextFieldDelegate {
    private enum EntryKind {
        case digits(Int)
        case password
    }

    private let rootPath: String
    private let appGroupPath: String?
    private let manifest: YougramVaultManifest
    private let onUnlocked: (Data) -> Void
    private let onWipedAndReset: () -> Void

    private var entryKind: EntryKind = .digits(6)
    private var passcodeMode: Bool = false
    private var biometricsEnabled: Bool = false
    private var scrambledKeypad: Bool = false
    private var enteredDigits: String = ""
    private var keypadOrder: [Int] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]
    private var hasPromptedBiometrics = false
    private var cooldownTimer: Timer?

    private let containerStack = UIStackView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let errorLabel = UILabel()

    private let dotsStack = UIStackView()
    private var dotViews: [UIView] = []
    private let keypadStack = UIStackView()

    private let passwordField = UITextField()
    private let unlockButton = UIButton(type: .system)
    private let biometricsButton = UIButton(type: .system)
    private let eraseButton = UIButton(type: .system)

    public init(
        rootPath: String,
        appGroupPath: String?,
        manifest: YougramVaultManifest,
        onUnlocked: @escaping (Data) -> Void,
        onWipedAndReset: @escaping () -> Void
    ) {
        self.rootPath = rootPath
        self.appGroupPath = appGroupPath
        self.manifest = manifest
        self.onUnlocked = onUnlocked
        self.onWipedAndReset = onWipedAndReset

        switch manifest.unlockMode {
        case let .dedicated(kind):
            self.passcodeMode = false
            self.biometricsEnabled = manifest.biometricsEnabled
            self.scrambledKeypad = manifest.scrambledKeypad
            switch kind {
            case .digits4:
                self.entryKind = .digits(4)
            case .digits6:
                self.entryKind = .digits(6)
            case .password:
                self.entryKind = .password
            }
        case .appPasscode:
            self.passcodeMode = true
            let kind = PasscodeCredentialStore.shared.currentPasscodeKind() ?? .digits6
            let protection = try? PasscodeCredentialStore.shared.protectionSettings()
            self.biometricsEnabled = protection?.biometricsEnabled ?? false
            self.scrambledKeypad = manifest.scrambledKeypad
            switch kind {
            case .digits4:
                self.entryKind = .digits(4)
            case .digits6:
                self.entryKind = .digits(6)
            case .alphanumeric:
                self.entryKind = .password
            }
        }

        if self.scrambledKeypad {
            self.keypadOrder = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].shuffled()
        }

        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.cooldownTimer?.invalidate()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 13.0, *) {
            self.view.backgroundColor = .systemBackground
        } else {
            self.view.backgroundColor = .white
        }
        self.setupUI()
        self.refreshCooldownState()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if case .password = self.entryKind, self.currentCooldownRemaining() == 0 {
            self.passwordField.becomeFirstResponder()
        }
        if !self.hasPromptedBiometrics && self.biometricsEnabled && self.currentCooldownRemaining() == 0 {
            self.hasPromptedBiometrics = true
            self.attemptBiometricUnlock()
        }
    }

    private func setupUI() {
        self.containerStack.axis = .vertical
        self.containerStack.alignment = .center
        self.containerStack.spacing = 14.0
        self.containerStack.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(self.containerStack)

        if #available(iOS 13.0, *) {
            let config = UIImage.SymbolConfiguration(pointSize: 42.0, weight: .regular)
            self.iconView.image = UIImage(systemName: "lock.fill", withConfiguration: config)
            self.iconView.tintColor = .systemBlue
        }
        self.containerStack.addArrangedSubview(self.iconView)

        self.titleLabel.text = "Yougram Locked"
        self.titleLabel.font = UIFont.systemFont(ofSize: 22.0, weight: .semibold)
        self.titleLabel.textAlignment = .center
        self.containerStack.addArrangedSubview(self.titleLabel)

        self.subtitleLabel.text = self.passcodeMode
            ? "Enter your App Passcode to decrypt local data"
            : "Enter your Local Encryption secret to unlock"
        self.subtitleLabel.font = UIFont.systemFont(ofSize: 15.0)
        if #available(iOS 13.0, *) {
            self.subtitleLabel.textColor = .secondaryLabel
        } else {
            self.subtitleLabel.textColor = .gray
        }
        self.subtitleLabel.textAlignment = .center
        self.subtitleLabel.numberOfLines = 0
        self.containerStack.addArrangedSubview(self.subtitleLabel)

        self.errorLabel.text = " "
        self.errorLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .medium)
        self.errorLabel.textColor = .systemRed
        self.errorLabel.textAlignment = .center
        self.errorLabel.numberOfLines = 0
        self.containerStack.addArrangedSubview(self.errorLabel)

        switch self.entryKind {
        case let .digits(count):
            self.setupPinUI(count: count)
        case .password:
            self.setupPasswordUI()
        }

        if self.biometricsEnabled {
            self.biometricsButton.setTitle("Unlock with Face ID / Touch ID", for: .normal)
            self.biometricsButton.titleLabel?.font = UIFont.systemFont(ofSize: 15.0, weight: .medium)
            self.biometricsButton.addTarget(self, action: #selector(self.biometricsTapped), for: .touchUpInside)
            self.containerStack.addArrangedSubview(self.biometricsButton)
        }

        self.eraseButton.setTitle("Erase All Data", for: .normal)
        self.eraseButton.setTitleColor(.systemRed, for: .normal)
        self.eraseButton.titleLabel?.font = UIFont.systemFont(ofSize: 14.0, weight: .regular)
        self.eraseButton.translatesAutoresizingMaskIntoConstraints = false
        self.eraseButton.addTarget(self, action: #selector(self.eraseTapped), for: .touchUpInside)
        self.view.addSubview(self.eraseButton)

        NSLayoutConstraint.activate([
            self.containerStack.centerYAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.centerYAnchor, constant: -16.0),
            self.containerStack.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 28.0),
            self.containerStack.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -28.0),
            self.eraseButton.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -16.0),
            self.eraseButton.centerXAnchor.constraint(equalTo: self.view.centerXAnchor)
        ])
    }

    private func setupPinUI(count: Int) {
        self.dotsStack.axis = .horizontal
        self.dotsStack.spacing = 16.0
        self.dotsStack.alignment = .center
        for _ in 0 ..< count {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.layer.cornerRadius = 7.0
            dot.layer.borderWidth = 1.5
            if #available(iOS 13.0, *) {
                dot.layer.borderColor = UIColor.label.cgColor
            } else {
                dot.layer.borderColor = UIColor.black.cgColor
            }
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 14.0),
                dot.heightAnchor.constraint(equalToConstant: 14.0)
            ])
            self.dotViews.append(dot)
            self.dotsStack.addArrangedSubview(dot)
        }
        self.containerStack.addArrangedSubview(self.dotsStack)

        self.keypadStack.axis = .vertical
        self.keypadStack.spacing = 12.0
        self.keypadStack.alignment = .center

        let rows: [[Int?]] = [
            [self.keypadOrder[0], self.keypadOrder[1], self.keypadOrder[2]],
            [self.keypadOrder[3], self.keypadOrder[4], self.keypadOrder[5]],
            [self.keypadOrder[6], self.keypadOrder[7], self.keypadOrder[8]],
            [nil, self.keypadOrder[9], -1]
        ]

        for row in rows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 20.0
            rowStack.alignment = .center
            for cell in row {
                if let digit = cell {
                    let button = UIButton(type: .system)
                    button.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        button.widthAnchor.constraint(equalToConstant: 72.0),
                        button.heightAnchor.constraint(equalToConstant: 72.0)
                    ])
                    if digit == -1 {
                        if #available(iOS 13.0, *) {
                            button.setImage(UIImage(systemName: "delete.left"), for: .normal)
                            button.tintColor = .label
                        } else {
                            button.setTitle("⌫", for: .normal)
                        }
                        button.tag = -1
                        button.addTarget(self, action: #selector(self.backspaceTapped), for: .touchUpInside)
                    } else {
                        button.setTitle("\(digit)", for: .normal)
                        button.titleLabel?.font = UIFont.systemFont(ofSize: 28.0, weight: .regular)
                        if #available(iOS 13.0, *) {
                            button.backgroundColor = .secondarySystemBackground
                            button.setTitleColor(.label, for: .normal)
                        } else {
                            button.backgroundColor = UIColor(white: 0.92, alpha: 1.0)
                            button.setTitleColor(.black, for: .normal)
                        }
                        button.layer.cornerRadius = 36.0
                        button.tag = digit
                        button.addTarget(self, action: #selector(self.digitTapped(_:)), for: .touchUpInside)
                    }
                    rowStack.addArrangedSubview(button)
                } else {
                    let spacer = UIView()
                    spacer.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        spacer.widthAnchor.constraint(equalToConstant: 72.0),
                        spacer.heightAnchor.constraint(equalToConstant: 72.0)
                    ])
                    rowStack.addArrangedSubview(spacer)
                }
            }
            self.keypadStack.addArrangedSubview(rowStack)
        }
        self.containerStack.addArrangedSubview(self.keypadStack)
    }

    private func setupPasswordUI() {
        self.passwordField.isSecureTextEntry = true
        self.passwordField.borderStyle = .roundedRect
        self.passwordField.placeholder = "Password"
        self.passwordField.autocorrectionType = .no
        self.passwordField.autocapitalizationType = .none
        self.passwordField.returnKeyType = .go
        self.passwordField.delegate = self
        self.passwordField.translatesAutoresizingMaskIntoConstraints = false

        let revealButton = UIButton(type: .system)
        if #available(iOS 13.0, *) {
            revealButton.setImage(UIImage(systemName: "eye"), for: .normal)
        } else {
            revealButton.setTitle("Show", for: .normal)
        }
        revealButton.frame = CGRect(x: 0.0, y: 0.0, width: 36.0, height: 32.0)
        revealButton.addTarget(self, action: #selector(self.togglePasswordVisibility(_:)), for: .touchUpInside)
        self.passwordField.rightView = revealButton
        self.passwordField.rightViewMode = .always

        self.containerStack.addArrangedSubview(self.passwordField)
        NSLayoutConstraint.activate([
            self.passwordField.widthAnchor.constraint(equalTo: self.containerStack.widthAnchor),
            self.passwordField.heightAnchor.constraint(equalToConstant: 44.0)
        ])

        self.unlockButton.setTitle("Unlock", for: .normal)
        self.unlockButton.titleLabel?.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        self.unlockButton.backgroundColor = .systemBlue
        self.unlockButton.setTitleColor(.white, for: .normal)
        self.unlockButton.layer.cornerRadius = 10.0
        self.unlockButton.translatesAutoresizingMaskIntoConstraints = false
        self.unlockButton.addTarget(self, action: #selector(self.unlockPasswordTapped), for: .touchUpInside)
        self.containerStack.addArrangedSubview(self.unlockButton)
        NSLayoutConstraint.activate([
            self.unlockButton.widthAnchor.constraint(equalTo: self.containerStack.widthAnchor),
            self.unlockButton.heightAnchor.constraint(equalToConstant: 46.0)
        ])
    }

    @objc private func togglePasswordVisibility(_ sender: UIButton) {
        let wasFirstResponder = self.passwordField.isFirstResponder
        let existingText = self.passwordField.text
        self.passwordField.isSecureTextEntry.toggle()
        if #available(iOS 13.0, *) {
            let iconName = self.passwordField.isSecureTextEntry ? "eye" : "eye.slash"
            sender.setImage(UIImage(systemName: iconName), for: .normal)
        }
        if wasFirstResponder {
            self.passwordField.text = nil
            self.passwordField.text = existingText
        }
    }

    @objc private func digitTapped(_ sender: UIButton) {
        guard self.currentCooldownRemaining() == 0 else {
            return
        }
        guard case let .digits(targetCount) = self.entryKind, self.enteredDigits.count < targetCount else {
            return
        }
        self.enteredDigits.append("\(sender.tag)")
        self.errorLabel.text = " "
        self.updateDots()
        if self.enteredDigits.count == targetCount {
            let code = self.enteredDigits
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.submitSecret(code)
            }
        }
    }

    @objc private func backspaceTapped() {
        guard !self.enteredDigits.isEmpty else {
            return
        }
        self.enteredDigits.removeLast()
        self.updateDots()
    }

    @objc private func unlockPasswordTapped() {
        self.submitSecret(self.passwordField.text ?? "")
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        self.submitSecret(textField.text ?? "")
        return true
    }

    private func updateDots() {
        for (idx, dot) in self.dotViews.enumerated() {
            if idx < self.enteredDigits.count {
                if #available(iOS 13.0, *) {
                    dot.backgroundColor = .label
                } else {
                    dot.backgroundColor = .black
                }
            } else {
                dot.backgroundColor = .clear
            }
        }
    }

    private func currentCooldownRemaining() -> Int {
        if self.passcodeMode {
            return (try? PasscodeCredentialStore.shared.cooldownRemaining()) ?? 0
        }
        return YougramVaultStore.shared.cooldownRemaining(rootPath: self.rootPath)
    }

    private func refreshCooldownState() {
        let remaining = self.currentCooldownRemaining()
        if remaining > 0 {
            self.errorLabel.text = "Too many attempts. Try again in \(remaining)s."
            self.setInputEnabled(false)
            self.cooldownTimer?.invalidate()
            self.cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                let left = self.currentCooldownRemaining()
                if left <= 0 {
                    self.cooldownTimer?.invalidate()
                    self.cooldownTimer = nil
                    self.errorLabel.text = " "
                    self.setInputEnabled(true)
                } else {
                    self.errorLabel.text = "Too many attempts. Try again in \(left)s."
                }
            }
        } else {
            self.setInputEnabled(true)
        }
    }

    private func setInputEnabled(_ enabled: Bool) {
        self.keypadStack.isUserInteractionEnabled = enabled
        self.keypadStack.alpha = enabled ? 1.0 : 0.45
        self.passwordField.isEnabled = enabled
        self.unlockButton.isEnabled = enabled
        self.unlockButton.alpha = enabled ? 1.0 : 0.45
    }

    private func submitSecret(_ secret: String) {
        guard !secret.isEmpty else {
            self.errorLabel.text = "Enter your password to unlock."
            return
        }
        if self.currentCooldownRemaining() > 0 {
            self.refreshCooldownState()
            return
        }

        self.setInputEnabled(false)
        let rootPath = self.rootPath
        let appGroupPath = self.appGroupPath
        let isPasscodeMode = self.passcodeMode

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if isPasscodeMode {
                if PasscodeCredentialStore.shared.matchesDuressCode(secret) {
                    YougramVaultStore.shared.cryptoShredAndWipeAllData(rootPath: rootPath, appGroupPath: appGroupPath)
                    try? resetWalletLocalSecrets()
                    DispatchQueue.main.async {
                        self?.onWipedAndReset()
                    }
                    return
                }
                do {
                    PasscodeSession.setApplicationAvailable(true)
                    let session = try PasscodeCredentialStore.shared.verify(secret, scope: .appUnlock)
                    let masterKey = try YougramVaultStore.shared.unlockWithAppPasscodeSession(session, rootPath: rootPath)
                    AppLockContextImpl.markUnlockedFromVault(rootPath: rootPath)
                    DispatchQueue.main.async {
                        self?.onUnlocked(masterKey)
                    }
                } catch let error as PasscodeError {
                    DispatchQueue.main.async {
                        self?.handleAuthFailure(message: error == .invalidCode ? "Incorrect passcode." : "Try again later.")
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.handleAuthFailure(message: "Unable to unlock vault.")
                    }
                }
            } else {
                do {
                    let masterKey = try YougramVaultStore.shared.unlockWithDedicatedSecret(secret, rootPath: rootPath)
                    DispatchQueue.main.async {
                        self?.onUnlocked(masterKey)
                    }
                } catch YougramVaultError.duressTriggered {
                    YougramVaultStore.shared.cryptoShredAndWipeAllData(rootPath: rootPath, appGroupPath: appGroupPath)
                    try? resetWalletLocalSecrets()
                    DispatchQueue.main.async {
                        self?.onWipedAndReset()
                    }
                } catch let YougramVaultError.cooldown(seconds) {
                    DispatchQueue.main.async {
                        self?.handleAuthFailure(message: "Too many attempts. Try again in \(seconds)s.")
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.handleAuthFailure(message: "Incorrect password or code.")
                    }
                }
            }
        }
    }

    private func handleAuthFailure(message: String) {
        self.enteredDigits = ""
        self.passwordField.text = ""
        self.updateDots()
        self.errorLabel.text = message
        self.shakeInputView()
        self.refreshCooldownState()
    }

    private func shakeInputView() {
        let target: UIView = self.dotsStack.superview != nil ? self.dotsStack : self.passwordField
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.duration = 0.35
        anim.values = [-12, 12, -9, 9, -5, 5, 0]
        target.layer.add(anim, forKey: "shake")
    }

    @objc private func biometricsTapped() {
        self.attemptBiometricUnlock()
    }

    private func attemptBiometricUnlock() {
        guard self.biometricsEnabled, self.currentCooldownRemaining() == 0 else {
            return
        }
        let rootPath = self.rootPath
        let isPasscodeMode = self.passcodeMode
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let masterKey: Data
                if isPasscodeMode {
                    PasscodeSession.setApplicationAvailable(true)
                    let context = LAContext()
                    context.localizedReason = "Unlock Yougram Local Encryption"
                    let session = try PasscodeCredentialStore.shared.authenticateBiometrics(
                        context: context,
                        scope: .resource(namespace: "yougram.vault")
                    )
                    masterKey = try YougramVaultStore.shared.unlockWithAppPasscodeSession(session, rootPath: rootPath)
                    AppLockContextImpl.markUnlockedFromVault(rootPath: rootPath)
                } else {
                    masterKey = try YougramVaultStore.shared.unlockWithBiometrics(
                        rootPath: rootPath,
                        localizedReason: "Unlock Yougram Local Encryption"
                    )
                }
                DispatchQueue.main.async {
                    self?.onUnlocked(masterKey)
                }
            } catch {
                // Keep manual password/code entry visible when biometrics fails or is cancelled.
            }
        }
    }

    @objc private func eraseTapped() {
        let first = UIAlertController(
            title: "Erase All Data?",
            message: "This will permanently destroy all encrypted messages, media, accounts, and local keys on this device. This cannot be undone.",
            preferredStyle: .alert
        )
        first.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        first.addAction(UIAlertAction(title: "Continue", style: .destructive, handler: { [weak self] _ in
            self?.confirmSecondErase()
        }))
        self.present(first, animated: true, completion: nil)
    }

    private func confirmSecondErase() {
        let second = UIAlertController(
            title: "Confirm Permanent Erasure",
            message: "All local Yougram data will be cryptographically shredded immediately.",
            preferredStyle: .alert
        )
        second.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        second.addAction(UIAlertAction(title: "Erase Everything", style: .destructive, handler: { [weak self] _ in
            guard let self else { return }
            YougramVaultStore.shared.cryptoShredAndWipeAllData(rootPath: self.rootPath, appGroupPath: self.appGroupPath)
            try? resetWalletLocalSecrets()
            self.onWipedAndReset()
        }))
        self.present(second, animated: true, completion: nil)
    }
}
