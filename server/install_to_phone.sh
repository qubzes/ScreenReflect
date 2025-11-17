#!/bin/bash

echo "🔍 Checking for connected devices..."
adb devices

# Count non-emulator devices
DEVICE_COUNT=$(adb devices | grep -v "emulator" | grep "device$" | wc -l)

if [ $DEVICE_COUNT -eq 0 ]; then
    echo ""
    echo "❌ No physical phone detected!"
    echo ""
    echo "📱 Please make sure:"
    echo "  1. USB Debugging is enabled on your phone"
    echo "  2. Phone is connected via USB"
    echo "  3. You tapped 'Allow' on the USB debugging popup"
    echo ""
    echo "Then run this script again: ./install_to_phone.sh"
    exit 1
fi

echo ""
echo "✅ Phone detected!"
echo ""
echo "📦 Installing Screen Reflect app..."
./gradlew installDebug

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ App installed successfully!"
    echo ""
    echo "📱 Next steps:"
    echo "  1. Open 'Screen Reflect' app on your phone"
    echo "  2. Tap 'Start Streaming'"
    echo "  3. On your Mac, open Screen Reflect from menu bar"
    echo "  4. Your phone should appear automatically (if on same WiFi)"
    echo ""
    echo "💡 If auto-discovery doesn't work:"
    echo "  - Make sure both phone and Mac are on the SAME WiFi network"
    echo "  - Check that your WiFi allows device-to-device communication"
    echo "  - Some public/corporate WiFi networks block mDNS discovery"
else
    echo ""
    echo "❌ Installation failed. Please check the errors above."
fi
