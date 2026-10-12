# WSL USB Auto-Reconnect TUI 🔄

A dynamic, asynchronous Terminal UI for `usbipd-win` that provides **Persistent Auto-Reconnection** for USB devices in WSL.

If you develop on Windows using WSL and need to interact with hardware that frequently reboots, disconnects, or changes states (such as flashing an NVIDIA Jetson Orin), you know the pain of manually re-attaching the USB device over and over. **This tool solves that completely.**

## ✨ Core Feature: Auto-Reconnect (Lock Mode)
By pressing a single key, you can **"Lock"** a Target Vendor ID (VID). 
Once locked, this script runs silently in the background and guarantees that whenever the device is plugged in or finishes rebooting, it is instantly bound and attached back into your WSL environment. No manual intervention required.

### Other Features
- ⚡ **Asynchronous TUI:** Smooth, flicker-free interface. UI never freezes during USB operations.
- 🛡️ **Mutex Protection:** Safe for multiple terminals; prevents USB stack hostage situations.
- 📐 **Responsive UI:** Safely handles terminal window resizing.

## 🚀 How to Use (Jetson Orin Flashing Example)

1. Simply double-click **`Start.bat`**. (It will automatically request Administrator privileges and bypass execution policies).
2. Press the corresponding **[KEY]** (e.g., `1`) to lock your target USB device.
3. The UI will mark it as `[LOCKED]`.
4. Run your flash script inside WSL. The tool will handle everything else automatically.
5. Press `Q` or `Ctrl+C` to gracefully release devices and exit.

## Prerequisites
- Windows 11 (or Windows 10 with WSL2).
- [usbipd-win](https://github.com/dorssel/usbipd-win) installed.
- Administrator privileges.

## License
MIT License