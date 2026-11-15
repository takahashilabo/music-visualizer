import AppKit

// The same flavor of whimsical "-ing" verbs Claude Code shows while
// thinking, since that's the look the user wanted echoed here.
private let kWords = [
    "Pondering", "Noodling", "Percolating", "Ruminating", "Marinating",
    "Conjuring", "Divining", "Schlepping", "Cogitating", "Herding",
    "Vibing", "Brewing", "Tinkering", "Spelunking", "Wrangling",
    "Puzzling", "Churning", "Simmering", "Musing", "Puttering",
    "Mulling", "Synthesizing", "Untangling", "Doodling", "Wandering"
]

private let kFontFamilies = [
    "Helvetica Neue", "Avenir Next", "Futura", "Menlo", "Georgia",
    "American Typewriter", "Copperplate", "Didot", "Baskerville",
    "Courier New", "Optima", "Palatino", "Marker Felt", "Herculanum"
]

/// A transparent, click-through overlay that flashes short words in random
/// fonts/sizes/colors — timed to the beat, inspired by the kind of playful
/// kinetic-text loading indicator Claude Code shows while thinking.
final class TextOverlayView: NSView {
    private let analyzer: AudioAnalyzer
    private var timer: Timer?
    private var lastSpawn: CFTimeInterval = 0
    private var lastBeatSpawn: CFTimeInterval = 0

    init(analyzer: AudioAnalyzer) {
        self.analyzer = analyzer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .clear
        layer?.masksToBounds = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
    }

    // Never intercept clicks — this is purely decorative, regardless of
    // whether the panel is currently click-through or in Edit Mode.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func tick() {
        guard bounds.width > 4, bounds.height > 4 else { return }
        let features = analyzer.features.snapshot()
        let now = CACurrentMediaTime()

        let idleInterval: CFTimeInterval = 2.6
        let beatCooldown: CFTimeInterval = 0.45

        var shouldSpawn = false
        if features.beatPulse > 0.7, features.loudness > 0.08, now - lastBeatSpawn > beatCooldown {
            shouldSpawn = true
            lastBeatSpawn = now
        } else if features.loudness > 0.04, now - lastSpawn > idleInterval {
            shouldSpawn = true
        }

        guard shouldSpawn else { return }
        lastSpawn = now
        spawnWord(features: features)
    }

    private func spawnWord(features: AudioFeatures) {
        let word = kWords.randomElement()!
        let family = kFontFamilies.randomElement()!
        let bold = Double.random(in: 0...1) < 0.2
        let baseSize = 12 + Double(features.loudness) * 16 + Double(features.beatPulse) * 8
        let size = CGFloat(max(10, min(baseSize, 34)))

        let font = NSFontManager.shared.font(
            withFamily: family,
            traits: bold ? .boldFontMask : [],
            weight: 5,
            size: size
        ) ?? NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)

        let hue = CGFloat.random(in: 0...1)
        let saturation = min(0.3 + CGFloat(features.treble) * 0.4, 0.85)
        let color = NSColor(calibratedHue: hue, saturation: saturation, brightness: 0.9, alpha: 0.55)

        let text = NSAttributedString(string: word, attributes: [
            .font: font,
            .foregroundColor: color
        ])
        let textSize = text.size()

        let maxX = max(bounds.width - textSize.width, 1)
        let maxY = max(bounds.height - textSize.height, 1)
        let origin = CGPoint(x: CGFloat.random(in: 0...maxX), y: CGFloat.random(in: 0...maxY))

        let textLayer = CATextLayer()
        textLayer.string = text
        textLayer.frame = CGRect(origin: origin, size: CGSize(width: textSize.width + 4, height: textSize.height + 4))
        textLayer.contentsScale = window?.backingScaleFactor ?? 2.0
        textLayer.alignmentMode = .left
        textLayer.opacity = 0
        layer?.addSublayer(textLayer)

        let hold = 0.6 + Double(features.loudness) * 0.7
        textLayer.opacity = 1 // animates via CALayer's default implicit fade

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + hold) {
            textLayer.opacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + hold + 0.4) {
            textLayer.removeFromSuperlayer()
        }
    }
}
