//
//  BonjourBrowser.swift
//  ScreenReflect
//
//  Discovers Android "Screen Reflect" servers on the local network via Bonjour (mDNS).
//

import Foundation
import Network

/// Represents a discovered and resolved Android device running Screen Reflect
struct DiscoveredDevice: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let hostName: String
    let port: Int
    let netService: NetService

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id
    }
}

/// Service discovery manager using NetServiceBrowser for Bonjour/mDNS
@MainActor
class BonjourBrowser: NSObject, ObservableObject {

    // MARK: - Published Properties

    /// List of discovered and successfully resolved devices
    @Published var resolvedServices: [DiscoveredDevice] = []

    /// Indicates if browsing is active
    @Published var isBrowsing: Bool = false

    // MARK: - Private Properties

    private var browser: NetServiceBrowser?
    private var pendingServices: [NetService] = []
    private var localhostScanTimer: Timer?

    // MARK: - Public Methods

    /// Start browsing for Screen Reflect services
    func startBrowsing() {
        guard browser == nil else { return }

        browser = NetServiceBrowser()
        browser?.delegate = self
        browser?.searchForServices(ofType: "_screenreflect._tcp.", inDomain: "local.")

        // Also start localhost scanning for ADB forwarded connections
        startLocalhostScanning()

        isBrowsing = true
        print("[BonjourBrowser] Started browsing for _screenreflect._tcp. services")
    }

    /// Stop browsing and clear all discovered services
    func stopBrowsing() {
        browser?.stop()
        browser?.delegate = nil
        browser = nil

        localhostScanTimer?.invalidate()
        localhostScanTimer = nil

        pendingServices.removeAll()
        resolvedServices.removeAll()
        isBrowsing = false

        print("[BonjourBrowser] Stopped browsing")
    }

    // MARK: - Localhost Scanning for ADB

    private func startLocalhostScanning() {
        print("[BonjourBrowser] Starting localhost scan for ADB forwarded servers")

        // Scan immediately
        scanLocalhostPorts()

        // Then scan every 5 seconds
        localhostScanTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanLocalhostPorts()
            }
        }
    }

    private func scanLocalhostPorts() {
        // Common Android ADB forwarded port range
        let portsToCheck = [33000, 34000, 35000, 36000, 37000, 38000, 39000, 40000]

        for port in portsToCheck {
            checkLocalhostPort(port)
        }
    }

    private func checkLocalhostPort(_ port: Int) {
        let host = NWEndpoint.Host("127.0.0.1")
        let portEndpoint = NWEndpoint.Port(integerLiteral: UInt16(port))

        let parameters = NWParameters.tcp
        let connection = NWConnection(host: host, port: portEndpoint, using: parameters)

        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                // Connection successful - found a server!
                Task { @MainActor in
                    self?.addLocalhostServer(port: port)
                }
                connection.cancel()
            } else if case .failed = state, case .waiting = state {
                connection.cancel()
            }
        }

        connection.start(queue: .global(qos: .background))

        // Timeout after 1 second
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1.0) {
            connection.cancel()
        }
    }

    private func addLocalhostServer(port: Int) {
        // Check if already in list
        guard !resolvedServices.contains(where: { $0.hostName == "127.0.0.1" && $0.port == port }) else {
            return
        }

        print("[BonjourBrowser] ✅ Found Screen Reflect server on localhost:\(port)")

        let netService = NetService(domain: "local.", type: "_screenreflect._tcp.", name: "localhost")
        let device = DiscoveredDevice(
            name: "Local Device (ADB)",
            hostName: "127.0.0.1",
            port: port,
            netService: netService
        )

        resolvedServices.insert(device, at: 0)  // Insert at top
    }
}

// MARK: - NetServiceBrowserDelegate

extension BonjourBrowser: NetServiceBrowserDelegate {

    nonisolated func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        Task { @MainActor in
            print("[BonjourBrowser] Browser will search")
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        Task { @MainActor in
            print("[BonjourBrowser] Browser did not search: \(errorDict)")
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            print("[BonjourBrowser] Found service: \(service.name)")

            // Add to pending list
            pendingServices.append(service)

            // Set delegate and resolve
            service.delegate = self
            service.resolve(withTimeout: 5.0)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Task { @MainActor in
            print("[BonjourBrowser] Removed service: \(service.name)")

            // Remove from resolved list
            resolvedServices.removeAll { device in
                device.netService.name == service.name
            }

            // Remove from pending list
            pendingServices.removeAll { $0.name == service.name }
        }
    }
}

// MARK: - NetServiceDelegate

extension BonjourBrowser: NetServiceDelegate {

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in
            guard let hostName = sender.hostName else {
                print("[BonjourBrowser] Service resolved but no hostname: \(sender.name)")
                return
            }

            let port = sender.port

            print("[BonjourBrowser] Successfully resolved service: \(sender.name) at \(hostName):\(port)")

            // Create device model
            let device = DiscoveredDevice(
                name: sender.name,
                hostName: hostName,
                port: port,
                netService: sender
            )

            // Add to resolved list if not already present
            if !resolvedServices.contains(where: { $0.name == device.name }) {
                resolvedServices.append(device)
            }

            // Remove from pending
            pendingServices.removeAll { $0.name == sender.name }
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        Task { @MainActor in
            print("[BonjourBrowser] Service did not resolve: \(sender.name), error: \(errorDict)")

            // Remove from pending
            pendingServices.removeAll { $0.name == sender.name }
        }
    }
}
