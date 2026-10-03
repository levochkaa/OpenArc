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
    // MARK: Lifecycle

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
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.close() }
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

    func presentationControllerDidDismiss(_: UIPresentationController) { cancelOwnedSignIn() }

    func textFieldShouldReturn(_: UITextField) -> Bool {
        configureServer()
        return true
    }

    // MARK: Private

    private let session: any BrowserMobileAccountSessionPresenting
    private let serverField = UITextField()
    private let statusLabel = UILabel()
    private let errorLabel = UILabel()
    private let consentLabel = UILabel()
    private let serverButton = UIButton(type: .system)
    private let signInButton = ASAuthorizationAppleIDButton(
        authorizationButtonType: .signIn,
        authorizationButtonStyle: .black
    )
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

    private static func localized(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Mobile", comment: "Account and sync")
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
                "Sync shares your Spaces, folders, and tab addresses with your other devices through this server."
            )
        consentLabel.textColor = .secondaryLabel
        errorLabel.textColor = .systemRed
        errorLabel.accessibilityIdentifier = "account.error"
        signInButton.accessibilityIdentifier = "account.signIn"
        signInButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        signInButton.addTarget(self, action: #selector(signIn), for: .touchUpInside)
        stack.addArrangedSubview(signInButton)
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
        signInButton.isHidden = account.isAuthenticated
        signInButton.isEnabled = account.isConfigured && !account.isSigningIn
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
                .compactMap { $0 }
                .joined(separator: "\n")
        }
    }

    private func configureServer() {
        do {
            try session.configureServer(serverField.text ?? "")
            localError = nil
            serverField.resignFirstResponder()
        } catch { localError = error.localizedDescription }
        render()
    }

    @objc private func signIn() {
        guard signInTask == nil, !session.account.isSigningIn, let window = view.window else { return }
        localError = nil
        let attempt = UUID()
        signInAttempt = attempt
        signInTask = Task { [weak self, session] in
            await session.signIn(from: window, attemptID: attempt)
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
