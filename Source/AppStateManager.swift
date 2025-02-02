//
//  AppStateManager.swift
//  vpncore - Created on 26.06.19.
//
//  Copyright (c) 2019 Proton Technologies AG
//
//  This file is part of vpncore.
//
//  vpncore is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  vpncore is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with vpncore.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import Reachability

public protocol AppStateManagerFactory {
    func makeAppStateManager() -> AppStateManager
}

public class AppStateManager {
    
    private let alamofireWrapper: AlamofireWrapper
    private let vpnApiService: VpnApiService
    private var vpnManager: VpnManagerProtocol
    private let propertiesManager: PropertiesManagerProtocol
    private let serverStorage: ServerStorage = ServerStorageConcrete()
    private let timerFactory: TimerFactoryProtocol
    private let vpnKeychain: VpnKeychainProtocol
    private let configurationPreparer: VpnManagerConfigurationPreparer
    
    public let stateChange = Notification.Name("AppStateManagerStateChange")
    public let wake = Notification.Name("AppStateManagerWake")
    
    public weak var alertService: CoreAlertService?
    
    private var reachability: Reachability?
    public private(set) var state: AppState = .disconnected
    private var vpnState: VpnState = .invalid {
        didSet {
            onVpnStateChanged?(vpnState)
        }
    }
    public var onVpnStateChanged: ((VpnState) -> Void)?
    private var lastAttemptedConfiguration: ConnectionConfiguration?
    private var attemptingConnection = false
    private var stuckDisconnecting = false {
        didSet {
            if stuckDisconnecting == false {
                reconnectingAfterStuckDisconnecting = false
            }
        }
    }
    private var reconnectingAfterStuckDisconnecting = false
    
    private var timeoutTimer: Timer?
    private var serviceChecker: ServiceChecker?
    
    public init(vpnApiService: VpnApiService, vpnManager: VpnManagerProtocol, alamofireWrapper: AlamofireWrapper, alertService: CoreAlertService, timerFactory: TimerFactoryProtocol, propertiesManager: PropertiesManagerProtocol, vpnKeychain: VpnKeychainProtocol, configurationPreparer: VpnManagerConfigurationPreparer) {
        self.vpnApiService = vpnApiService
        self.vpnManager = vpnManager
        self.alamofireWrapper = alamofireWrapper
        self.alertService = alertService
        self.timerFactory = timerFactory
        self.propertiesManager = propertiesManager
        self.vpnKeychain = vpnKeychain
        self.configurationPreparer = configurationPreparer
        
        handleVpnStateChange(vpnManager.state)
        reachability = try? Reachability()
        setupReachability()
        startObserving()
    }
    
    deinit {
        reachability?.stopNotifier()
    }
    
    public func isOnDemandEnabled(handler: @escaping (Bool) -> Void) {
        vpnManager.isOnDemandEnabled(handler: handler)
    }
    
    public func prepareToConnect() {
        if !propertiesManager.hasConnected {
            switch vpnState {
            case .disconnecting:
                vpnStuck()
                return
            default:
                alertService?.push(alert: FirstTimeConnectingAlert())
            }
        }
        
        prepareServerCertificate()
        
        if vpnKeychain.hasOldVpnPassword() {
            try? vpnKeychain.clearOldVpnPassword()
            alertService?.push(alert: FirstTimeConnectingAlert())
        }
        
        if case VpnState.disconnecting = vpnState {
            stuckDisconnecting = true
        }
        
        state = .preparingConnection
        attemptingConnection = true
        beginTimoutCountdown()
        notifyObservers()
    }
    
    public func cancelConnectionAttempt() {
        cancelConnectionAttempt {}
    }
    
    public func cancelConnectionAttempt(completion: @escaping () -> Void) {
        state = .aborted(userInitiated: true)
        attemptingConnection = false
        cancelTimout()
        
        notifyObservers()
        
        disconnect(completion: completion)
    }
    
    public func refreshState() {
        vpnManager.refreshState()
    }
    
    public func connect(withConfiguration configuration: ConnectionConfiguration) {
        guard let reachability = reachability else { return }
        if case AppState.aborted = state { return }
        
        if reachability.connection == .unavailable {
            notifyNetworkUnreachable()
            return
        }
        
        do {
            let vpnCredentials = try vpnKeychain.fetch()
            
            if checkDelinquency(credentials: vpnCredentials) {
                return
            }
        } catch {
            connectionFailed()
            alertService?.push(alert: CannotAccessVpnCredentialsAlert())
        }
        
        lastAttemptedConfiguration = configuration
        
        attemptingConnection = true
        
        let serverAge = ServerStorageConcrete().fetchAge()
        if Date().timeIntervalSince1970 - serverAge > (2 * 60 * 60) {
            // if this is too common, then we should pick a random server instead of using really old score values
            PMLog.ET("Connecting with scores older than 2 hours", level: .warn)
        }
        
        PMLog.D("Connect started")
        makeConnection(configuration)
    }
    
