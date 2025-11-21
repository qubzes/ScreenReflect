//
//  ContentView.swift
//  ScreenReflect
//
//  Device list view displayed in the menu bar popover.
//

import SwiftUI

// MARK: - Color Extension for Hex Support

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

struct ContentView: View {

    @ObservedObject var browser: BonjourBrowser
    let connectingDevices: Set<UUID>
    let onDeviceSelected: (DiscoveredDevice) -> Void

    @State private var showManualConnect = false
    @State private var manualHost = "127.0.0.1"
    @State private var manualPort = "8080"

    var body: some View {
        VStack(spacing: 0) {
            // Ultra-sleek Header with shadcn-inspired styling
            HStack(spacing: 12) {
                Image(systemName: "display")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.linearGradient(
                        colors: [Color(hex: "a855f7"), Color(hex: "6366f1")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))

                Text(showManualConnect ? "Manual Connect" : "Screen Reflect")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(hex: "f8fafc"))

                Spacer()

                if showManualConnect {
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showManualConnect = false
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(hex: "94a3b8"))
                            .frame(width: 24, height: 24)
                            .background(Color(hex: "1e293b"))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(hex: "0f172a"))

            Rectangle()
                .fill(Color(hex: "1e293b"))
                .frame(height: 1)

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
                VStack(spacing: 20) {
                    if browser.isBrowsing {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color(hex: "8b5cf6"))

                        Text("Searching for devices...")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color(hex: "cbd5e1"))

                        Text("Make sure your Android device is running Screen Reflect")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "64748b"))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    } else {
                        ZStack {
                            Circle()
                                .fill(Color(hex: "1e293b"))
                                .frame(width: 80, height: 80)

                            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                .font(.system(size: 32, weight: .light))
                                .foregroundColor(Color(hex: "64748b"))
                        }

                        Text("No devices found")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color(hex: "94a3b8"))
                    }
                }
                .frame(maxHeight: .infinity)
                .frame(maxWidth: .infinity)
                .background(Color(hex: "0a0f1e"))
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(browser.resolvedServices) { device in
                            DeviceRow(
                                device: device,
                                isConnecting: connectingDevices.contains(device.id)
                            ) {
                                onDeviceSelected(device)
                            }
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                }
                .background(Color(hex: "0a0f1e"))
            }

            Rectangle()
                .fill(Color(hex: "1e293b"))
                .frame(height: 1)

            // Ultra-sleek Footer
            HStack(spacing: 12) {
                if browser.isBrowsing {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(hex: "10b981"))
                            .frame(width: 6, height: 6)
                            .shadow(color: Color(hex: "10b981").opacity(0.5), radius: 4, x: 0, y: 0)

                        Text("Searching...")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "64748b"))
                    }
                }

                Spacer()

                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showManualConnect = true
                    }
                }) {
                    Text("Manual Connect")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "8b5cf6"))
                }
                .buttonStyle(.plain)

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Text("Quit")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "64748b"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(hex: "0f172a"))
        }
        .frame(width: 340, height: 420)
        .background(Color(hex: "0a0f1e"))
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

// MARK: - Ultra-sleek Device Row

struct DeviceRow: View {

    let device: DiscoveredDevice
    let isConnecting: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Device Icon with gradient background
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(
                            colors: [Color(hex: "6366f1"), Color(hex: "8b5cf6")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 44, height: 44)

                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(hex: "f1f5f9"))
                        .lineLimit(1)

                    Text("\(device.hostName):\(device.port)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Color(hex: "64748b"))
                        .lineLimit(1)
                }

                Spacer()

                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color(hex: "8b5cf6"))
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: isHovering ? "8b5cf6" : "475569"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hex: "1e293b"))
                    .opacity(isHovering ? 0.8 : 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        LinearGradient(
                            colors: isHovering ?
                                [Color(hex: "6366f1").opacity(0.5), Color(hex: "8b5cf6").opacity(0.5)] :
                                [Color(hex: "334155").opacity(0.3), Color(hex: "334155").opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: isHovering ? Color(hex: "8b5cf6").opacity(0.2) : .clear, radius: 8, x: 0, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isConnecting)
        .onHover { hovering in
            isHovering = hovering && !isConnecting
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
