//  KeePassium Password Manager
//  Copyright © 2018-2025 KeePassium Labs <info@keepassium.com>
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import KeePassiumLib

protocol DatabaseUnlockerCoordinatorDelegate: AnyObject {
    func shouldDismissFromKeyboard(_ coordinator: DatabaseUnlockerCoordinator) -> Bool

    func willUnlockDatabase(_ fileRef: URLReference, in coordinator: DatabaseUnlockerCoordinator)
    func didNotUnlockDatabase(
        _ fileRef: URLReference,
        with message: String?,
        reason: String?,
        in coordinator: DatabaseUnlockerCoordinator
    )

    func shouldChooseFallbackStrategy(
        for fileRef: URLReference,
        in coordinator: DatabaseUnlockerCoordinator
    ) -> UnreachableFileFallbackStrategy

    func didUnlockDatabase(
        databaseFile: DatabaseFile,
        at fileRef: URLReference,
        warnings: DatabaseLoadingWarnings,
        in coordinator: DatabaseUnlockerCoordinator
    )
    func didPressReinstateDatabase(_ fileRef: URLReference, in coordinator: DatabaseUnlockerCoordinator)
    func didPressAddRemoteDatabase(in coordinator: DatabaseUnlockerCoordinator)
}

final class DatabaseUnlockerCoordinator: BaseCoordinator {
    enum State {
        case unlockOriginalFileFast
        case unlockOriginalFileSlow
        case unlockFallbackFile
    }
    weak var delegate: DatabaseUnlockerCoordinatorDelegate?

    var reloadingContext: DatabaseReloadContext?

    private let databaseUnlockerVC: DatabaseUnlockerVC

    private var databaseRef: URLReference
    private var fallbackDatabaseRef: URLReference?
    private var selectedKeyFileRef: URLReference?
    private var selectedHardwareKey: HardwareKey?

    private var state: State = .unlockOriginalFileFast
    private var databaseLoader: DatabaseLoader?

    init(router: NavigationRouter, databaseRef: URLReference) {
        self.databaseRef = databaseRef
        self.fallbackDatabaseRef = DatabaseManager.getFallbackFile(for: databaseRef)
        databaseUnlockerVC = DatabaseUnlockerVC.instantiateFromStoryboard()
        super.init(router: router)

        databaseUnlockerVC.delegate = self
        databaseUnlockerVC.databaseRef = databaseRef
    }

    override func start() {
        super.start()
        _pushInitialViewController(databaseUnlockerVC, animated: true)
        setDatabase(databaseRef, andThen: .doNothing)
    }

    override func refresh() {
        super.refresh()
        databaseUnlockerVC.refresh()
    }

    func cancelLoading(reason: ProgressEx.CancellationReason) {
        databaseLoader?.cancel(reason: reason)
    }

    func setDatabase(_ fileRef: URLReference, andThen activation: DatabaseUnlockerActivationType) {
        databaseRef = fileRef
        fallbackDatabaseRef = DatabaseManager.getFallbackFile(for: databaseRef)
        databaseUnlockerVC.databaseRef = fileRef

        guard let dbSettings = DatabaseSettingsManager.shared.getSettings(for: databaseRef) else {
            setKeyFile(nil)
            setHardwareKey(nil)
            state = .unlockOriginalFileSlow
            refresh()
            return
        }

        if let associatedKeyFileRef = dbSettings.associatedKeyFile {
            let allKeyFiles = FileKeeper.shared.getAllReferences(
                fileType: .keyFile,
                includeBackup: false)
            let matchingKeyFile = associatedKeyFileRef.find(
                in: allKeyFiles,
                fallbackToNamesake: true)
            setKeyFile(matchingKeyFile ?? associatedKeyFileRef)
        } else {
            setKeyFile(nil)
        }

        let associatedHardwareKey = dbSettings.associatedHardwareKey
        setHardwareKey(associatedHardwareKey)

        state = .unlockOriginalFileFast
        refresh()

        DispatchQueue.main.async { [self] in
            maybeShowInitialDatabaseError(fileRef)
            activateDatabase(activation)
        }
    }

