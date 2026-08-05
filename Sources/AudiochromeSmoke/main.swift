import AudiochromeCore
import Foundation

@main
struct SmokeMain {
    static func main() throws {
        var failures = 0

        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(name)")
            } else {
                print("FAIL  \(name)")
                failures += 1
            }
        }

        let linkedText = """
        Preamp: -2.8847 dB
        Filter 1: ON PK Fc 31 Hz Gain -5.6 dB Q 0.3
        Filter 2: ON PK Fc 240 Hz Gain 3.8 dB Q 1
        """
        let linked = try ProfileParser.parse(linkedText, name: "linked")
        check("linked not multi-channel", !linked.isMultiChannel)
        check("linked preamp", abs((linked.linked?.preampDB ?? 0) - (-2.8847)) < 0.0001)
        check("linked filter count", linked.linked?.filters.count == 2)
        check("linked first Fc", linked.linked?.filters.first?.frequencyHz == 31)

        let twoChannelText = """
        Channel: L
        Preamp: -2.8847 dB
        Filter 1: ON PK Fc 31 Hz Gain -5.6 dB Q 0.3

        Channel: R
        Preamp: 0.0016 dB
        Filter 1: ON PK Fc 290 Hz Gain -9.1 dB Q 1
        """
        let stereo = try ProfileParser.parse(twoChannelText, name: "stereo")
        check("stereo multi-channel", stereo.isMultiChannel)
        check("stereo L count", stereo.left?.filters.count == 1)
        check("stereo R Fc", stereo.right?.filters.first?.frequencyHz == 290)

        // Frequency-response sanity: peaking filter should hit ~gain at Fc (plus preamp).
        let perseus = """
        Preamp: -2.8847 dB
        Filter 1: ON PK Fc 240 Hz Gain 3.8 dB Q 1
        """
        let profile = try ProfileParser.parse(perseus, name: "fr")
        let dsp = EQProcessor()
        dsp.update(profile: profile, sampleRate: 44_100)
        let at240 = dsp.magnitudeDB(atFrequency: 240)
        // preamp (-2.8847) + ~3.8 at Fc ≈ +0.915
        check("FR near expected at 240 Hz", abs(at240 - 0.915) < 0.15)

        let curve = EQProcessor.frequencyResponseCurve(for: profile, pointCount: 32)
        check("FR curve point count", curve.count == 32)
        check("FR curve has variation", (curve.max() ?? 0) - (curve.min() ?? 0) > 0.5)

        do {
            _ = try ProfileParser.parse("\n\n", name: "empty")
            check("empty throws", false)
        } catch ProfileParserError.emptyFile {
            check("empty throws", true)
        } catch {
            check("empty throws", false)
        }

        // Device enumeration should not crash.
        let devices = AudioDeviceService().outputDevices()
        check("device list loads", true)
        print("info  \(devices.count) output device(s)")
        for d in devices.prefix(5) {
            print("      - \(d.name)\(d.isDefault ? " (default)" : "")")
        }

        if failures > 0 {
            fputs("\n\(failures) failure(s)\n", stderr)
            exit(1)
        }
        print("\nAll smoke checks passed.")
    }
}
