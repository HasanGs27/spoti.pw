// Compile together with NativeAudioResolver / NativeYouTubeLocal / Resources.
// Default: offline deterministic checks. --live: one public song, local extraction.
import Foundation

@main struct NativeAudioSmoke {
    static func require(_ condition: Bool, _ description: String) {
        guard condition else { fatalError(description) }
    }
    static func main() async throws {
        let expected: [String: Any] = ["expectedTitle": "Bandolero", "expectedArtist": "Moha La Squale", "expectedSeconds": 185.88]
        let track = try SGNativeTrack(expected)
        func candidate(_ title: String = "Bandolero", _ artist: String = "Moha La Squale", _ seconds: Double = 186, _ song: Bool = true) -> SGNativeCandidate {
            SGNativeCandidate(videoID: "G3na6eXSKtc", title: title, artists: [artist], seconds: seconds, audioTrack: song)
        }
        require(SGNativeMatch.accepts(candidate(), track), "Correct catalogue recording rejected")
        require(!SGNativeMatch.accepts(candidate("Bandolero - slowed"), track), "Wrong slowed version accepted")
        require(!SGNativeMatch.accepts(candidate("Bandolero Part 2"), track), "Longer different title accepted")
        require(!SGNativeMatch.accepts(candidate("Bandolero - Radio Edit"), track), "Different edit accepted")
        let shortTitle = try SGNativeTrack(["title": "Tu", "artist": "Moha La Squale", "seconds": 186])
        require(!SGNativeMatch.accepts(candidate("Tu m'aimes"), shortTitle), "Short title matched a different longer song")
        require(SGNativeMatch.accepts(candidate("BANDOLERO"), track), "Case normalization rejected the same title")
        require(!SGNativeMatch.accepts(candidate("Bandolero", "Other Artist"), track), "Wrong artist accepted")
        require(!SGNativeMatch.accepts(candidate("Bandolero", "Moha La Squale", 180), track), "Wrong duration accepted")
        require(!SGNativeMatch.accepts(candidate("Bandolero", "Moha La Squale", 186, false), track), "Unofficial video accepted")
        require(SGNativeMatch.sourceID(URL(string: "https://youtu.be/G3na6eXSKtc?si=abc")!) == "G3na6eXSKtc", "Share URL rejected")
        require(SGNativeMatch.sourceID(URL(string: "https://music.youtube.com/watch?v=G3na6eXSKtc&list=abc")!) == "G3na6eXSKtc", "Music URL rejected")
        require(SGNativeMatch.sourceID(URL(string: "https://youtube.com.evil.test/watch?v=G3na6eXSKtc")!) == nil, "Host spoof accepted")
        require(!SGNativeHTTP.allowed(URL(string: "http://music.youtube.com")!), "Insecure URL accepted")
        require(!SGNativeHTTP.allowed(URL(string: "https://192.168.1.1")!), "Local network URL accepted")
        require(SGNativeJSResources.source("yt_ejs_helper.js")?.contains("var jsc") == true, "Embedded solver missing")
        require(SGNativeJSResources.source("meriyah.umd.js")?.isEmpty == false, "Embedded parser missing")
        do {
            _ = try SGNativeTrack(["title": "Bandolero", "artist": "Moha", "seconds": Double.nan])
            fatalError("Nonfinite duration accepted")
        } catch {}
        if let position = CommandLine.arguments.firstIndex(of: "--fixture"), CommandLine.arguments.count > position + 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[position + 1]))
            let results = SGNativeMatch.parse(try JSONSerialization.jsonObject(with: data))
            require(results.contains(where: { $0.videoID == "G3na6eXSKtc" && SGNativeMatch.accepts($0, track) }), "Real search response not parsed")
        }
        print("Native source URL, identity, duration, variant and resource checks passed.")
        guard CommandLine.arguments.contains("--live") else { return }
        let result = try await SGNativeResolverEngine.resolve(expected, sourceURL: nil)
        guard let url = (result["url"] as? String).flatMap(URL.init(string:)) else { fatalError("Missing stream") }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await SGNativeHTTP.session.bytes(for: request)
        require((response as? HTTPURLResponse).map { [200,206].contains($0.statusCode) } == true, "Audio source did not serve bytes")
        var prefix = Data()
        for try await byte in bytes { prefix.append(byte); if prefix.count == 4096 { break } }
        require(prefix.count >= 12 && String(data: prefix.subdata(in: 4..<8), encoding: .ascii) == "ftyp", "Source did not return an MP4/M4A container")
        print("Local-only live extraction served M4A bytes; sourceID=\(result["sourceID"] ?? ""), bitrate=\(result["bitrate"] ?? 0). No audio saved.")
    }
}