    private func maybeShowInitialDatabaseError(_ fileRef: URLReference) {
        databaseUnlockerVC.hideErrorMessage(animated: false)
        if let fileAccessError = fileRef.error {
            showFileError(fileAccessError)
            return
        }

        let timeout = Timeout(duration: 2.0)
        fileRef.refreshInfo(timeout: timeout) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.refresh()
            case .failure(let fileAccessError):
                if fileAccessError.isTimeout {
                    return
                }
                self.showFileError(fileAccessError)
            }
        }
    }
}

extension DatabaseUnlockerCoordinator {

    public func activateDatabase(_ activation: DatabaseUnlockerActivationType) {
        if databaseUnlockerVC.isProgressViewVisible() {
            return
        }

        switch activation {
        case .doNothing:
            return
        case .unlock:
            if canUnlockAutomatically() {
                tryToUnlockDatabase()
                return
            }
            fallthrough
        case .focus:
            databaseUnlockerVC.maybeFocusOnPassword()
        }
    }

    private func showDiagnostics(
        at popoverAnchor: PopoverAnchor,
        in viewController: UIViewController
    ) {
        let modalRouter = NavigationRouter.createModal(style: .formSheet, at: popoverAnchor)
        let diagnosticsViewerCoordinator = DiagnosticsViewerCoordinator(router: modalRouter)
        diagnosticsViewerCoordinator.start()
        viewController.present(modalRouter, animated: true, completion: nil)
        addChildCoordinator(diagnosticsViewerCoordinator, onDismiss: nil)
    }

    private func getPopoverRouter(at popoverAnchor: PopoverAnchor) -> NavigationRouter {
        #if AUTOFILL_EXT
        if ProcessInfo.isRunningOnMac {
            return _router
        }
        #endif
        return NavigationRouter.createModal(style: .popover, at: popoverAnchor)
    }

    private func selectKeyFile(
        at popoverAnchor: PopoverAnchor,
        in viewController: UIViewController
    ) {
        let modalRouter = NavigationRouter.createModal(style: .formSheet, at: popoverAnchor)
        let keyFilePickerCoordinator = KeyFilePickerCoordinator(router: modalRouter)
        keyFilePickerCoordinator.delegate = self
        keyFilePickerCoordinator.start()
        addChildCoordinator(keyFilePickerCoordinator, onDismiss: nil)
        if modalRouter != _router {
            viewController.present(modalRouter, animated: true, completion: nil)
        }
    }

    private func selectHardwareKey(
        at popoverAnchor: PopoverAnchor,
        in viewController: UIViewController
    ) {
        let targetRouter = getPopoverRouter(at: popoverAnchor)
        let hardwareKeyPickerCoordinator = HardwareKeyPickerCoordinator(router: targetRouter)
        hardwareKeyPickerCoordinator.delegate = self
        hardwareKeyPickerCoordinator.setSelectedKey(selectedHardwareKey)
        hardwareKeyPickerCoordinator.start()
        addChildCoordinator(hardwareKeyPickerCoordinator, onDismiss: nil)
        if targetRouter != _router {
            viewController.present(targetRouter, animated: true, completion: nil)
        }
    }

    private func setKeyFile(_ fileRef: URLReference?) {
        selectedKeyFileRef = fileRef
        if reloadingContext == nil {
            DatabaseSettingsManager.shared.updateSettings(for: databaseRef) { dbSettings in
                dbSettings.maybeSetAssociatedKeyFile(fileRef)
            }
        }

        databaseUnlockerVC.setKeyFile(fileRef)
        databaseUnlockerVC.refresh()
    }

    private func setHardwareKey(_ hardwareKey: HardwareKey?) {
        selectedHardwareKey = hardwareKey
        if reloadingContext == nil {
            DatabaseSettingsManager.shared.updateSettings(for: databaseRef) { dbSettings in
                dbSettings.maybeSetAssociatedHardwareKey(hardwareKey)
            }
        }
        databaseUnlockerVC.setHardwareKey(hardwareKey)
        databaseUnlockerVC.refresh()
    }

