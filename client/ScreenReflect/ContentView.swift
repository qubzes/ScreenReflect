//
//  ContentView.swift
//  ScreenReflect
//
//  Device list view displayed in the menu bar popover.
//

import SwiftUI

struct ContentView: View {

    @ObservedObject var browser: BonjourBrowser
    let connectingDevices: Set<UUID>
    let onDeviceSelected: (DiscoveredDevice) -> Void

    @State private var showManualConnect = false
    @State private var manualHost = "127.0.0.1"
    @State private var manualPort = "8080"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "display")
                    .font(.title2)
                    .foregroundColor(.blue)

                Text(showManualConnect ? "Manual Connect" : "Screen Reflect")
                    .font(.headline)

                Spacer()

                if showManualConnect {
                    Button(action: {
                        showManualConnect = false
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()

            Divider()

            // Show Manual Connect UI or Device List
            if showManualConnect {
                ManualConnectContentView(
                    host: $manualHost,
                    port: $manualPort,
                    onConnect: {
                        if let portInt = Int(manualPort) {
                            let manualDevice = DiscoveredDevice(
                                name: "Manual Connection",
                                hostName: manualHost,
                                port: portInt,
                                netService: NetService(domain: "local.", type: "_screenreflect._tcp.", name: "manual")
                            )
                            showManualConnect = false
                            onDeviceSelected(manualDevice)
                        }
                    },
                    onCancel: {
                        showManualConnect = false
                    }
                )
            } else if browser.resolvedServices.isEmpty {
                VStack(spacing: 16) {
                    if browser.isBrowsing {
                        ProgressView()
                            .scaleEffect(1.2)

                        Text("Searching for devices...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("Make sure your Android device is running Screen Reflect")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)

                        Text("No devices found")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(browser.resolvedServices) { device in
                            DeviceRow(
                                device: device,
                                isConnecting: connectingDevices.contains(device.id)
                            ) {
                                onDeviceSelected(device)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            Divider()

            // Footer
            HStack {
                if browser.isBrowsing {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)

                        Text("Searching...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button(action: {
                    showManualConnect = true
                }) {
                    Text("Manual Connect")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Text("Quit")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding()
        }
        .onAppear {
            browser.startBrowsing()
        }
    }
}

// MARK: - Manual Connect Content View (Inline)

struct ManualConnectContentView: View {
    @Binding var host: String
    @Binding var port: String
    let onConnect: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("For Android Emulator:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Host:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("127.0.0.1", text: $host)
                        .textFieldStyle(.roundedBorder)

                    Text("Port:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("8080", text: $port)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)

                Divider()
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Instructions:")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    Text("1. Note the port on Android app")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text("2. Run on Mac:")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text("adb forward tcp:<port> tcp:<port>")
                        .font(.caption2)
                        .foregroundColor(.blue)
                        .monospaced()
                        .padding(.leading, 8)

                    Text("3. Enter port above and connect")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding()
        }

        Divider()

        // Footer with buttons
        HStack {
            Spacer()

            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Button("Connect") {
                onConnect()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }
}

// MARK: - Device Row

struct DeviceRow: View {

    let device: DiscoveredDevice
    let isConnecting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "iphone")
                    .font(.title2)
                    .foregroundColor(.blue)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.body)
                        .foregroundColor(.primary)

                    Text("\(device.hostName):\(device.port)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isConnecting {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                    Text("Connecting...")
                        .font(.caption2)
                        .foregroundColor(.blue)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)  // Disable button while connecting
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.0))
        )
        .opacity(isConnecting ? 0.7 : 1.0)  // Dim while connecting
        .onHover { hovering in
            // Visual feedback on hover can be added here if desired
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView(
        browser: BonjourBrowser(),
        connectingDevices: [],
        onDeviceSelected: { device in
            print("Selected: \(device.name)")
        }
    )
}