    public func disconnect() {
        disconnect {}
    }
    
    public func disconnect(completion: @escaping () -> Void) {
        PMLog.D("Disconnect started")
        propertiesManager.intentionallyDisconnected = true
        vpnManager.disconnect(completion: completion)
    }
    
    public func connectedDate(completion: @escaping (Date?) -> Void) {
        let savedDate = Date(timeIntervalSince1970: propertiesManager.lastConnectedTimeStamp)
        vpnManager.connectedDate { [weak self] (date) in
            if let connectionDate = date, connectionDate > savedDate {
                self?.propertiesManager.lastConnectedTimeStamp = connectionDate.timeIntervalSince1970
                completion(connectionDate)
            } else {
                completion(savedDate)
            }
        }
    }
    
    public func activeConnection() -> ConnectionConfiguration? {
        guard let currentVpnProtocol = vpnManager.currentVpnProtocol else {
            return nil
        }
        
        switch currentVpnProtocol {
        case .ike:
            return propertiesManager.lastIkeConnection
        case .openVpn:
            return propertiesManager.lastOpenVpnConnection
        }
    }
    
    // MARK: - Private functions
    private func beginTimoutCountdown() {
        cancelTimout()
        timeoutTimer = timerFactory.timer(timeInterval: 30, repeats: false, block: { [weak self] _ in
            self?.timeout()
        })
        timeoutTimer?.tolerance = 5.0
        RunLoop.current.add(timeoutTimer!, forMode: .default)
    }
    
    private func cancelTimout() {
        timeoutTimer?.invalidate()
    }
    
    @objc private func timeout() {
        PMLog.D("Connection attempt timed out")
        state = .aborted(userInitiated: false)
        attemptingConnection = false
        cancelTimout()
        stopAttemptingConnection()
    }
    
    private func stopAttemptingConnection() {
        PMLog.D("Stop preparing connection")
        cancelTimout()
        handleVpnError(vpnState)
        disconnect()
    }
    
    private func prepareServerCertificate() {
        do {
            _ = try vpnKeychain.getServerCertificate()
        } catch {
            try? vpnKeychain.storeServerCertificate()
        }
    }
    
    private func makeConnection(_ connectionConfiguration: ConnectionConfiguration) {
        guard let vpnManagerConfiguration = configurationPreparer.prepareConfiguration(from: connectionConfiguration) else {
            cancelConnectionAttempt()
            return
        }
        
        switch connectionConfiguration.vpnProtocol {
        case .ike:
            self.propertiesManager.lastIkeConnection = connectionConfiguration
        case .openVpn:
            self.propertiesManager.lastOpenVpnConnection = connectionConfiguration
        }
        
        vpnManager.connect(configuration: vpnManagerConfiguration, completion: {
            // COMPLETION
        })
    }
    
    private func setupReachability() {
        guard let reachability = reachability else {
            return
        }
        
        do {
            try reachability.startNotifier()
        } catch {
            return
        }
    }
    
    private func startObserving() {
        vpnManager.stateChanged = { [weak self] in
            self?.vpnStateChanged()
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(killSwitchChanged), name: type(of: propertiesManager).hasConnectedNotification, object: nil)
    }
    
    @objc private func vpnStateChanged() {
        reachability?.whenReachable = nil
        
        let newState = vpnManager.state
        switch newState {
        case .error:
            if case VpnState.invalid = vpnState {
                vpnState = newState
                return // otherwise shows connecting failed on first attempt
            } else if attemptingConnection {
                stopAttemptingConnection()
            }
        default:
            break
        }
        
        vpnState = newState
        handleVpnStateChange(newState)
    }
    
    @objc private func killSwitchChanged() {
        if state.isConnected {
            propertiesManager.intentionallyDisconnected = true
            vpnManager.setOnDemand(propertiesManager.hasConnected)
        }
    }
    
    // swiftlint:disable cyclomatic_complexity
    private func handleVpnStateChange(_ vpnState: VpnState) {
        if case VpnState.disconnecting = vpnState {} else {
            stuckDisconnecting = false
        }
        
        switch vpnState {
        case .invalid:
            return // NEVPNManager hasn't initialised yet
        case .disconnected:
            if attemptingConnection {
                state = .preparingConnection
                return
            } else {
                state = .disconnected
            }
        case .connecting(let descriptor):
            state = .connecting(descriptor)
        case .connected(let descriptor):
            propertiesManager.intentionallyDisconnected = false
            
            serviceChecker?.stop()
            if let alertService = alertService {
                serviceChecker = ServiceChecker(alamofireWrapper: alamofireWrapper, alertService: alertService)
            }
            attemptingConnection = false
            state = .connected(descriptor)
            cancelTimout()
        case .reasserting:
            return // usually this step is quick
        case .disconnecting(let descriptor):
            if attemptingConnection { // needs to disconnect before attempting to connect
                if case AppState.connecting = state {
                    stopAttemptingConnection()
                } else {
                    state = .preparingConnection
                }
            } else {
                state = .disconnecting(descriptor)
            }
        case .error(let error):
            state = .error(error)
        }
        
        if !state.isConnected {
            serviceChecker?.stop()
            serviceChecker = nil
        }
        
        notifyObservers()
    }
    // swiftlint:enable cyclomatic_complexity
    