    private func canUnlockAutomatically() -> Bool {
        if reloadingContext != nil {
            return true
        }
        guard let dbSettings = DatabaseSettingsManager.shared.getSettings(for: databaseRef) else {
            return false
        }
        return dbSettings.hasMasterKey
    }

    private func tryToUnlockDatabase() {
        Diag.clear()

        delegate?.willUnlockDatabase(databaseRef, in: self)
        databaseUnlockerVC.hideErrorMessage(animated: false)
        retryToUnlockDatabase()
    }

    private func retryToUnlockDatabase() {
        assert(databaseLoader == nil)

        let challengeHandler = ChallengeResponseManager.makeHandler(
            for: selectedHardwareKey,
            presenter: _router.navigationController.view
        )

        let databaseSettingsManager = DatabaseSettingsManager.shared
        let dbSettings = databaseSettingsManager.getSettings(for: databaseRef)
        let compositeKey: CompositeKey
        if let storedCompositeKey = reloadingContext?.compositeKey ?? dbSettings?.masterKey {
            compositeKey = storedCompositeKey
            compositeKey.challengeHandler = challengeHandler
            if state == .unlockOriginalFileSlow {
                compositeKey.eraseFinalKeys()
            }
        } else {
            if state == .unlockOriginalFileFast {
                state = .unlockOriginalFileSlow
            }
            let password = databaseUnlockerVC.password
            compositeKey = CompositeKey(
                password: password,
                keyFileRef: selectedKeyFileRef,
                challengeHandler: challengeHandler
            )
        }

        var databaseStatus = DatabaseFile.Status()
        let currentDatabaseRef: URLReference
        switch state {
        case .unlockOriginalFileFast,
             .unlockOriginalFileSlow:
            currentDatabaseRef = databaseRef
        case .unlockFallbackFile:
            guard let fallbackDatabaseRef else {
                assertionFailure("Tried to open non-existent database")
                return
            }
            currentDatabaseRef = fallbackDatabaseRef
            databaseStatus.insert(.localFallback)
        }

        if databaseSettingsManager.isReadOnly(currentDatabaseRef) {
            databaseStatus.insert(.readOnly)
        }
        #if AUTOFILL_EXT
        let fallbackTimeoutDuration = databaseSettingsManager
            .getFallbackTimeout(currentDatabaseRef, forAutoFill: true)
        databaseStatus.insert(.useStreams)
        #elseif MAIN_APP
        let fallbackTimeoutDuration = databaseSettingsManager
            .getFallbackTimeout(currentDatabaseRef, forAutoFill: false)
        #endif

        databaseLoader = DatabaseLoader(
            dbRef: currentDatabaseRef,
            compositeKey: compositeKey,
            status: databaseStatus,
            timeout: Timeout(duration: fallbackTimeoutDuration),
            delegate: self
        )
        databaseLoader!.load()
    }

    private func eraseMasterKey() {
        DatabaseSettingsManager.shared.updateSettings(for: databaseRef) {
            $0.clearMasterKey()
        }
    }

    private func showFileError(_ error: FileAccessError) {
        switch error {
        case .authorizationRequired:
            databaseUnlockerVC.showErrorMessage(
                error.localizedDescription,
                reason: error.failureReason,
                haptics: .error,
                action: .init(
                    title: error.recoverySuggestion ?? LString.actionFixThis,
                    handler: { [weak self] in
                        guard let self else { return }
                        Diag.debug("Will reinstate database")
                        self.delegate?.didPressReinstateDatabase(self.databaseRef, in: self)
                    }
                )
            )
        default:
            databaseUnlockerVC.showErrorMessage(
                error.localizedDescription,
                reason: error.failureReason,
                helpAnchor: error.helpAnchor,
                haptics: .error
            )
        }
    }

