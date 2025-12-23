//
//  StreamClient.swift
//  ScreenReflect
//
//  Ultra-low-latency TCP client for real-time A/V streaming.
//  Uses highest priority queue for immediate packet processing.
//

import Foundation
import Network

/// Packet types in the custom protocol
enum PacketType: UInt8 {
    case config = 0x00       // H.264 SPS/PPS configuration
    case video = 0x01        // H.264 video frame
    case audio = 0x02        // AAC audio frame
    case audioConfig = 0x03  // AAC AudioSpecificConfig (CSD-0)
    case dimension = 0x04    // Video dimension update (8 bytes: width + height)
}

/// Network client that manages TCP connection and stream parsing
@MainActor
class StreamClient: ObservableObject {

    // MARK: - Published Properties

    @Published var isConnected: Bool = false
    @Published var connectionError: String?
    @Published var videoDimensions: CGSize?

    // MARK: - Private Properties

    private var connection: NWConnection?
    private let device: DiscoveredDevice

    // References to decoders (injected)
    private let h264Decoder: H264Decoder
    private let aacDecoder: AACDecoder

    // MARK: - Initialization

    init(device: DiscoveredDevice, h264Decoder: H264Decoder, aacDecoder: AACDecoder) {
        self.device = device
        self.h264Decoder = h264Decoder
        self.aacDecoder = aacDecoder
    }

    // MARK: - Connection Management

