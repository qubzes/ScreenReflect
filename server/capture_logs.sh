#!/bin/bash

# Clear old logs
adb logcat -c

# Create log file with timestamp
LOGFILE="screenreflect_logs_$(date +%Y%m%d_%H%M%S).txt"

echo "Capturing logs to $LOGFILE"
echo "Press Ctrl+C to stop"
echo "----------------------------------------"

# Capture logs and save to file
adb logcat | grep -E "(AudioEncoder|VideoEncoder|MediaCaptureService|NetworkServer|H264Decoder|AACDecoder|StreamClient)" | tee "$LOGFILE"