    private func showDatabaseLoadError(_ error: DatabaseLoader.Error) {
        let currentDatabaseRef: URLReference
        switch state {
        case .unlockOriginalFileFast,
             .unlockOriginalFileSlow:
            currentDatabaseRef = databaseRef
        case .unlockFallbackFile:
            currentDatabaseRef = fallbackDatabaseRef ?? databaseRef
        }

        guard currentDatabaseRef.needsReinstatement else {
            databaseUnlockerVC.showErrorMessage(
                error.localizedDescription,
                reason: error.failureReason,
                helpAnchor: error.helpAnchor,
                haptics: .error
            )
            return
        }
        databaseUnlockerVC.showErrorMessage(
            error.localizedDescription,
            reason: error.failureReason,
            haptics: .error,
            action: .init(
                title: error.recoverySuggestion ?? LString.actionFixThis,
                handler: { [weak self] in
                    guard let self else { return }
                    Diag.debug("Will reinstate database")
                    self.delegate?.didPressReinstateDatabase(self.databaseRef, in: self)
                }
            )
        )
    }

    private func showIntuneProtectionError() {
        let message = LString.Error.databaseProtectedByIntune + "\n\n" + LString.tryRemoteConnection
        databaseUnlockerVC.showErrorMessage(
            message,
            reason: nil,
            haptics: .error,
            action: .init(
                title: LString.actionConnectToServer,
                handler: { [weak self] in
                    guard let self else { return }
                    Diag.debug("Will add remote database")
                    self.delegate?.didPressAddRemoteDatabase(in: self)
                }
            )
        )
    }
}

extension DatabaseUnlockerCoordinator: DatabaseUnlockerDelegate {
    func shouldDismissFromKeyboard(_ viewController: DatabaseUnlockerVC) -> Bool {
        return delegate?.shouldDismissFromKeyboard(self) ?? false
    }

    func didPressSelectKeyFile(
        at popoverAnchor: PopoverAnchor,
        in viewController: DatabaseUnlockerVC
    ) {
        _router.dismissModals(animated: false, completion: { [weak self] in
            self?.selectKeyFile(at: popoverAnchor, in: viewController)
        })
    }

    func didPressSelectHardwareKey(
        at popoverAnchor: PopoverAnchor,
        in viewController: DatabaseUnlockerVC
    ) {
        _router.dismissModals(animated: false, completion: { [weak self] in
            self?.selectHardwareKey(at: popoverAnchor, in: viewController)
        })
    }

    func shouldDismissPopovers(in viewController: DatabaseUnlockerVC) {
        _router.dismissModals(animated: false, completion: nil)
    }

    func canUnlockAutomatically(_ viewController: DatabaseUnlockerVC) -> Bool {
        return canUnlockAutomatically()
    }
    func didPressUnlock(in viewController: DatabaseUnlockerVC) {
        tryToUnlockDatabase()
    }

    func didPressLock(in viewController: DatabaseUnlockerVC) {
        eraseMasterKey()
    }

    func didPressShowDiagnostics(
        at popoverAnchor: PopoverAnchor,
        in viewController: DatabaseUnlockerVC
    ) {
        showDiagnostics(at: popoverAnchor, in: viewController)
    }
}

extension DatabaseUnlockerCoordinator: KeyFilePickerCoordinatorDelegate {
    func didSelectKeyFile(
        _ fileRef: URLReference?,
        cause: FileActivationCause?,
        in coordinator: KeyFilePickerCoordinator
    ) {
        assert(cause != nil, "File selected but not activated?")
        databaseUnlockerVC.hideErrorMessage(animated: false)
        setKeyFile(fileRef)
    }

    func didEliminateKeyFile(
        _ keyFile: URLReference,
        in coordinator: KeyFilePickerCoordinator
    ) {
        if keyFile == selectedKeyFileRef {
            databaseUnlockerVC.hideErrorMessage(animated: false)
            setKeyFile(nil)
        }
        databaseUnlockerVC.refresh()
    }
}

extension DatabaseUnlockerCoordinator: HardwareKeyPickerCoordinatorDelegate {
    func didSelectKey(_ hardwareKey: HardwareKey?, in coordinator: HardwareKeyPickerCoordinator) {
        databaseUnlockerVC.hideErrorMessage(animated: false)
        setHardwareKey(hardwareKey)
    }
}

extension DatabaseUnlockerCoordinator: DatabaseLoaderDelegate {
    func databaseLoader(_ databaseLoader: DatabaseLoader, willLoadDatabase dbRef: URLReference) {
        databaseUnlockerVC.showProgressView(
            title: LString.databaseStatusLoading,
            allowCancelling: true,
            animated: true
        )
    }

