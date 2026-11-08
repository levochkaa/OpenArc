// BrowserMobileAccountViewController.swift

import AuthenticationServices
import Combine
import UIKit

// MARK: - BrowserMobileAccountSessionPresenting

@MainActor protocol BrowserMobileAccountSessionPresenting: AnyObject {
    var account: BrowserAccountStore { get }
    var serverURL: URL? { get }
    var lastSyncError: String? { get }
    var changePublisher: AnyPublisher<Void, Never> { get }
    func configureServer(_ raw: String) throws
    func signIn(from window: UIWindow, attemptID: UUID) async
    func signIn(with provider: BrowserAccountProvider, from window: UIWindow, attemptID: UUID) async
    func requestEmailCode(_ email: String, from window: UIWindow, attemptID: UUID) async
    func signIn(email: String, code: String, from window: UIWindow, attemptID: UUID) async
    func loadProviders() async
    func cancelEmailSignIn()
    func cancelSignIn(attemptID: UUID)
    func enableSync()
    func pauseSync()
    func resumeSync()
    func signOut()
    func retrySync()
}

// MARK: - BrowserMobileSyncSession + BrowserMobileAccountSessionPresenting

extension BrowserMobileSyncSession: BrowserMobileAccountSessionPresenting {
    var changePublisher: AnyPublisher<Void, Never> { objectWillChange.eraseToAnyPublisher() }
}

// MARK: - BrowserMobileAccountViewController

