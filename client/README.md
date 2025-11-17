# Screen Reflect - macOS Client

A minimalist, App Store-compliant macOS menu bar application for mirroring Android devices running the Screen Reflect server.

## Features

- **100% App Store Compliant**: Fully sandboxed with proper entitlements
- **Native Performance**: Uses VideoToolbox for H.264 decoding and CoreAudio for AAC audio
- **Zero External Dependencies**: No bundled binaries (ffmpeg, adb, etc.)
- **Automatic Discovery**: Finds Android devices via Bonjour/mDNS
- **Menu Bar Utility**: Minimal UI that lives in the menu bar
- **Hardware Acceleration**: Metal-accelerated video rendering via AVSampleBufferDisplayLayer

## Architecture

### Core Components

1. **BonjourBrowser.swift** - Service discovery using NetServiceBrowser
2. **StreamClient.swift** - TCP connection and custom protocol parser
3. **H264Decoder.swift** - VideoToolbox-based H.264 decoder
4. **AACDecoder.swift** - CoreAudio-based AAC decoder and player
5. **VideoPlayerView.swift** - High-performance video rendering
6. **ScreenReflectApp.swift** - Menu bar application entry point
7. **ContentView.swift** - Device list UI

### Custom Network Protocol

The Android server sends data over TCP using this format:

```
[1 byte: PACKET_TYPE][4 bytes: DATA_LENGTH (big-endian)][N bytes: DATA_PAYLOAD]
```

**Packet Types:**
- `0x00` - CONFIG: H.264 SPS/PPS configuration
- `0x01` - VIDEO: H.264 video frame (Annex B format)
- `0x02` - AUDIO: AAC audio frame

### Video Pipeline

1. Android sends H.264 frames in Annex B format (0x00 0x00 0x01 start codes)
2. `H264Decoder` converts Annex B → AVCC format (4-byte length prefixes)
3. VideoToolbox decodes to CVImageBuffer
4. AVSampleBufferDisplayLayer renders with hardware acceleration

### Audio Pipeline

1. Android sends raw AAC frames
2. `AACDecoder` enqueues frames to AudioQueue
3. CoreAudio handles decompression and playback

## Project Structure

```
ScreenReflect/
├── ScreenReflect.xcodeproj/
│   └── project.pbxproj
├── ScreenReflect/
│   ├── Info.plist
│   ├── ScreenReflect.entitlements
│   ├── ScreenReflectApp.swift
│   ├── ContentView.swift
│   ├── BonjourBrowser.swift
│   ├── StreamClient.swift
│   ├── H264Decoder.swift
│   ├── AACDecoder.swift
│   ├── VideoPlayerView.swift
│   ├── Assets.xcassets/
│   └── Preview Content/
└── README.md
```

## App Sandbox Configuration

### Entitlements (ScreenReflect.entitlements)

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

### Info.plist Keys

```xml
<key>LSUIElement</key>
<true/>  <!-- Menu bar utility, no Dock icon -->

<key>NSLocalNetworkUsageDescription</key>
<string>Screen Reflect needs to find and connect to your Android devices on the local network.</string>

<key>NSBonjourServices</key>
<array>
    <string>_screenreflect._tcp.</string>
</array>
```

## Building

### Requirements

- macOS 13.0 or later
- Xcode 15.0 or later
- Swift 5.9 or later

### Build Steps

1. Open `ScreenReflect.xcodeproj` in Xcode
2. Select a development team in Signing & Capabilities
3. Build and run (⌘R)

The app will appear in the menu bar with a display icon.

## Usage

1. **Start the Android Server**: Run Screen Reflect on your Android device
2. **Launch the App**: The menu bar icon will appear
3. **Select Device**: Click the menu bar icon to see discovered devices
4. **Start Mirroring**: Click a device to open the player window

### Keyboard Shortcuts

- Click menu bar icon to show/hide device list
- Close player window to disconnect

## Technical Details

### Sandbox Compliance

This app is designed to pass App Store review by:

- Using only Apple frameworks (no external binaries)
- Proper sandbox entitlements
- Network access limited to client connections
- No use of private APIs or Process spawning
- User-facing privacy descriptions

### Performance Optimizations

- **Hardware Decoding**: VideoToolbox uses GPU acceleration
- **Zero-Copy Rendering**: CVImageBuffer → AVSampleBufferDisplayLayer
- **Async I/O**: Network.framework with non-blocking receive
- **Metal Integration**: Display layer uses Metal for composition

### Known Limitations

- **No A/V Sync**: Audio and video are played independently (MVP limitation)
- **No Recording**: App only displays the stream in real-time
- **No Controls**: No pause/resume (designed for live mirroring only)

## Troubleshooting

### No Devices Found

1. Ensure both Mac and Android are on the same network
2. Check that the Android app is running and advertising via mDNS
3. Verify the service type matches: `_screenreflect._tcp.`
4. Grant network permissions when prompted

### Video Not Displaying

1. Check that CONFIG packet (SPS/PPS) is received first
2. Verify H.264 frames are in Annex B format
3. Check Xcode console for decoder errors

### Audio Not Playing

1. Verify AAC frames are valid
2. Check system audio output settings
3. Ensure sample rate matches (default: 48kHz)

## Protocol Compatibility

The Android server must:

1. Advertise via Bonjour as `_screenreflect._tcp.`
2. Accept TCP connections on the advertised port
3. Send packets in the documented format
4. Send CONFIG packet before VIDEO packets
5. Use H.264 Baseline or Main profile
6. Use AAC-LC audio codec

## App Store Submission Checklist

- ✅ Fully sandboxed
- ✅ No external binaries
- ✅ Privacy descriptions in Info.plist
- ✅ Proper entitlements for network access
- ✅ Code signed with valid Developer ID
- ✅ Uses only public Apple frameworks
- ✅ No Process or shell command execution

## License

This implementation is provided as a reference architecture for building App Store-compliant screen mirroring applications.

## Credits

Built with:
- SwiftUI for UI
- VideoToolbox for H.264 decoding
- AVFoundation for video rendering
- AudioToolbox for AAC playback
- Network.framework for modern TCP I/O
- Foundation NetService for Bonjour discovery
