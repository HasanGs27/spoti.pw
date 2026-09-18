// Compile together with NativeAudioResolver / NativeYouTubeLocal / Resources.
// Default: offline deterministic checks. --live: one public song, local extraction.
import Foundation
import Darwin

actor NativeAudioSmokeLog {
    private(set) var queries: [String] = []
    private(set) var extracted: [String] = []
    func search(_ query: String) { queries.append(query) }
    func extract(_ id: String) -> Int { extracted.append(id); return extracted.count }
}

@main struct NativeAudioSmoke {
    static func require(_ condition: Bool, _ description: String) {
        guard condition else { fatalError(description) }
    }
    static func checkResolverReuse(_ row: [String: Any], featured: SGNativeTrack) async throws {
        let track = try SGNativeTrack(row)
        let first = SGNativeCandidate(videoID: "G3na6eXSKtc", title: track.title, artists: track.artists, seconds: 186, audioTrack: true)
        let alternative = SGNativeCandidate(videoID: "abcdefghijk", title: track.title, artists: track.artists, seconds: 186, audioTrack: true)
        let cache = SGNativeCandidateCache(capacity: 2, lifetime: 10)
        await cache.store(first, for: track, now: 1)
        require(await cache.candidate(for: track, now: 10)?.videoID == first.videoID, "Cached identity unavailable before expiry")
        require(await cache.candidate(for: track, sourceID: alternative.videoID, now: 10) == nil, "Cache overrode an explicit source choice")
        require(await cache.candidate(for: track, now: 11) == nil, "Identity cache outlived its TTL")
        let changed = try SGNativeTrack(["title": track.title, "artist": "Other Artist", "seconds": 186])
        await cache.store(first, for: changed, now: 12)
        require(await cache.candidate(for: changed, now: 13) == nil, "Cache stored a mismatched identity")
        let secondTrack = try SGNativeTrack(["title": "Second", "artist": track.artist, "seconds": 186])
        let thirdTrack = try SGNativeTrack(["title": "Third", "artist": track.artist, "seconds": 186])
        await cache.store(first, for: track, now: 20)
        await cache.store(SGNativeCandidate(videoID: "12345678901", title: "Second", artists: track.artists, seconds: 186, audioTrack: true), for: secondTrack, now: 21)
        _ = await cache.candidate(for: track, now: 22)
        await cache.store(SGNativeCandidate(videoID: "12345678902", title: "Third", artists: track.artists, seconds: 186, audioTrack: true), for: thirdTrack, now: 23)
        require(await cache.candidate(for: secondTrack, now: 24) == nil, "Cache did not evict least recently used identity")
        require(await cache.candidate(for: track, now: 24) != nil, "Cache evicted recently used identity")

        let correctFeature = SGNativeCandidate(videoID: "9_jLl-ruToA", title: "200 MPH FT Diplo (feat. Diplo)", artists: ["Bad Bunny"], seconds: 171, audioTrack: true)
        let searchLog = NativeAudioSmokeLog()
        let fallback = try await SGNativeResolverEngine.candidates(featured) { query in
            await searchLog.search(query)
            return query.hasSuffix("Bad Bunny") ? [correctFeature] : [first]
        }
        require(fallback.first?.videoID == correctFeature.videoID, "Primary-artist fallback missed verified match")
        require(await searchLog.queries == ["200 Mph Bad Bunny, Diplo", "200 Mph Bad Bunny"], "Fallback searched redundantly or changed title")
        let successfulSearch = NativeAudioSmokeLog()
        _ = try await SGNativeResolverEngine.candidates(featured) { query in
            await successfulSearch.search(query); return [correctFeature]
        }
        require(await successfulSearch.queries.count == 1, "Successful initial search triggered fallback")
        let singleSearch = NativeAudioSmokeLog()
        _ = try await SGNativeResolverEngine.candidates(track) { query in
            await singleSearch.search(query); return []
        }
        require(await singleSearch.queries.count == 1, "Identical primary-artist query was repeated")

        let reuseCache = SGNativeCandidateCache()
        let reuseLog = NativeAudioSmokeLog()
        let search: SGNativeResolverEngine.Search = { query in await reuseLog.search(query); return [first] }
        let extract: SGNativeResolverEngine.Extract = { candidate in
            let generation = await reuseLog.extract(candidate.videoID)
            return ["sourceID": candidate.videoID, "url": "https://example.invalid/audio-\(generation)"]
        }
        let once = try await SGNativeResolverEngine.resolve(row, sourceURL: nil, cache: reuseCache, searcher: search, extractor: extract)
        let twice = try await SGNativeResolverEngine.resolve(row, sourceURL: nil, cache: reuseCache, searcher: search, extractor: extract)
        require(await reuseLog.queries.count == 1, "Verified identity did not skip repeated catalogue search")
        require(await reuseLog.extracted.count == 2, "Resolver reused an expiring audio URL")
        require(once["url"] as? String != twice["url"] as? String, "Second download did not get fresh URL")

        let replacementLog = NativeAudioSmokeLog()
        let replaced = try await SGNativeResolverEngine.resolve(row, sourceURL: nil, cache: reuseCache, searcher: { query in
            await replacementLog.search(query); return [first, alternative]
        }, extractor: { candidate in
            _ = await replacementLog.extract(candidate.videoID)
            if candidate.videoID == first.videoID { throw SGNativeFailure.http(404) }
            return ["sourceID": candidate.videoID]
        })
        require(replaced["sourceID"] as? String == alternative.videoID, "Disappeared cached source did not recover")
        require(await replacementLog.extracted == [first.videoID, alternative.videoID], "Unavailable cached identity was retried redundantly")
        require(await reuseCache.candidate(for: track)?.videoID == alternative.videoID, "Recovered identity did not replace stale cache")

        let refusedLog = NativeAudioSmokeLog()
        do {
            _ = try await SGNativeResolverEngine.resolve(row, sourceURL: nil, cache: SGNativeCandidateCache(), searcher: { query in
                await refusedLog.search(query); return [first, alternative]
            }, extractor: { candidate in
                _ = await refusedLog.extract(candidate.videoID)
                throw NSError(domain: "spoti.nativeAudio.player", code: 24, userInfo: ["sourceStatus": "LOGIN_REQUIRED:Sign in to confirm you are not a bot"])
            })
            fatalError("Refused source reported success")
        } catch { require((error as NSError).code == 33, "Source refusal was not actionable") }
        require(await refusedLog.extracted.count == 1, "Source refusal retried another recording unnecessarily")
        require(SGNativeFailure.localized(URLError(.notConnectedToInternet)).code == 30, "Offline error not distinguished")
        require(SGNativeFailure.localized(URLError(.timedOut)).code == 31, "Unreachable source not distinguished")
        require(SGNativeFailure.http(429).code == 32, "Rate limit not distinguished")
        require(SGNativeFailure.http(503).code == 34, "Temporary source outage not distinguished")
        let unknown = SGNativeFailure.localized(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "https://example.invalid/private-url"]))
        require(!unknown.localizedDescription.contains("private-url"), "Failure text leaked request details")

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await SGNativeResolverEngine.candidates(track) { _ in
                fatalError("Cancelled search contacted source")
            }
        }
        do { try await cancelled.value; fatalError("Cancelled lookup reported success") }
        catch { require(error is CancellationError, "Cancellation lost its identity") }
        let paused: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let request = SGNativeAudioRequest()
                request.finish(["success": true], error: nil) { result, error in
                    continuation.resume(returning: result == nil && error?.code == NSURLErrorCancelled)
                }
                request.cancel()
                request.finish(["success": true], error: nil) { _, _ in fatalError("Completion delivered twice") }
            }
        }
        require(paused, "Queued success survived cancellation")
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
        let featured = try SGNativeTrack(["expectedTitle": "200 Mph", "expectedArtist": "Bad Bunny, Diplo",
                                          "expectedArtists": ["Bad Bunny", "Diplo"], "expectedSeconds": 170.51])
        func featuredCandidate(_ title: String, _ artists: [String] = ["Bad Bunny"], _ seconds: Double = 171) -> SGNativeCandidate {
            SGNativeCandidate(videoID: "9_jLl-ruToA", title: title, artists: artists, seconds: seconds, audioTrack: true)
        }
        require(SGNativeMatch.accepts(featuredCandidate("200 MPH FT Diplo (feat. Diplo)"), featured), "Official repeated guest credit rejected")
        require(SGNativeMatch.accepts(featuredCandidate("200 Mph (with Diplo)"), featured), "Known bracketed guest credit rejected")
        require(SGNativeMatch.accepts(featuredCandidate("200 MPH feat. Diplo"), featured), "Known trailing guest credit rejected")
        require(!SGNativeMatch.accepts(featuredCandidate("200 Mph (feat. Other Artist)"), featured), "Unknown guest credit ignored")
        require(!SGNativeMatch.accepts(featuredCandidate("200 Mph (feat. Bad)"), featured), "Partial artist name accepted as guest credit")
        require(!SGNativeMatch.accepts(featuredCandidate("200 Mph (feat. Diplo) - Live"), featured), "Live guest version accepted")
        require(!SGNativeMatch.accepts(featuredCandidate("200 Mph (feat. Diplo Remix)"), featured), "Version hidden inside guest credit accepted")
        require(!SGNativeMatch.accepts(featuredCandidate("200 Mph Part 2 FT Diplo"), featured), "Different title with valid credit accepted")
        require(!SGNativeMatch.accepts(featuredCandidate("200 Mph FT Diplo", ["Tribute Ensemble"]), featured), "Guest credit bypassed primary artist check")
        require(!SGNativeMatch.accepts(featuredCandidate("200 Mph FT Diplo", ["Bad Bunny"], 166), featured), "Guest credit bypassed duration check")
        let spotifyCredit = try SGNativeTrack(["title": "200 Mph (feat. Diplo)", "artist": "Bad Bunny, Diplo",
                                               "expectedArtists": ["Bad Bunny", "Diplo"], "seconds": 170.51])
        require(SGNativeMatch.accepts(featuredCandidate("200 Mph", ["Bad Bunny", "Diplo"]), spotifyCredit), "Credit present only in Spotify title rejected")
        let emptyArtists = try SGNativeTrack(["title": "Bandolero", "artist": "Moha La Squale", "expectedArtists": [], "seconds": 186])
        require(SGNativeMatch.accepts(candidate(), emptyArtists), "Empty optional artists array rejected valid artist")
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
            require(results.contains(where: { $0.videoID == "9_jLl-ruToA" && SGNativeMatch.accepts($0, featured) }), "Real 200 Mph result rejected because of guest credits")
            require(!results.contains(where: { $0.videoID == "leNdpiOWMhQ" && SGNativeMatch.accepts($0, featured) }), "Real karaoke result accepted")
            let unlinkedGuest = results.first { $0.videoID == "XsgzVmsz4Q0" }
            require(unlinkedGuest?.artists == ["Aries", "Arjan"], "Unlinked guest missing or album/duration parsed as artist")
        }
        try await checkResolverReuse(expected, featured: featured)
        print("Native source identity, cache expiry, fresh streams, fallback search, cancellation and failure checks passed.")
        guard CommandLine.arguments.contains("--live") else { return }
        let result: [String: Any]
        do {
            result = try await SGNativeResolverEngine.resolve(expected, sourceURL: nil)
        } catch {
            let diagnostic = error as NSError
            print("Live extraction failed: \(diagnostic.domain):\(diagnostic.code); \(diagnostic.userInfo["sourceFailure"] ?? diagnostic.localizedDescription)")
            exit(2)
        }
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