    func databaseLoader(
        _ databaseLoader: DatabaseLoader,
        didChangeProgress progress: ProgressEx,
        for dbRef: URLReference
    ) {
        databaseUnlockerVC.updateProgressView(with: progress)
    }

    func databaseLoader(
        _ databaseLoader: DatabaseLoader,
        didFailLoading dbRef: URLReference,
        with error: DatabaseLoader.Error
    ) {
        self.databaseLoader = nil
        switch error {
        case .cancelledByUser:
            DatabaseSettingsManager.shared.updateSettings(for: databaseRef) { dbSettings in
                dbSettings.clearMasterKey()
            }
            databaseUnlockerVC.refresh()
            databaseUnlockerVC.clearPasswordField()
            databaseUnlockerVC.hideProgressView(animated: true)

            databaseUnlockerVC.maybeFocusOnPassword()
        case .invalidKey:
            switch state {
            case .unlockOriginalFileFast:
                Diag.info("Express unlock failed, retrying slow")
                state = .unlockOriginalFileSlow
                retryToUnlockDatabase()
                return
            case .unlockOriginalFileSlow,
                 .unlockFallbackFile:
                DatabaseSettingsManager.shared.updateSettings(for: databaseRef) { dbSettings in
                    dbSettings.clearMasterKey()
                }
                databaseUnlockerVC.refresh()
                databaseUnlockerVC.hideProgressView(animated: false)
                databaseUnlockerVC.showMasterKeyInvalid(message: error.localizedDescription)
            }
        case .databaseUnreachable:
            databaseUnlockerVC.refresh()

            let currentDatabaseRef = dbRef 
            let fallbackStrategy: UnreachableFileFallbackStrategy =
                delegate?.shouldChooseFallbackStrategy(for: currentDatabaseRef, in: self)
                ?? .showError
            switch fallbackStrategy {
            case .useCache:
                if fallbackDatabaseRef != nil {
                    Diag.info("Original file unreachable, will try fallback")
                    assert(state != .unlockFallbackFile, "Should not fall back from a fallback file")
                    state = .unlockFallbackFile
                    retryToUnlockDatabase()
                    return
                } else {
                    Diag.info("Original file unreachable and there is no fallback")
                    fallthrough
                }
            case .showError:
                databaseUnlockerVC.hideProgressView(animated: true)
                showDatabaseLoadError(error)
                databaseUnlockerVC.maybeFocusOnPassword()
            case .reAddDatabase:
                databaseUnlockerVC.hideProgressView(animated: true)
                showDatabaseLoadError(error)
                delegate?.didPressReinstateDatabase(databaseRef, in: self)
            }
        case .wrongFormat(let fileFormat):
            databaseUnlockerVC.refresh()
            databaseUnlockerVC.hideProgressView(animated: true)
            switch fileFormat {
            case .intuneProtectedFile:
                showIntuneProtectionError()
            default:
                showDatabaseLoadError(error)
            }
        default:
            databaseUnlockerVC.refresh()
            databaseUnlockerVC.hideProgressView(animated: true)

            showDatabaseLoadError(error)
            databaseUnlockerVC.maybeFocusOnPassword()
        }
        delegate?.didNotUnlockDatabase(
            databaseRef,
            with: error.localizedDescription,
            reason: error.failureReason,
            in: self
        )
    }

    func databaseLoader(
        _ databaseLoader: DatabaseLoader,
        didLoadDatabase dbRef: URLReference,
        databaseFile: DatabaseFile,
        withWarnings warnings: DatabaseLoadingWarnings
    ) {
        self.databaseLoader = nil
        HapticFeedback.play(.databaseUnlocked)

        if reloadingContext == nil {
            DatabaseSettingsManager.shared.updateSettings(for: databaseRef) { dbSettings in
                dbSettings.maybeSetMasterKey(of: databaseFile.database)
            }
        }
        databaseUnlockerVC.clearPasswordField()

        delegate?.didUnlockDatabase(
            databaseFile: databaseFile,
            at: databaseRef,
            warnings: warnings,
            in: self
        )
    }
}
