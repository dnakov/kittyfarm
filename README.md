<p align="center">
  <img src="kittyfarm.png" width="128" />
</p>

<h1 align="center">KittyFarm</h1>

<p align="center">Run iOS Simulators and Android Emulators side-by-side on your Mac.</p>

---

KittyFarm is a macOS app that lets you view and control multiple simulators and emulators from a single window. Touch input on one device can be replicated to all others simultaneously.

### Features

- Live display of iOS Simulators (via private SimulatorKit APIs — no screen recording permission needed) and Android Emulators (via gRPC)
- Touch replication across devices
- Device bezels rendered from Apple's CoreSimulator chrome assets and Android SDK skins
- Build & Play: build your iOS/Android project and deploy to all devices in parallel
- Drag-and-drop device reordering
- Proportional layout that scales devices to fill available space

### Requirements

- macOS 26+
- Xcode 17+
- Android SDK (for emulator support)

### Building

The Xcode project is generated from `project.yml` using [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
xcodebuild -project KittyFarm.xcodeproj -scheme KittyFarm -configuration Debug build
```

### License

MIT
