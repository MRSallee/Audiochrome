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

        let written = ProfileWriter.apoText(for: linked)
        let roundTrip = try ProfileParser.parse(written, name: "round-trip")
        check("writer round-trip preamp", abs((roundTrip.linked?.preampDB ?? 0) - (-2.8847)) < 0.0001)
        check("writer round-trip count", roundTrip.linked?.filters.count == 2)
        check("writer round-trip Fc", roundTrip.linked?.filters.first?.frequencyHz == 31)

        let fresh = EQProfile.makeNew()
        check("new profile name", fresh.name == "New Profile")
        check("new profile one PK", fresh.linked?.filters.count == 1 && fresh.linked?.filters.first?.kind == .peaking)
        check("new profile Q 1", fresh.linked?.filters.first?.q == 1)
        check("new profile 1 kHz", fresh.linked?.filters.first?.frequencyHz == 1_000)
        let freshRoundTrip = try ProfileParser.parse(ProfileWriter.apoText(for: fresh), name: fresh.name)
        check("new profile writes", freshRoundTrip.linked?.filters.first?.kind == .peaking)

        check(
            "squig empty is sandbox",
            SquiglinkURL.editorURL(filters: []).absoluteString
                == "https://squig.link/?eqModel=_EQ_Sandbox"
        )
        let emptyPK = EQFilter(enabled: true, kind: .peaking, frequencyHz: 0, gainDB: 0, q: 0)
        let squigExample = [
            EQFilter(enabled: true, kind: .lowShelf, frequencyHz: 196, gainDB: 7.8, q: 1),
            emptyPK, emptyPK, emptyPK, emptyPK
        ]
        check(
            "squig eqFilters v2 example",
            SquiglinkURL.editorURL(filters: squigExample).absoluteString
                == "https://squig.link/?eqModel=_EQ_Sandbox&eqFilters=djI7MCwxLDE5NiwxLDcuODswLDAsMCwwLDA7MCwwLDAsMCwwOzAsMCwwLDAsMDswLDAsMCwwLDA"
        )
        check(
            "squig skips hidden LP",
            SquiglinkURL.editorURL(
                filters: [EQFilter(enabled: true, kind: .lowPass, frequencyHz: 80, gainDB: 0, q: 0.7)]
            ).absoluteString == "https://squig.link/?eqModel=_EQ_Sandbox"
        )

        var snapshot = AppConfig()
        snapshot.openAtLogin = true
        snapshot.animatedMenuBarIcon = false
        snapshot.activeEQReminders = false
        snapshot.customEQPerDevice = true
        snapshot.profileColors = ["Oratory.txt": "#FF00AA"]
        snapshot.knownOutputs["uid-1"] = KnownOutput(
            identityKey: "uid-1",
            uid: "uid-1",
            name: "Speakers",
            displayName: "Desk",
            transport: "Built-in",
            lastSeen: Date(timeIntervalSinceReferenceDate: 100)
        )
        snapshot.outputs["uid-1"] = OutputMapping(
            enabled: true,
            profileFilename: "Oratory.txt",
            colorHex: "#FF00AA",
            profilesDirectoryPath: "/tmp/eq"
        )
        let encoded = try ConfigStore.encode(snapshot)
        let decoded = try ConfigStore.decode(encoded)
        check("config encode round-trip", decoded == snapshot)
        check("config export includes colors", decoded.profileColors["Oratory.txt"] == "#FF00AA")
        check("config export includes folder", decoded.outputs["uid-1"]?.profilesDirectoryPath == "/tmp/eq")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiochrome-config-smoke.json")
        try encoded.write(to: tmp)
        let fromFile = try ConfigStore.load(from: tmp)
        check("config file round-trip", fromFile == snapshot)
        try? FileManager.default.removeItem(at: tmp)
        do {
            _ = try ConfigStore.decode(Data("{not-a-config".utf8))
            check("invalid config throws", false)
        } catch {
            check("invalid config throws", true)
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
