//
//  AppState.swift
//  ScreenReflect
//
//  Manages global application state.
//

import Foundation
import Combine

@MainActor
class AppState: ObservableObject {
    @Published var connectingDevices: Set<UUID> = []
    @Published var connectedDevices: Set<UUID> = []

    private var streamClients: [UUID: StreamClient] = [:]
    private var observers: [UUID: AnyCancellable] = [:]

    func setConnecting(_ deviceId: UUID, isConnecting: Bool) {
        print("[AppState] setConnecting(\(deviceId), \(isConnecting))")
        if isConnecting {
            connectingDevices.insert(deviceId)
        } else {
            connectingDevices.remove(deviceId)
        }
        print("[AppState] connectingDevices count: \(connectingDevices.count)")
    }

    func setConnected(_ deviceId: UUID, isConnected: Bool) {
        print("[AppState] setConnected(\(deviceId), \(isConnected))")
        if isConnected {
            connectedDevices.insert(deviceId)
        } else {
            connectedDevices.remove(deviceId)
        }
        print("[AppState] connectedDevices count: \(connectedDevices.count)")
    }

    func registerStreamClient(_ deviceId: UUID, _ streamClient: StreamClient) {
        print("[AppState] Registering stream client for device \(deviceId)")
        streamClients[deviceId] = streamClient

        // Observe the stream client's connection state
        observers[deviceId] = streamClient.$isConnected
            .sink { [weak self] isConnected in
                print("[AppState] Stream client \(deviceId) isConnected changed to: \(isConnected)")
                self?.setConnected(deviceId, isConnected: isConnected)
                if isConnected {
                    self?.setConnecting(deviceId, isConnecting: false)
                }
            }
    }

    func unregisterStreamClient(_ deviceId: UUID) {
        print("[AppState] Unregistering stream client for device \(deviceId)")
        observers[deviceId]?.cancel()
        observers.removeValue(forKey: deviceId)
        streamClients.removeValue(forKey: deviceId)
    }
}