@MainActor final class BrowserMobileAccountViewController: UIViewController, UIAdaptivePresentationControllerDelegate,
    UITextFieldDelegate
{
    // MARK: Private

    private let session: any BrowserMobileAccountSessionPresenting
    private let serverField = UITextField()
    private let statusLabel = UILabel()
    private let errorLabel = UILabel()
    private let consentLabel = UILabel()
    private let serverButton = UIButton(type: .system)
    private let signInButton = ASAuthorizationAppleIDButton(
        authorizationButtonType: .signIn,
        authorizationButtonStyle: .black,
    )
    private let providerButtons: [BrowserAccountProvider: UIButton] = [
        .google: UIButton(type: .system),
        .github: UIButton(type: .system),
    ]
    private let loadProvidersButton = UIButton(type: .system)
    private let emailField = UITextField()
    private let sendCodeButton = UIButton(type: .system)
    private let codeSentLabel = UILabel()
    private let codeField = UITextField()
    private let signInWithCodeButton = UIButton(type: .system)
    private let sendAgainButton = UIButton(type: .system)
    private let differentEmailButton = UIButton(type: .system)
    private let enableButton = UIButton(type: .system)
    private let pauseButton = UIButton(type: .system)
    private let resumeButton = UIButton(type: .system)
    private let signOutButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let progress = UIActivityIndicatorView(style: .medium)
    private var observation: AnyCancellable?
    private var signInTask: Task<Void, Never>?
    private var signInAttempt: UUID?
    private var localError: String?
    private var renderedServerURL: URL?
    /// The account whose sign-in methods this screen asked for; a new server
    /// brings a new account.
    private weak var providersAccount: BrowserAccountStore?
    private var isShowingCodeEntry = false

    init(session: any BrowserMobileAccountSessionPresenting) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        title = Self.localized("Account & Sync")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.close() },
        )
        makeContent()
        observation = session.changePublisher.receive(on: RunLoop.main).sink { [weak self] in self?.render() }
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        (navigationController?.presentationController ?? presentationController)?.delegate = self
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || view.window == nil {
            cancelOwnedSignIn()
        }
    }

    private static func localized(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Mobile", comment: "Account and sync")
    }

    func presentationControllerDidDismiss(_: UIPresentationController) { cancelOwnedSignIn() }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === emailField {
            requestEmailCode()
        } else if textField === codeField {
            signInWithCode()
        } else {
            configureServer()
        }
        return true
    }

    private func makeContent() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
        ])
        let serverTitle = UILabel()
        serverTitle.text = Self.localized("Sync Server")
        serverTitle.font = .preferredFont(forTextStyle: .headline)
        serverTitle.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(serverTitle)
        serverField.borderStyle = .roundedRect
        serverField.font = .preferredFont(forTextStyle: .body)
        serverField.adjustsFontForContentSizeCategory = true
        serverField.keyboardType = .URL
        serverField.autocapitalizationType = .none
        serverField.autocorrectionType = .no
        serverField.textContentType = .URL
        serverField.returnKeyType = .done
        serverField.placeholder = Self.localized("https://your-sync-server")
        serverField.accessibilityLabel = Self.localized("Sync Server")
        serverField.accessibilityIdentifier = "account.server"
        serverField.delegate = self
        serverField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        stack.addArrangedSubview(serverField)
        configure(serverButton, title: "Save Server", id: "account.saveServer") { [weak self] in
            self?.configureServer()
        }
        stack.addArrangedSubview(serverButton)
        for label in [statusLabel, consentLabel, errorLabel] {
            label.numberOfLines = 0
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(label)
        }
        statusLabel.accessibilityIdentifier = "account.status"
        consentLabel.text = Self
            .localized(
                "Sync shares your Spaces, folders, and tab addresses with your other devices through this server.",
            )
        consentLabel.textColor = .secondaryLabel
        errorLabel.textColor = .systemRed
        errorLabel.accessibilityIdentifier = "account.error"
        signInButton.accessibilityIdentifier = "account.signIn"
        signInButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        signInButton.addTarget(self, action: #selector(signIn), for: .touchUpInside)
        stack.addArrangedSubview(signInButton)
        makeOtherSignInMethods(in: stack)
        stack.addArrangedSubview(progress)
        configure(enableButton, title: "Enable Sync", id: "account.enable") { [weak self] in
            self?.session.enableSync()
        }
        configure(pauseButton, title: "Pause Sync", id: "account.pause") { [weak self] in self?.session.pauseSync() }
        configure(resumeButton, title: "Resume Sync", id: "account.resume") { [weak self] in
            self?.session.resumeSync()
        }
        configure(retryButton, title: "Retry Sync", id: "account.retry") { [weak self] in self?.session.retrySync() }
        configure(signOutButton, title: "Sign Out", id: "account.signOut") { [weak self] in
            self?.cancelOwnedSignIn()
            self?.session.signOut()
        }
        configure(cancelButton, title: "Cancel Sign-In", id: "account.cancelSignIn") { [weak self] in
            self?.cancelOwnedSignIn()
        }
        for button in [enableButton, pauseButton, resumeButton, retryButton, signOutButton, cancelButton] {
            stack.addArrangedSubview(button)
        }
    }

    /// The server's other sign-in methods: a button per web provider, then a
    /// code sent by email.
    private func makeOtherSignInMethods(in stack: UIStackView) {
        let titles: [(BrowserAccountProvider, String)] = [
            (.google, "Continue with Google"),
            (.github, "Continue with GitHub"),
        ]
        for (provider, title) in titles {
            guard let button = providerButtons[provider] else { continue }
            configure(button, title: title, id: "account.continue.\(provider.rawValue)") { [weak self] in
                self?.beginOwnedSignIn { session, window, attempt in
                    await session.signIn(with: provider, from: window, attemptID: attempt)
                }
            }
            stack.addArrangedSubview(button)
        }
        configure(loadProvidersButton, title: "Show Sign-In Options", id: "account.loadProviders") { [weak self] in
            guard let session = self?.session else { return }
            Task { await session.loadProviders() }
        }
        stack.addArrangedSubview(loadProvidersButton)
        for (field, placeholder, id) in [
            (emailField, "Email", "account.email"),
            (codeField, "6-digit code", "account.code"),
        ] {
            field.borderStyle = .roundedRect
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.placeholder = Self.localized(placeholder)
            field.accessibilityLabel = field.placeholder
            field.accessibilityIdentifier = id
            field.delegate = self
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        emailField.keyboardType = .emailAddress
        emailField.textContentType = .emailAddress
        emailField.returnKeyType = .send
        codeField.keyboardType = .numberPad
        codeField.textContentType = .oneTimeCode
        codeField.returnKeyType = .done
        configure(sendCodeButton, title: "Email Me a Code", id: "account.sendCode") { [weak self] in
            self?.requestEmailCode()
        }
        codeSentLabel.numberOfLines = 0
        codeSentLabel.font = .preferredFont(forTextStyle: .body)
        codeSentLabel.adjustsFontForContentSizeCategory = true
        codeSentLabel.textColor = .secondaryLabel
        codeSentLabel.accessibilityIdentifier = "account.codeSent"
        configure(signInWithCodeButton, title: "Sign In", id: "account.signInWithCode") { [weak self] in
            self?.signInWithCode()
        }
        configure(sendAgainButton, title: "Send Again", id: "account.sendAgain") { [weak self] in
            guard let self, let request = session.account.emailSignIn else { return }
            beginOwnedSignIn { session, window, attempt in
                await session.requestEmailCode(request.email, from: window, attemptID: attempt)
            }
        }
        configure(differentEmailButton, title: "Use a Different Email", id: "account.differentEmail") { [weak self] in
            self?.codeField.text = nil
            self?.session.cancelEmailSignIn()
        }
        let views: [UIView] = [
            emailField, sendCodeButton, codeSentLabel, codeField, signInWithCodeButton, sendAgainButton,
            differentEmailButton,
        ]
        for view in views {
            stack.addArrangedSubview(view)
        }
    }

    private func configure(_ button: UIButton, title: String, id: String, action: @escaping @MainActor () -> Void) {
        button.configuration = .bordered()
        button.configuration?.title = Self.localized(title)
        button.accessibilityIdentifier = id
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { [weak self] _ in
            self?.localError = nil
            action()
            self?.render()
        }, for: .touchUpInside)
    }

    private func render() {
        let account = session.account
        if renderedServerURL != session.serverURL {
            renderedServerURL = session.serverURL
            serverField.text = session.serverURL?.absoluteString
        }
        serverField.isEnabled = !account.isAuthenticated && !account.isSigningIn
        serverButton.isEnabled = serverField.isEnabled
        // Native Sign in with Apple works whether or not the server lists
        // its web flow among the providers.
        signInButton.isHidden = account.isAuthenticated
        signInButton.isEnabled = account.isConfigured && !account.isSigningIn
        renderOtherSignInMethods(account)
        enableButton.isHidden = !account.isAuthenticated || account.bindingState != .needsConsent
        consentLabel.isHidden = enableButton.isHidden
        pauseButton.isHidden = !account.isAuthenticated || account.bindingState != .enabled
        resumeButton.isHidden = !account.isAuthenticated || account.bindingState != .paused
        signOutButton.isHidden = !account.isAuthenticated
        cancelButton.isHidden = !account.isSigningIn || signInTask == nil
        if account.isSigningIn {
            progress.startAnimating()
        } else {
            progress.stopAnimating()
        }
        progress.isHidden = !account.isSigningIn
        let error = localError ?? account.lastError ?? session.lastSyncError
        errorLabel.text = error
        errorLabel.isHidden = error == nil
        retryButton.isHidden = session.lastSyncError == nil || account.bindingState != .enabled
        if account.isSigningIn {
            statusLabel.text = Self.localized("Signing in…")
        } else if !account.isConfigured {
            statusLabel.text = Self.localized("Enter your sync server to sign in.")
        } else if !account.isAuthenticated {
            statusLabel.text = Self.localized("Sign in to sync this profile.")
        } else {
            let status =
                switch account.bindingState {
                case .enabled: "Sync is enabled."
                case .paused: "Sync is paused. Your data stays on this device."
                case .needsConsent: "Choose whether to sync this profile."
                case .differentAccount: "This profile belongs to another account."
                case nil: "Signed in."
                }
            statusLabel.text = [account.session?.userEmail, Self.localized(status)]
                .compactMap(\.self)
                .joined(separator: "\n")
        }
    }

    private func renderOtherSignInMethods(_ account: BrowserAccountStore) {
        let offersSignIn = account.isConfigured && !account.isAuthenticated
        if offersSignIn, account.providers == nil, providersAccount !== account {
            providersAccount = account
            Task { [session] in await session.loadProviders() }
        }
        let providers = offersSignIn ? account.providers ?? [] : []
        let isEnabled = !account.isSigningIn
        for (provider, button) in providerButtons {
            button.isHidden = !providers.contains(provider)
            button.isEnabled = isEnabled
        }
        loadProvidersButton.isHidden = !offersSignIn || account.providers != nil || account.lastError == nil
        loadProvidersButton.isEnabled = isEnabled
        let request = providers.contains(.email) ? account.emailSignIn : nil
        let showsEmail = providers.contains(.email) && request == nil
        let showsCode = request != nil
        let emailViews: [UIView] = [emailField, sendCodeButton]
        for view in emailViews {
            view.isHidden = !showsEmail
        }
        let codeViews: [UIView] = [
            codeSentLabel,
            codeField,
            signInWithCodeButton,
            sendAgainButton,
            differentEmailButton,
        ]
        for view in codeViews {
            view.isHidden = !showsCode
        }
        emailField.isEnabled = isEnabled
        sendCodeButton.isEnabled = isEnabled
        codeField.isEnabled = isEnabled
        signInWithCodeButton.isEnabled = isEnabled
        sendAgainButton.isEnabled = isEnabled && account.canResendEmailCode
        differentEmailButton.isEnabled = isEnabled
        if let request {
            codeSentLabel.text = String(format: Self.localized("Enter the 6-digit code sent to %@."), request.email)
        }
        if showsCode, !isShowingCodeEntry {
            codeField.text = nil
            if view.window != nil {
                codeField.becomeFirstResponder()
            }
        }
        isShowingCodeEntry = showsCode
    }

    private func requestEmailCode() {
        guard session.account.emailSignIn == nil else { return }
        let email = emailField.text ?? ""
        beginOwnedSignIn { session, window, attempt in
            await session.requestEmailCode(email, from: window, attemptID: attempt)
        }
    }

    private func signInWithCode() {
        guard let request = session.account.emailSignIn else { return }
        let code = codeField.text ?? ""
        beginOwnedSignIn { session, window, attempt in
            await session.signIn(email: request.email, code: code, from: window, attemptID: attempt)
        }
    }

    private func configureServer() {
        do {
            try session.configureServer(serverField.text ?? "")
            localError = nil
            serverField.resignFirstResponder()
        } catch {
            localError = error.localizedDescription
        }
        render()
    }

    @objc private func signIn() {
        beginOwnedSignIn { session, window, attempt in
            await session.signIn(from: window, attemptID: attempt)
        }
    }

    /// Starts a sign-in this screen owns, so closing it cancels only that one.
    private func beginOwnedSignIn(
        _ body: @escaping @MainActor (any BrowserMobileAccountSessionPresenting, UIWindow, UUID) async -> Void,
    ) {
        guard signInTask == nil, !session.account.isSigningIn, let window = view.window else { return }
        localError = nil
        let attempt = UUID()
        signInAttempt = attempt
        signInTask = Task { [weak self, session] in
            await body(session, window, attempt)
            guard let self, signInAttempt == attempt else { return }
            signInAttempt = nil
            signInTask = nil
            render()
        }
        render()
    }

    private func cancelOwnedSignIn() {
        guard let task = signInTask, let attempt = signInAttempt else { return }
        signInAttempt = nil
        signInTask = nil
        session.cancelSignIn(attemptID: attempt)
        task.cancel()
        if isViewLoaded {
            render()
        }
    }

    private func close() {
        cancelOwnedSignIn()
        dismiss(animated: true)
    }
}
