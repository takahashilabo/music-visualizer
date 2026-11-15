import Accelerate
import Foundation

struct AudioFeatures {
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var loudness: Float = 0
    var beatPulse: Float = 0
}

final class AudioFeaturesStore {
    private let lock = NSLock()
    private var current = AudioFeatures()

    func update(_ body: (inout AudioFeatures) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&current)
    }

    func snapshot() -> AudioFeatures {
        lock.lock(); defer { lock.unlock() }
        return current
    }
}

/// Holds the most recent N samples written from the (frequent, small) audio
/// callback, so the (infrequent, large) analysis step can always pull a full
/// FFT window. Not a classic producer/consumer queue — readers just want
/// "the latest window", which is all a visualizer needs.
private final class LatestWindowBuffer {
    private let lock = NSLock()
    private var storage: [Float]
    private var writeIndex = 0
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        storage = [Float](repeating: 0, count: capacity)
    }

    func write(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        for sample in samples {
            storage[writeIndex % capacity] = sample
            writeIndex += 1
        }
    }

    func readLatest(_ n: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        var result = [Float](repeating: 0, count: n)
        let start = writeIndex - n
        for i in 0..<n {
            let idx = (((start + i) % capacity) + capacity) % capacity
            result[i] = storage[idx]
        }
        return result
    }
}

/// Windowed FFT + band energies + spectral-flux beat detection over the
/// system audio tap's samples, exposed as smoothed `AudioFeatures`.
final class AudioAnalyzer {
    let features = AudioFeaturesStore()

    private let fftSize = 2048
    private let halfSize = 1024
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let hannWindow: [Float]
    private let latestWindow: LatestWindowBuffer
    private let sampleRate: Double

    private var previousMagnitudes: [Float]
    private var bassEnvelope: Float = 0
    private var midEnvelope: Float = 0
    private var trebleEnvelope: Float = 0
    private var loudnessEnvelope: Float = 0
    private var fluxEnvelope: Float = 0.0005
    private var beatPulse: Float = 0
    private var silenceGate: Float = 0

    // Each band is compared against its own long-term (seconds-scale)
    // reference level using a short-term (fraction-of-a-second) follower.
    // The two timescales must be far apart — if they track each other
    // closely the ratio just collapses to ~1 all the time (which is what
    // happened with a single fast-adapting average).
    private var bassSlow: Float = 0.0001
    private var bassFast: Float = 0.0001
    private var midSlow: Float = 0.0001
    private var midFast: Float = 0.0001
    private var trebleSlow: Float = 0.0001
    private var trebleFast: Float = 0.0001
    private var loudnessSlow: Float = 0.0001
    private var loudnessFast: Float = 0.0001

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        hannWindow = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        latestWindow = LatestWindowBuffer(capacity: fftSize * 4)
        previousMagnitudes = [Float](repeating: 0, count: halfSize)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func ingest(monoSamples: [Float]) {
        latestWindow.write(monoSamples)
    }

    /// Call once per render frame. Not thread safe with itself — only call
    /// from one (e.g. the render) thread.
    func analyze(deltaTime: Float) {
        let samples = latestWindow.readLatest(fftSize)

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))

        var imagp = [Float](repeating: 0, count: fftSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)

        windowed.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                vDSP_fft_zip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        let binHz = Float(sampleRate) / Float(fftSize)
        func bandEnergy(_ loHz: Float, _ hiHz: Float) -> Float {
            let loBin = max(1, Int(loHz / binHz))
            let hiBin = min(halfSize - 1, Int(hiHz / binHz))
            guard hiBin > loBin else { return 0 }
            var sum: Float = 0
            magnitudes.withUnsafeBufferPointer { ptr in
                vDSP_sve(ptr.baseAddress! + loBin, 1, &sum, vDSP_Length(hiBin - loBin))
            }
            return sum / Float(hiBin - loBin)
        }

        let rawBass = bandEnergy(20, 250)
        let rawMid = bandEnergy(250, 2000)
        let rawTreble = bandEnergy(2000, 12000)

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(fftSize))

        var flux: Float = 0
        for i in 0..<halfSize {
            let diff = magnitudes[i] - previousMagnitudes[i]
            if diff > 0 { flux += diff }
        }
        previousMagnitudes = magnitudes

        // A fast-adapting threshold re-calibrates to "whatever the song is
        // doing right now" within under a second, which quietly erases beat
        // salience over a long listening session (a sustained loud/busy
        // passage raises the bar until even real beats stop clearing it).
        // Slowing this to a several-second time constant keeps the bar
        // closer to a song-level average instead of a moment-level one.
        fluxEnvelope = fluxEnvelope * 0.985 + flux * 0.015
        let threshold = fluxEnvelope * 1.8 + 0.01
        if flux > threshold {
            beatPulse = 1.0
        } else {
            let decay = powf(0.0005, deltaTime)
            beatPulse *= decay
        }

        // Relative-to-recent-average energy is great for picking out
        // transients/beats, but it can't tell "loud and steady" apart from
        // "silent and steady" — both read as "no change" and settle to the
        // same resting value. So we separately track absolute loudness
        // against a fixed reference and use it as a hard gate: without it,
        // stopping the music entirely wouldn't visibly calm the visual down.
        let referenceRms: Float = 0.06
        let absoluteLoudness = min(max(rms / referenceRms, 0), 1)
        silenceGate = smooth(silenceGate, absoluteLoudness, attack: 0.6, release: 0.08)

        bassEnvelope = smooth(bassEnvelope, relativeEnergy(rawBass, slow: &bassSlow, fast: &bassFast), attack: 0.85, release: 0.3)
        midEnvelope = smooth(midEnvelope, relativeEnergy(rawMid, slow: &midSlow, fast: &midFast), attack: 0.8, release: 0.3)
        trebleEnvelope = smooth(trebleEnvelope, relativeEnergy(rawTreble, slow: &trebleSlow, fast: &trebleFast), attack: 0.8, release: 0.32)
        loudnessEnvelope = smooth(loudnessEnvelope, relativeEnergy(rms, slow: &loudnessSlow, fast: &loudnessFast), attack: 0.7, release: 0.25)

        features.update { f in
            f.bass = bassEnvelope * silenceGate
            f.mid = midEnvelope * silenceGate
            f.treble = trebleEnvelope * silenceGate
            f.loudness = absoluteLoudness
            f.beatPulse = beatPulse * silenceGate
        }
    }

    /// Compares a fast follower of `raw` (reacts within a couple of frames)
    /// against a slow follower (reacts over several seconds). Bass hits,
    /// onsets, and other transients push the fast value above the slow
    /// reference and the ratio spikes toward/above 1; quiet moments sink it
    /// toward 0. The two time constants must stay far apart, or the ratio
    /// just collapses to ~1 all the time regardless of the music.
    private func relativeEnergy(_ raw: Float, slow: inout Float, fast: inout Float) -> Float {
        if slow <= 0.0001 { slow = raw }
        slow = slow * 0.998 + raw * 0.002
        fast = fast * 0.45 + raw * 0.55
        let safeSlow = max(slow, 0.0001)
        let ratio = fast / safeSlow
        let normalized = (ratio - 0.5) / 1.3
        return min(max(normalized, 0), 1)
    }

    private func smooth(_ current: Float, _ target: Float, attack: Float, release: Float) -> Float {
        let coeff = target > current ? attack : release
        return current + (target - current) * coeff
    }
}
