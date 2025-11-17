# Screen Reflect - Android Server

A minimalist Android application that streams screen content and internal audio to macOS devices on the local network.

## Features

- **Real-time Screen Capture**: Captures device screen using MediaProjection API
- **Internal Audio Capture**: Captures app audio using AudioPlaybackCapture API
- **H.264 Video Encoding**: Hardware-accelerated video encoding via MediaCodec
- **AAC Audio Encoding**: Efficient audio encoding for streaming
- **Automatic Discovery**: Advertises service via mDNS/Bonjour for zero-configuration networking
- **Custom Protocol**: Efficient multiplexed stream for audio/video synchronization
- **Foreground Service**: Reliable background streaming with persistent notification
- **Minimalist UI**: Single-screen Material 3 interface

## Requirements

- **Android 10 (API 29)** or higher
- **Permissions**:
  - RECORD_AUDIO - Required for internal audio capture
  - FOREGROUND_SERVICE - For persistent streaming service
  - FOREGROUND_SERVICE_MEDIA_PROJECTION - Required on Android 14+
  - INTERNET, ACCESS_NETWORK_STATE, ACCESS_WIFI_STATE - For networking
  - POST_NOTIFICATIONS - For notification on Android 13+

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  MainActivity                        │
│  (Requests permissions & starts service)            │
└──────────────────┬──────────────────────────────────┘
                   │
                   ↓
┌─────────────────────────────────────────────────────┐
│             MediaCaptureService                      │
│         (Foreground Service)                         │
└──────┬──────┬──────┬──────┬─────────────────────────┘
       │      │      │      │
       ↓      ↓      ↓      ↓
   ┌──────┐ ┌────────┐ ┌────────┐ ┌─────────┐
   │Video │ │ Audio  │ │Network │ │   NSD   │
   │Encode│ │ Encode │ │ Server │ │ Helper  │
   └──────┘ └────────┘ └────────┘ └─────────┘
       │      │           │            │
       └──────┴───────────┘            │
              │                        │
              ↓                        ↓
      TCP Stream (Custom Protocol)   mDNS Advertisement
```

## Components

### 1. MediaCaptureService
**Location**: `service/MediaCaptureService.kt`

Foreground service that coordinates all streaming components:
- Manages MediaProjection lifecycle
- Starts/stops encoders and network components
- Handles user permission revocation
- Displays persistent notification

### 2. VideoEncoder
**Location**: `capture/VideoEncoder.kt`

Captures and encodes screen content:
- Creates VirtualDisplay from MediaProjection
- Encodes to H.264 using MediaCodec
- Sends SPS/PPS config and video frames to NetworkServer
- **Configuration**:
  - Resolution: 1280x720
  - Frame rate: 30 FPS
  - Bitrate: 2 Mbps
  - Codec: H.264 (AVC)

### 3. AudioEncoder
**Location**: `capture/AudioEncoder.kt`

Captures and encodes internal audio:
- Uses AudioPlaybackCaptureConfiguration for internal audio
- Encodes to AAC using MediaCodec
- **Configuration**:
  - Sample rate: 48kHz
  - Channels: Stereo
  - Bitrate: 128 kbps
  - Codec: AAC-LC

### 4. NetworkServer
**Location**: `network/NetworkServer.kt`

TCP server with custom multiplexing protocol:
- Binds to available port (OS-assigned)
- Accepts single client connection
- **Custom Protocol**:
  ```
  [1 byte: Type][4 bytes: Length (BE)][N bytes: Data]

  Types:
  0x00 = CONFIG (H.264 SPS/PPS)
  0x01 = VIDEO (H.264 frame)
  0x02 = AUDIO (AAC frame)
  ```

### 5. NsdHelper
**Location**: `network/NsdHelper.kt`

Advertises service on local network:
- Service type: `_screenreflect._tcp.`
- Service name: "Screen Reflect - [Device Model]"
- Allows macOS client to auto-discover

## Custom Network Protocol

### Packet Structure

Every packet sent follows this format:

```
┌──────────────┬──────────────────┬────────────────────┐
│ Packet Type  │   Data Length    │   Data Payload     │
│   (1 byte)   │   (4 bytes BE)   │   (N bytes)        │
└──────────────┴──────────────────┴────────────────────┘
```

### Packet Types

| Type | Value | Description | When Sent |
|------|-------|-------------|-----------|
| CONFIG | 0x00 | H.264 SPS/PPS | Once at start, before video frames |
| VIDEO | 0x01 | H.264 NAL unit | Continuously, 30fps |
| AUDIO | 0x02 | AAC frame | Continuously |

### Example Packet Flow

```
1. CONFIG: [0x00][0x00 0x00 0x00 0x32][SPS+PPS data...]
2. VIDEO:  [0x01][0x00 0x00 0x3B 0xA4][H.264 frame...]
3. AUDIO:  [0x02][0x00 0x00 0x02 0x00][AAC frame...]
4. VIDEO:  [0x01][0x00 0x00 0x3C 0x12][H.264 frame...]
5. AUDIO:  [0x02][0x00 0x00 0x02 0x00][AAC frame...]
...
```

## Building and Running

### Prerequisites

- Android Studio Hedgehog (2023.1.1) or later
- Android SDK 34
- Kotlin 1.9.20+

### Build Steps

1. **Open Project**:
   ```bash
   cd ScreenReflectAndroid
   # Open in Android Studio or build from command line
   ```

2. **Build APK**:
   ```bash
   ./gradlew assembleDebug
   ```

3. **Install on Device**:
   ```bash
   ./gradlew installDebug
   ```

### Running

1. Launch "Screen Reflect" app on Android device
2. Tap "Start Streaming"
3. Grant permissions:
   - Screen capture (system prompt)
   - Audio recording (if not already granted)
   - Notifications (Android 13+)
4. Notification appears: "Streaming to network"
5. macOS client can now discover and connect

## Permissions Flow

```
User taps "Start Streaming"
         ↓
