import AppKit
import CoreAudio
import MetalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: VisualizerPanel!
    private var editMode = false

    private let audioTap = SystemAudioTap()
    private var analyzer: AudioAnalyzer?
    private var renderer: GeometricRenderer?
    private let mtkView = MTKView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = VisualizerPanel()
        panel.embedVisualization(mtkView)
        panel.orderFrontRegardless()

        setupStatusItem()
        startAudioPipeline()
    }

    private func startAudioPipeline() {
        do {
            try audioTap.start()
        } catch {
            print("[SystemAudioTap] FAILED to start: \(error)")
            return
        }

        let analyzer = AudioAnalyzer(sampleRate: audioTap.format.mSampleRate)
        self.analyzer = analyzer

        let channels = Int(audioTap.format.mChannelsPerFrame)
        audioTap.onBuffer = { [weak analyzer] bufferList, _ in
            analyzer?.ingest(monoSamples: Self.monoSamples(from: bufferList, channels: channels))
        }

        renderer = GeometricRenderer(mtkView: mtkView, analyzer: analyzer)
        if renderer == nil {
            print("[GeometricRenderer] failed to initialize — no Metal device/pipeline?")
        }
    }

    private static func monoSamples(from bufferList: AudioBufferList, channels: Int) -> [Float] {
        var buffers = bufferList
        let abl = UnsafeMutableAudioBufferListPointer(&buffers)
        guard let buffer = abl.first, let mData = buffer.mData else { return [] }

        let totalFloats = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard totalFloats > 0 else { return [] }
        let floatPtr = mData.bindMemory(to: Float.self, capacity: totalFloats)

        guard channels > 1 else {
            return Array(UnsafeBufferPointer(start: floatPtr, count: totalFloats))
        }

        let frameCount = totalFloats / channels
        var mono = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            var sum: Float = 0
            for c in 0..<channels { sum += floatPtr[i * channels + c] }
            mono[i] = sum / Float(channels)
        }
        return mono
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        audioTap.stop()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "Music Visualizer"
            )
        }

        let menu = NSMenu()

        let editItem = NSMenuItem(
            title: "Edit Mode (Move / Resize)",
            action: #selector(toggleEditMode(_:)),
            keyEquivalent: ""
        )
        editItem.target = self
        menu.addItem(editItem)

        let allSpacesItem = NSMenuItem(
            title: "Show on All Spaces & Full Screen",
            action: #selector(toggleAllSpaces(_:)),
            keyEquivalent: ""
        )
        allSpacesItem.target = self
        allSpacesItem.state = .on
        menu.addItem(allSpacesItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    @objc private func toggleEditMode(_ sender: NSMenuItem) {
        editMode.toggle()
        sender.state = editMode ? .on : .off
        panel.setEditMode(editMode)
    }

    @objc private func toggleAllSpaces(_ sender: NSMenuItem) {
        let enabled = sender.state == .off
        sender.state = enabled ? .on : .off
        panel.setJoinsAllSpaces(enabled)
    }
}