    /// Connect to the Android device
    func connect() {
        // If already connected, do nothing
        if isConnected && connection != nil {
            print("[StreamClient] Already connected")
            return
        }

        // Clean up any existing connection before reconnecting
        if connection != nil {
            print("[StreamClient] Cleaning up existing connection before reconnect")
            disconnect()
        }

        print("[StreamClient] Connecting to \(device.hostName):\(device.port)")

        // Reset decoders for clean state
        h264Decoder.reset()
        aacDecoder.reset()

        // Create endpoint from resolved service
        let host = NWEndpoint.Host(device.hostName)
        let port = NWEndpoint.Port(integerLiteral: UInt16(device.port))

        // Configure TCP parameters for ultra-low-latency
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3
        tcpOptions.noDelay = true  // CRITICAL: Disable Nagle's algorithm for immediate sends

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.serviceClass = .responsiveData  // Low latency service class

        // Create connection
        connection = NWConnection(host: host, port: port, using: parameters)

        // Setup state handler
        connection?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleStateChange(state)
            }
        }

        // Start connection on HIGHEST priority queue for immediate packet processing
        connection?.start(queue: DispatchQueue.global(qos: .userInteractive))
    }

    /// Disconnect from the device
    func disconnect() {
        print("[StreamClient] Disconnecting...")

        // Cancel and clean up connection
        connection?.cancel()
        connection = nil

        // Update state
        isConnected = false
        connectionError = nil

        print("[StreamClient] Disconnected")
    }

    // MARK: - State Handling

    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            print("[StreamClient] Connection ready")
            isConnected = true
            connectionError = nil
            // Start receiving data
            receivePacket()

        case .waiting(let error):
            print("[StreamClient] Connection waiting: \(error)")
            connectionError = error.localizedDescription

        case .failed(let error):
            print("[StreamClient] Connection failed: \(error)")
            isConnected = false
            connectionError = error.localizedDescription

        case .cancelled:
            print("[StreamClient] Connection cancelled")
            isConnected = false

        default:
            break
        }
    }

    // MARK: - Data Reception and Parsing

    /// Receive a single packet (recursive)
    private func receivePacket() {
        guard let connection = connection else {
            print("[StreamClient] receivePacket: connection is nil")
            return
        }

        // Step 1: Receive 1-byte packet type
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("[StreamClient] Receive error (type): \(error.localizedDescription)")
                print("[StreamClient] Error details: \(error)")
                Task { @MainActor in
                    self.connectionError = "Failed to receive packet type: \(error.localizedDescription)"
                    self.disconnect()
                }
                return
            }

            guard let typeData = data, typeData.count == 1 else {
                if isComplete {
                    print("[StreamClient] Connection closed by server (no type data)")
                    Task { @MainActor in
                        self.disconnect()
                    }
                } else {
                    print("[StreamClient] Incomplete type data: \(data?.count ?? 0) bytes")
                }
                return
            }

            let packetTypeByte = typeData[0]
            guard let packetType = PacketType(rawValue: packetTypeByte) else {
                print("[StreamClient] Unknown packet type: \(packetTypeByte)")
                Task { @MainActor in
                    self.receivePacket() // Continue listening
                }
                return
            }

            // Step 2: Receive 4-byte length (big-endian)
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, isComplete, error in
                if let error = error {
                    print("[StreamClient] Receive error (length): \(error.localizedDescription)")
                    print("[StreamClient] Length error details: \(error)")
                    Task { @MainActor in
                        self.connectionError = "Failed to receive packet length: \(error.localizedDescription)"
                        self.disconnect()
                    }
                    return
                }

                guard let lengthData = data, lengthData.count == 4 else {
                    if isComplete {
                        print("[StreamClient] Connection closed by server (no length data)")
                        Task { @MainActor in
                            self.disconnect()
                        }
                    } else {
                        print("[StreamClient] Incomplete length data: \(data?.count ?? 0) bytes")
                    }
                    return
                }

                // Parse big-endian UInt32
                let length = lengthData.withUnsafeBytes { ptr in
                    ptr.load(as: UInt32.self).bigEndian
                }

                guard length > 0 && length < 10_000_000 else { // Sanity check: max 10MB
                    print("[StreamClient] Invalid packet length: \(length)")
                    Task { @MainActor in
                        self.receivePacket()
                    }
                    return
                }

                // Step 3: Receive payload
                connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { data, _, isComplete, error in
                    if let error = error {
                        print("[StreamClient] Receive error (payload): \(error.localizedDescription)")
                        print("[StreamClient] Payload error details: \(error)")
                        Task { @MainActor in
                            self.connectionError = "Failed to receive payload: \(error.localizedDescription)"
                            self.disconnect()
                        }
                        return
                    }

                    guard let payloadData = data, payloadData.count == Int(length) else {
                        if isComplete {
                            print("[StreamClient] Connection closed by server (no payload data, expected \(length) bytes)")
                            Task { @MainActor in
                                self.disconnect()
                            }
                        } else {
                            print("[StreamClient] Incomplete payload data: \(data?.count ?? 0)/\(length) bytes")
                        }
                        return
                    }

                    // Process the packet on background queue for better performance
                    // Removed Task { @MainActor } to avoid thread hopping and latency
                    self.processPacket(type: packetType, data: payloadData)
                    
                    // Continue receiving next packet
                    self.receivePacket()
                }
            }
        }
    }

    /// Process a received packet
    private func processPacket(type: PacketType, data: Data) {
        switch type {
        case .config:
            print("[StreamClient] Received CONFIG packet (\(data.count) bytes)")
            h264Decoder.processConfig(data: data)

        case .video:
            // Only log config packets to reduce overhead
            h264Decoder.decode(data: data)

        case .audio:
            // Only log config packets to reduce overhead
            aacDecoder.decode(data: data)

        case .audioConfig:
            print("[StreamClient] Received AUDIO_CONFIG packet (\(data.count) bytes)")
            aacDecoder.setAudioSpecificConfig(data: data)
            
        case .dimension:
            // Parse dimension packet: 4 bytes width + 4 bytes height (big-endian)
            guard data.count == 8 else {
                print("[StreamClient] Invalid DIMENSION packet size: \(data.count) bytes (expected 8)")
                return
            }
            
            let width = data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: 0, as: UInt32.self).bigEndian
            }
            
            let height = data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: 4, as: UInt32.self).bigEndian
            }
            
            let newDimensions = CGSize(width: CGFloat(width), height: CGFloat(height))
            print("[StreamClient] Received DIMENSION update: \(Int(width))x\(Int(height))")
            
            // Update published property to notify UI
            videoDimensions = newDimensions
            
            // Prepare decoder for new dimensions (it will handle this when new CONFIG arrives)
            h264Decoder.prepareForDimensionChange(newDimensions: newDimensions)
        }
    }
}