Check RECORD_AUDIO permission
         ↓
    [Not granted]  →  Request permission  →  [Granted]
         ↓
Request Screen Capture via MediaProjectionManager
         ↓
User approves in system dialog
         ↓
Service starts with MediaProjection token
```

## Usage

### Starting Stream

1. Ensure Android device and macOS are on same WiFi network
2. Open Screen Reflect on Android
3. Tap "Start Streaming"
4. Approve screen capture permission
5. Service starts and advertises on network

### Stopping Stream

**Method 1**: Tap "Stop Streaming" in app

**Method 2**: Tap "Stop" in notification

**Method 3**: Revoke screen capture from quick settings

All methods properly clean up resources.

## Troubleshooting

### "Service crashes on start"

**Cause**: Missing `FOREGROUND_SERVICE_MEDIA_PROJECTION` permission

**Fix**: Verify AndroidManifest.xml includes:
```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION" />
<service android:foregroundServiceType="mediaProjection" />
```

### "Audio not capturing"

**Cause**: Permission not granted or incompatible audio source

**Fix**:
- Ensure RECORD_AUDIO permission is granted
- Some apps may block audio capture (DRM-protected content)

### "macOS client can't find device"

**Cause**: NSD not advertising or network issue

**Fix**:
- Check both devices on same network
- Verify service type: `_screenreflect._tcp.`
- Check Android logs: `adb logcat -s NsdHelper`

### "Stream is laggy"

**Possible causes**:
- Network congestion
- Device CPU limitations
- Low WiFi signal

**Solutions**:
- Reduce resolution in VideoEncoder (change `width` and `height`)
- Lower bitrate (change `BIT_RATE`)
- Move devices closer to WiFi router

## Performance Optimization

### Video Quality vs Performance

Edit `VideoEncoder.kt`:

```kotlin
// Lower quality, better performance
private val width: Int = 960
private val height: Int = 540
private val BIT_RATE = 1_500_000  // 1.5 Mbps

// Higher quality, more CPU/network
private val width: Int = 1920
private val height: Int = 1080
private val BIT_RATE = 4_000_000  // 4 Mbps
```

### Audio Quality

Edit `AudioEncoder.kt`:

```kotlin
// Lower quality
private const val BIT_RATE = 96_000   // 96 kbps
private const val SAMPLE_RATE = 44100 // 44.1kHz

// Higher quality
private const val BIT_RATE = 256_000  // 256 kbps
private const val SAMPLE_RATE = 48000 // 48kHz
```

## Testing

### Unit Tests

```bash
./gradlew test
```

### Integration Tests

```bash
./gradlew connectedAndroidTest
```

### Manual Testing

1. **Service Lifecycle**: Start/stop multiple times
2. **Permission Revocation**: Revoke screen capture from quick settings
3. **Network Interruption**: Disable/enable WiFi during streaming
4. **Low Memory**: Stream while running other apps
5. **Different Networks**: Test on different WiFi networks

## Logs and Debugging

### View Logs

```bash
# All logs
adb logcat

# Filtered by component
adb logcat -s MediaCaptureService VideoEncoder AudioEncoder NetworkServer NsdHelper

# Video encoder only
adb logcat -s VideoEncoder:V *:S
```

### Key Log Messages

```
[MediaCaptureService] Screen mirroring started successfully
[VideoEncoder] Video encoder configured: 1280x720 @ 30fps
[AudioEncoder] Audio capture configured: 48000 Hz, 2 channels
[NetworkServer] Server started on port 45123
[NsdHelper] Service registered: Screen Reflect - Pixel 7
```

## Known Limitations

1. **Single Client**: Only one macOS client can connect at a time
2. **Same Network**: Devices must be on same WiFi (no internet streaming)
3. **No A/V Sync**: Audio and video streams are independent (MVP limitation)
4. **DRM Content**: Some apps block audio/video capture
5. **Android 10+**: MediaProjection improvements require API 29+

## Security Considerations

- Service only accepts local network connections
- No authentication required (local network trust model)
- Screen capture permission required from user
- All data transmitted in cleartext (local network only)

## Future Enhancements

- [ ] Multi-client support
- [ ] Quality settings in UI
- [ ] Connection encryption (TLS)
- [ ] Presentation timestamps for A/V sync
- [ ] Adaptive bitrate based on network conditions
- [ ] Recording to file option

## License

See main project LICENSE file.

## Credits

Built with:
- Kotlin & Jetpack Compose for UI
- MediaProjection API for screen capture
- MediaCodec for hardware encoding
- AudioPlaybackCapture for internal audio
- NsdManager for service discovery
