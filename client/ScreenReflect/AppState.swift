//
//  AppState.swift
//  ScreenReflect
//
//  Manages global application state.
//

import Foundation
import Combine

class AppState: ObservableObject {
    @Published var connectingDevices: Set<UUID> = []
    
    func setConnecting(_ deviceId: UUID, isConnecting: Bool) {
        if isConnecting {
            connectingDevices.insert(deviceId)
        } else {
            connectingDevices.remove(deviceId)
        }
    }
}
