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
    func deleteAccount(erasingWebsiteData: Bool) async -> Bool
    func retrySync()
}

// MARK: - BrowserMobileSyncSession + BrowserMobileAccountSessionPresenting

extension BrowserMobileSyncSession: BrowserMobileAccountSessionPresenting {
    var changePublisher: AnyPublisher<Void, Never> { objectWillChange.eraseToAnyPublisher() }
}

// MARK: - BrowserMobileAccountField

/// A filled 50 pt text field with the grouped cell color.
final class BrowserMobileAccountField: UITextField {
    override init(frame: CGRect) {
        super.init(frame: frame)
        borderStyle = .none
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func textRect(forBounds bounds: CGRect) -> CGRect { bounds.insetBy(dx: 16, dy: 0) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { bounds.insetBy(dx: 16, dy: 0) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { bounds.insetBy(dx: 16, dy: 0) }
}

private extension UIFont {
    var bold: UIFont {
        fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? self
    }

    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont(descriptor: fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ]), size: 0)
    }
}

// MARK: - BrowserMobileAccountViewController

@MainActor final class BrowserMobileAccountViewController: UIViewController, UIAdaptivePresentationControllerDelegate,
    UITextFieldDelegate
{
    // MARK: Private

    private let session: any BrowserMobileAccountSessionPresenting
    private let serverField = BrowserMobileAccountField()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let orLabel = UILabel()
    private let errorLabel = UILabel()
    private let consentLabel = UILabel()
    private let serverButton = UIButton(type: .system)
    private lazy var signInButton = ASAuthorizationAppleIDButton(
        authorizationButtonType: .signIn,
        authorizationButtonStyle: traitCollection.userInterfaceStyle == .dark ? .white : .black,
    )
    private let providerButtons: [BrowserAccountProvider: UIButton] = [
        .google: UIButton(type: .system),
        .github: UIButton(type: .system),
    ]
    private let loadProvidersButton = UIButton(type: .system)
    private let emailField = BrowserMobileAccountField()
    private let sendCodeButton = UIButton(type: .system)
    private let codeSentLabel = UILabel()
    private let codeField = BrowserMobileAccountField()
    private let signInWithCodeButton = UIButton(type: .system)
    private let sendAgainButton = UIButton(type: .system)
    private let differentEmailButton = UIButton(type: .system)
    private let enableButton = UIButton(type: .system)
    private let pauseButton = UIButton(type: .system)
    private let resumeButton = UIButton(type: .system)
    private let signOutButton = UIButton(type: .system)
    private let deleteAccountButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let progress = UIActivityIndicatorView(style: .medium)
    private var observation: AnyCancellable?
    private var signInTask: Task<Void, Never>?
    private var signInAttempt: UUID?
    private var deleteTask: Task<Void, Never>?
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
        makeContent()
        observation = session.changePublisher.receive(on: RunLoop.main).sink { [weak self] in self?.render() }
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Pushed inside Settings, the back button closes it; shown on its own, Done does.
        let isPushed = navigationController.map { $0.viewControllers.first !== self } ?? false
        navigationItem.rightBarButtonItem = isPushed
            ? nil
            : UIBarButtonItem(
                title: Self.localized("Done"), style: .plain, target: self, action: #selector(doneTapped),
            )
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

    @objc private func doneTapped() { close() }

    private func makeContent() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
        ])
        // The mark, what this screen is for, and where things stand.
        let logo = UIImageView(image: UIImage(named: "HomeLogo"))
        logo.contentMode = .scaleAspectFit
        logo.heightAnchor.constraint(equalToConstant: 56).isActive = true
        stack.addArrangedSubview(logo)
        stack.setCustomSpacing(16, after: logo)
        titleLabel.font = .preferredFont(forTextStyle: .title2).bold
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityIdentifier = "account.title"
        stack.addArrangedSubview(titleLabel)
        stack.setCustomSpacing(6, after: titleLabel)
        for label in [statusLabel, consentLabel, errorLabel, orLabel] {
            label.numberOfLines = 0
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.textColor = .secondaryLabel
        }
        statusLabel.accessibilityIdentifier = "account.status"
        stack.addArrangedSubview(statusLabel)
        stack.setCustomSpacing(24, after: statusLabel)
        errorLabel.textColor = .systemRed
        errorLabel.accessibilityIdentifier = "account.error"
        stack.addArrangedSubview(errorLabel)
        stack.setCustomSpacing(16, after: errorLabel)
        signInButton.accessibilityIdentifier = "account.signIn"
        signInButton.cornerRadius = 12
        signInButton.heightAnchor.constraint(equalToConstant: 50).isActive = true
        signInButton.addTarget(self, action: #selector(signIn), for: .touchUpInside)
        stack.addArrangedSubview(signInButton)
        makeOtherSignInMethods(in: stack)
        stack.addArrangedSubview(progress)
        consentLabel.text = Self
            .localized(
                "Sync shares your Spaces, folders, and tab addresses with your other devices through this server.",
            )
        stack.addArrangedSubview(consentLabel)
        configure(enableButton, title: "Enable Sync", id: "account.enable", prominent: true) { [weak self] in
            self?.session.enableSync()
        }
        configure(pauseButton, title: "Pause Sync", id: "account.pause") { [weak self] in self?.session.pauseSync() }
        configure(resumeButton, title: "Resume Sync", id: "account.resume", prominent: true) { [weak self] in
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
        configure(deleteAccountButton, title: "Delete Account…", id: "account.delete", plain: true) { [weak self] in
            self?.confirmAccountDeletion()
        }
        deleteAccountButton.configuration?.baseForegroundColor = .systemRed
        for button in [enableButton, pauseButton, resumeButton, retryButton, signOutButton, cancelButton] {
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(deleteAccountButton)
        // People use the app's own server; only development builds pick another.
        #if DEBUG
            makeServerSection(in: stack)
        #endif
    }

    private func makeServerSection(in stack: UIStackView) {
        // Whatever shows above, the server keeps its distance.
        let gap = UIView()
        gap.heightAnchor.constraint(equalToConstant: 16).isActive = true
        stack.addArrangedSubview(gap)
        // The server is rarely changed, so it sits last.
        let serverTitle = UILabel()
        serverTitle.text = Self.localized("Sync Server").uppercased()
        serverTitle.font = .preferredFont(forTextStyle: .footnote)
        serverTitle.adjustsFontForContentSizeCategory = true
        serverTitle.textColor = .secondaryLabel
        let serverHeader = UIView()
        serverTitle.translatesAutoresizingMaskIntoConstraints = false
        serverHeader.addSubview(serverTitle)
        NSLayoutConstraint.activate([
            serverTitle.leadingAnchor.constraint(equalTo: serverHeader.leadingAnchor, constant: 16),
            serverTitle.trailingAnchor.constraint(equalTo: serverHeader.trailingAnchor),
            serverTitle.topAnchor.constraint(equalTo: serverHeader.topAnchor),
            serverTitle.bottomAnchor.constraint(equalTo: serverHeader.bottomAnchor),
        ])
        stack.addArrangedSubview(serverHeader)
        stack.setCustomSpacing(6, after: serverHeader)
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
        stack.addArrangedSubview(serverField)
        configure(serverButton, title: "Save Server", id: "account.saveServer", plain: true) { [weak self] in
            self?.configureServer()
        }
        stack.addArrangedSubview(serverButton)
    }

    /// The server's other sign-in methods: a button per web provider, then a
    /// code sent by email.
    private func makeOtherSignInMethods(in stack: UIStackView) {
        stack.setCustomSpacing(10, after: signInButton)
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
            applyBrand(provider, to: button)
            stack.addArrangedSubview(button)
        }
        configure(loadProvidersButton, title: "Show Sign-In Options", id: "account.loadProviders") { [weak self] in
            guard let session = self?.session else { return }
            Task { await session.loadProviders() }
        }
        stack.addArrangedSubview(loadProvidersButton)
        orLabel.text = Self.localized("or")
        stack.addArrangedSubview(orLabel)
        for (field, placeholder, id) in [
            (emailField, "Email", "account.email"),
            (codeField, "6-digit code", "account.code"),
        ] {
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.placeholder = Self.localized(placeholder)
            field.accessibilityLabel = field.placeholder
            field.accessibilityIdentifier = id
            field.delegate = self
        }
        emailField.keyboardType = .emailAddress
        emailField.textContentType = .emailAddress
        emailField.returnKeyType = .send
        codeField.keyboardType = .numberPad
        codeField.textContentType = .oneTimeCode
        codeField.returnKeyType = .done
        configure(sendCodeButton, title: "Email Me a Code", id: "account.sendCode", prominent: true) { [weak self] in
            self?.requestEmailCode()
        }
        codeSentLabel.numberOfLines = 0
        codeSentLabel.font = .preferredFont(forTextStyle: .body)
        codeSentLabel.adjustsFontForContentSizeCategory = true
        codeSentLabel.textColor = .secondaryLabel
        codeSentLabel.accessibilityIdentifier = "account.codeSent"
        configure(signInWithCodeButton, title: "Sign In", id: "account.signInWithCode", prominent: true) {
            [weak self] in
            self?.signInWithCode()
        }
        configure(sendAgainButton, title: "Send Again", id: "account.sendAgain", plain: true) { [weak self] in
            guard let self, let request = session.account.emailSignIn else { return }
            beginOwnedSignIn { session, window, attempt in
                await session.requestEmailCode(request.email, from: window, attemptID: attempt)
            }
        }
        configure(differentEmailButton, title: "Use a Different Email", id: "account.differentEmail", plain: true) {
            [weak self] in
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

    /// The provider's own mark and colors, next to Sign in with Apple: white
    /// buttons on a dark sheet; on a light one Google stays white with an
    /// edge and GitHub turns its dark gray.
    private func applyBrand(_ provider: BrowserAccountProvider, to button: UIButton) {
        guard var configuration = button.configuration else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        let gitHubGray = UIColor(red: 0x24 / 255, green: 0x29 / 255, blue: 0x2F / 255, alpha: 1)
        let background: UIColor
        let foreground: UIColor
        switch provider {
        case .github:
            background = dark ? .white : gitHubGray
            foreground = dark ? .black : .white
            configuration.image = UIImage(named: "GitHubLogo")?.withRenderingMode(.alwaysTemplate)
        default:
            background = .white
            foreground = UIColor(white: 0.12, alpha: 1)
            configuration.image = UIImage(named: "GoogleLogo")?.withRenderingMode(.alwaysOriginal)
            if !dark {
                configuration.background.strokeColor = UIColor(white: 0.75, alpha: 1)
                configuration.background.strokeWidth = 1
            }
        }
        configuration.baseBackgroundColor = background
        configuration.baseForegroundColor = foreground
        configuration.imagePadding = 10
        configuration.imagePlacement = .leading
        button.configuration = configuration
    }

    /// A full-width 50 pt button: a gray tile, the accent for the step that
    /// moves things forward, or plain text for side actions.
    private func configure(
        _ button: UIButton, title: String, id: String, prominent: Bool = false, plain: Bool = false,
        action: @escaping @MainActor () -> Void,
    ) {
        var configuration: UIButton.Configuration = plain ? .plain() : .filled()
        if !plain {
            configuration.baseBackgroundColor = prominent ? .systemBlue : .secondarySystemGroupedBackground
            configuration.baseForegroundColor = prominent ? .white : .label
            configuration.background.cornerRadius = 12
            configuration.cornerStyle = .fixed
        }
        configuration.title = Self.localized(title)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .body).withWeight(plain ? .regular : .semibold)
            return attributes
        }
        button.configuration = configuration
        button.accessibilityIdentifier = id
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: plain ? 40 : 50).isActive = true
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
        deleteAccountButton.isHidden = !account.isAuthenticated
        let isDeleting = account.isDeletingAccount || deleteTask != nil
        for button in [deleteAccountButton, signOutButton, enableButton, pauseButton, resumeButton, retryButton] {
            button.isEnabled = !isDeleting
        }
        if account.isSigningIn || isDeleting {
            progress.startAnimating()
        } else {
            progress.stopAnimating()
        }
        progress.isHidden = !account.isSigningIn && !isDeleting
        let error = localError ?? account.lastError ?? session.lastSyncError
        errorLabel.text = error
        errorLabel.isHidden = error == nil
        retryButton.isHidden = session.lastSyncError == nil || account.bindingState != .enabled
        titleLabel.text = account.isAuthenticated
            ? account.session?.userEmail ?? Self.localized("Signed in")
            : Self.localized("Sync your Spaces")
        if isDeleting {
            statusLabel.text = Self.localized("Deleting account…")
        } else if account.isSigningIn {
            statusLabel.text = Self.localized("Signing in…")
        } else if !account.isConfigured {
            statusLabel.text = Self.localized("Enter your sync server to sign in.")
        } else if !account.isAuthenticated {
            statusLabel.text = Self.localized("Sign in to keep your Spaces and tabs in step with OpenArc on your Mac.")
        } else {
            let status =
                switch account.bindingState {
                case .enabled: "Sync is enabled."
                case .paused: "Sync is paused. Your data stays on this device."
                case .needsConsent: "Choose whether to sync this profile."
                case .differentAccount: "This profile belongs to another account."
                case nil: "Signed in."
                }
            statusLabel.text = Self.localized(status)
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
        // "or" splits the one-tap sign-ins from the email code.
        orLabel.isHidden = !showsEmail || account.isAuthenticated
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

    /// What deletion removes and what stays. Website data goes only when the
    /// user picks the second button.
    private func confirmAccountDeletion() {
        guard deleteTask == nil, session.account.isAuthenticated, presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: Self.localized("Delete your OpenArc account?"),
            message: Self.localized(
                "This deletes your account from the sync server, with the Spaces, tabs and Boosts synced to it. Your other devices stop syncing. You can’t undo this.\n\nSpaces and tabs on this device stay here. So do cookies, site logins and other website data, unless you erase them too.",
            ),
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: Self.localized("Delete Account"), style: .destructive) { [weak self] _ in
            self?.deleteAccount(erasingWebsiteData: false)
        })
        alert.addAction(UIAlertAction(
            title: Self.localized("Delete Account and Website Data"), style: .destructive,
        ) { [weak self] _ in
            self?.deleteAccount(erasingWebsiteData: true)
        })
        alert.addAction(UIAlertAction(title: Self.localized("Cancel"), style: .cancel))
        alert.view.accessibilityIdentifier = "account.deleteConfirmation"
        present(alert, animated: true)
    }

    private func deleteAccount(erasingWebsiteData: Bool) {
        guard deleteTask == nil else { return }
        cancelOwnedSignIn()
        deleteTask = Task { [weak self, session] in
            let deleted = await session.deleteAccount(erasingWebsiteData: erasingWebsiteData)
            guard let self else { return }
            deleteTask = nil
            render()
            if deleted {
                showAccountDeleted()
            }
        }
        render()
    }

    private func showAccountDeleted() {
        guard view.window != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: Self.localized("Account deleted"),
            message: Self.localized("Spaces and tabs on this device stay here and no longer sync."),
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: Self.localized("OK"), style: .default))
        present(alert, animated: true)
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
