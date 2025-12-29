//
//  StreamClient.swift
//  ScreenReflect
//
//  Low-latency TCP client for real-time A/V streaming.
//  Uses direct packet processing with minimal main thread involvement.
//

import Foundation
import Network

/// Packet types in the custom protocol
enum PacketType: UInt8 {
    case config = 0x00       // H.264 SPS/PPS configuration
    case video = 0x01        // H.264 video frame
    case audio = 0x02        // AAC audio frame
    case audioConfig = 0x03  // AAC AudioSpecificConfig
    case dimension = 0x04    // Video dimension update (8 bytes)
}

// MARK: - Packet Processing (Nonisolated)

/// Continuous packet receive loop - runs entirely on network queue
/// Standalone function to avoid MainActor isolation
private func streamReceiveLoop(
    connection: NWConnection,
    h264Decoder: H264Decoder,
    aacDecoder: AACDecoder,
    onDisconnect: @escaping @Sendable () -> Void,
    onError: @escaping @Sendable (String) -> Void,
    onDimension: @escaping @Sendable (CGSize) -> Void
) {
    // Receive header (5 bytes: 1 type + 4 length)
    connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { data, _, isComplete, error in
        if let error = error {
            print("[StreamClient] Receive error (header): \(error)")
            onError("Failed to receive header: \(error.localizedDescription)")
            onDisconnect()
            return
        }
        
        guard let headerData = data, headerData.count == 5 else {
            if isComplete {
                print("[StreamClient] Connection closed by server")
                onDisconnect()
            }
            return
        }
        
        // Parse header
        let packetTypeByte = headerData[0]
        guard let packetType = PacketType(rawValue: packetTypeByte) else {
            print("[StreamClient] Unknown packet type: \(packetTypeByte)")
            streamReceiveLoop(
                connection: connection,
                h264Decoder: h264Decoder,
                aacDecoder: aacDecoder,
                onDisconnect: onDisconnect,
                onError: onError,
                onDimension: onDimension
            )
            return
        }
        
        // Parse length (big-endian)
        let length = headerData.withUnsafeBytes { ptr -> UInt32 in
            let b1 = UInt32(ptr[1]) << 24
            let b2 = UInt32(ptr[2]) << 16
            let b3 = UInt32(ptr[3]) << 8
            let b4 = UInt32(ptr[4])
            return b1 | b2 | b3 | b4
        }
        
        guard length > 0 && length < 10_000_000 else {
            print("[StreamClient] Invalid packet length: \(length)")
            streamReceiveLoop(
                connection: connection,
                h264Decoder: h264Decoder,
                aacDecoder: aacDecoder,
                onDisconnect: onDisconnect,
                onError: onError,
                onDimension: onDimension
            )
            return
        }
        
        // Receive payload
        connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { payloadData, _, isComplete, error in
            if let error = error {
                print("[StreamClient] Receive error (payload): \(error)")
                onError("Failed to receive payload: \(error.localizedDescription)")
                onDisconnect()
                return
            }
            
            guard let payloadData = payloadData, payloadData.count == Int(length) else {
                if isComplete {
                    print("[StreamClient] Connection closed (incomplete payload)")
                    onDisconnect()
                }
                return
            }
            
            // Process packet directly - decoders are thread-safe
            streamProcessPacket(
                type: packetType,
                data: payloadData,
                h264Decoder: h264Decoder,
                aacDecoder: aacDecoder,
                onDimension: onDimension
            )
            
            // Continue receiving
            streamReceiveLoop(
                connection: connection,
                h264Decoder: h264Decoder,
                aacDecoder: aacDecoder,
                onDisconnect: onDisconnect,
                onError: onError,
                onDimension: onDimension
            )
        }
    }
}

/// Process packet directly on network queue
private func streamProcessPacket(
    type: PacketType,
    data: Data,
    h264Decoder: H264Decoder,
    aacDecoder: AACDecoder,
    onDimension: @escaping @Sendable (CGSize) -> Void
) {
    switch type {
    case .config:
        print("[StreamClient] Received CONFIG packet (\(data.count) bytes)")
        h264Decoder.processConfig(data: data)

    case .video:
        h264Decoder.decode(data: data)

    case .audio:
        aacDecoder.decode(data: data)

    case .audioConfig:
        print("[StreamClient] Received AUDIO_CONFIG packet (\(data.count) bytes)")
        aacDecoder.setAudioSpecificConfig(data: data)
        
    case .dimension:
        guard data.count == 8 else {
            print("[StreamClient] Invalid DIMENSION packet size: \(data.count)")
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
        
        onDimension(newDimensions)
        h264Decoder.prepareForDimensionChange(newDimensions: newDimensions)
    }
}

// MARK: - StreamClient

/// Low-latency network client
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
    
    // Dedicated high-priority queue for network operations
    private let networkQueue = DispatchQueue(
        label: "com.screenreflect.network",
        qos: .userInteractive
    )

    // MARK: - Initialization

    init(device: DiscoveredDevice, h264Decoder: H264Decoder, aacDecoder: AACDecoder) {
        self.device = device
        self.h264Decoder = h264Decoder
        self.aacDecoder = aacDecoder
    }

    // MARK: - Connection Management

    /// Connect to the Android device
    func connect() {
        if isConnected && connection != nil {
            print("[StreamClient] Already connected")
            return
        }

        if connection != nil {
            print("[StreamClient] Cleaning up existing connection before reconnect")
            disconnect()
        }

        print("[StreamClient] Connecting to \(device.hostName):\(device.port)")

        // Reset decoders for clean state
        h264Decoder.reset()
        aacDecoder.reset()

        let host = NWEndpoint.Host(device.hostName)
        let port = NWEndpoint.Port(integerLiteral: UInt16(device.port))

        // Configure TCP for ultra-low-latency
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3
        tcpOptions.noDelay = true  // CRITICAL: Disable Nagle's algorithm

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.serviceClass = .responsiveData

        let newConnection = NWConnection(host: host, port: port, using: parameters)
        connection = newConnection
        
        // Capture decoders for use in callbacks
        let videoDecoder = h264Decoder
        let audioDecoder = aacDecoder

        // State handler
        newConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[StreamClient] Connection ready")
                Task { @MainActor in
                    self?.isConnected = true
                    self?.connectionError = nil
                }
                // Start receiving packets using standalone function
                streamReceiveLoop(
                    connection: newConnection,
                    h264Decoder: videoDecoder,
                    aacDecoder: audioDecoder,
                    onDisconnect: { Task { @MainActor in self?.disconnect() } },
                    onError: { error in Task { @MainActor in self?.connectionError = error } },
                    onDimension: { dims in Task { @MainActor in self?.videoDimensions = dims } }
                )

            case .waiting(let error):
                print("[StreamClient] Connection waiting: \(error)")
                Task { @MainActor in
                    self?.connectionError = error.localizedDescription
                }

            case .failed(let error):
                print("[StreamClient] Connection failed: \(error)")
                Task { @MainActor in
                    self?.isConnected = false
                    self?.connectionError = error.localizedDescription
                }

            case .cancelled:
                print("[StreamClient] Connection cancelled")
                Task { @MainActor in
                    self?.isConnected = false
                }

            default:
                break
            }
        }

        // Start connection on dedicated network queue
        newConnection.start(queue: networkQueue)
    }

    /// Disconnect from the device
    func disconnect() {
        print("[StreamClient] Disconnecting...")
        connection?.cancel()
        connection = nil
        isConnected = false
        connectionError = nil
        print("[StreamClient] Disconnected")
    }
}