    private func unknownError(_ vpnState: VpnState) {
        handleVpnStateChange(vpnState)
    }
    
    private func connectionFailed() {
        state = .error(NSError(code: 0, localizedDescription: ""))
        notifyObservers()
    }
    
    private func checkDelinquency(credentials: VpnCredentials) -> Bool {
        if credentials.isDelinquent {
            alertService?.push(alert: DelinquentUserAlert(confirmHandler: {
                SafariService.openLink(url: CoreAppConstants.ProtonVpnLinks.accountDashboard)
            }))
            
            connectionFailed()
            return true
        } else {
            return false
        }
    }
    
    private func handleVpnError(_ vpnState: VpnState) {
        // In the rare event that the vpn is stuck not disconnecting, show a helpful alert
        if case VpnState.disconnecting(_) = vpnState, stuckDisconnecting {
            PMLog.D("Stale VPN connection failing to disconnect")
            vpnStuck()
            return
        }
        
        attemptingConnection = false
        
        do {
            let vpnCredentials = try vpnKeychain.fetch()
            
            if checkDelinquency(credentials: vpnCredentials) {
                return
            }
            
            checkApiForFailureReason(vpnCredentials: vpnCredentials)
        } catch {
            connectionFailed()
            alertService?.push(alert: CannotAccessVpnCredentialsAlert())
        }
    }
    
    private func checkApiForFailureReason(vpnCredentials: VpnCredentials) {
        let dispatchGroup = DispatchGroup()
        
        var rSessionCount: Int?
        var rVpnCredentials: VpnCredentials?
        
        let failureClosure: (Error) -> Void = { error in
            dispatchGroup.leave()
        }
        
        dispatchGroup.enter()
        vpnApiService.sessions(success: { sessions in
            rSessionCount = sessions.count
            dispatchGroup.leave()
        }, failure: failureClosure)
        
        dispatchGroup.enter()
        vpnApiService.clientCredentials(success: { newVpnCredentials in
            rVpnCredentials = newVpnCredentials
            dispatchGroup.leave()
        }, failure: failureClosure)
        
        dispatchGroup.notify(queue: DispatchQueue.main) { [weak self] in
            guard let `self` = self, self.state.isDisconnected else { return }
            
            if let sessionCount = rSessionCount, sessionCount >= (rVpnCredentials?.maxConnect ?? vpnCredentials.maxConnect) {
                self.alertService?.push(alert: SessionCountLimitAlert())
                self.connectionFailed()
            } else if let newVpnCredentials = rVpnCredentials, newVpnCredentials.password != vpnCredentials.password {
                self.vpnKeychain.store(vpnCredentials: newVpnCredentials)
                guard let lastConfiguration = self.lastAttemptedConfiguration else {
                    return
                }
                if self.state.isDisconnected {
                    self.isOnDemandEnabled { enabled in
                        guard !enabled else { return }
                        
                        PMLog.D("Attempt connection after handling error")
                        self.connect(withConfiguration: lastConfiguration)
                    }
                }
            }
        }
    }
    
    private func notifyObservers() {
        DispatchQueue.main.async { [weak self] in
            guard let `self` = self else { return }
            
            NotificationCenter.default.post(name: self.stateChange, object: self.state)
        }
    }
    
    private func notifyNetworkUnreachable() {
        attemptingConnection = false
        cancelTimout()
        connectionFailed()
        
        DispatchQueue.main.async { [weak self] in
            guard let `self` = self else { return }
            self.alertService?.push(alert: VpnNetworkUnreachableAlert())
        }
    }
    
    private func vpnStuck() {
        vpnManager.removeConfigurations(completionHandler: { [weak self] error in
            guard let `self` = self else { return }
            guard error == nil, self.reconnectingAfterStuckDisconnecting == false, let lastConfig = self.lastAttemptedConfiguration else {
                self.alertService?.push(alert: VpnStuckAlert())
                self.connectionFailed()
                return
            }
            self.reconnectingAfterStuckDisconnecting = true
            self.connect(withConfiguration: lastConfig) // Retry connection
        })
    }
    
}
