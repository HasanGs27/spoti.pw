import Foundation

private func sgAudioError(_ code: Int, _ message: String) -> NSError {
    NSError(domain: "spoti.nativeAudio", code: code, userInfo: [NSLocalizedDescriptionKey: message])
}

// Dedicated ephemeral HTTP session: never reuse Spotify's cookies, credentials,
// cache or request interceptors. Only known public source hosts are permitted.
enum SGNativeHTTP {
    private final class Redirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard SGNativeHTTP.allowed(request.url) else { completionHandler(nil); return }
            var clean = request
            clean.httpShouldHandleCookies = false
            clean.setValue(nil, forHTTPHeaderField: "Cookie")
            clean.setValue(nil, forHTTPHeaderField: "Authorization")
            completionHandler(clean)
        }
    }
    private static let redirects = Redirects()
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 22
        config.timeoutIntervalForResource = 55
        return URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
    }()
    static func allowed(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased(), url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com") ||
               host == "googlevideo.com" || host.hasSuffix(".googlevideo.com")
    }
    static func data(from url: URL) async throws -> (Data, URLResponse) {
        try await data(for: URLRequest(url: url))
    }
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard allowed(request.url) else { throw sgAudioError(10, "Adresse de la source refusée.") }
        var clean = request
        clean.httpShouldHandleCookies = false
        clean.setValue(nil, forHTTPHeaderField: "Cookie")
        clean.setValue(nil, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: clean)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              allowed(http.url), data.count <= 8 * 1024 * 1024 else {
            throw sgAudioError(11, "La source ne répond pas correctement. Réessaie ou ajoute un fichier.")
        }
        return (data, response)
    }
}

struct SGNativeTrack {
    let title: String
    let artist: String
    let artists: [String]
    let seconds: Double
    init(_ row: [String: Any]) throws {
        title = (row["expectedTitle"] as? String ?? row["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        artist = (row["expectedArtist"] as? String ?? row["artist"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        artists = row["expectedArtists"] as? [String] ?? [artist]
        seconds = (row["expectedSeconds"] as? NSNumber ?? row["seconds"] as? NSNumber)?.doubleValue ?? 0
        guard !title.isEmpty, !artist.isEmpty, title.count <= 500, artist.count <= 500,
              seconds.isFinite, (1...1800).contains(seconds) else {
            throw sgAudioError(20, "Titre, artiste ou durée indisponibles pour vérifier le bon morceau.")
        }
    }
}

struct SGNativeCandidate {
    let videoID: String
    let title: String
    let artists: [String]
    let seconds: Double
    let audioTrack: Bool
}

enum SGNativeMatch {
    static func words(_ value: String) -> Set<String> {
        let text = value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        return Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
    static func accepts(_ result: SGNativeCandidate, _ track: SGNativeTrack) -> Bool {
        let title = words(track.title)
        let artist = words(track.artists.first ?? track.artist)
        let actualTitle = words(result.title)
        let variants: Set<String> = ["live", "cover", "remix", "slowed", "sped", "reverb", "instrumental", "karaoke", "acoustic", "remaster", "remastered"]
        return result.audioTrack && !title.isEmpty && !artist.isEmpty && result.seconds.isFinite &&
            abs(result.seconds - track.seconds) <= max(2, track.seconds * 0.012) &&
            title == actualTitle && artist.isSubset(of: words(result.artists.joined(separator: " "))) &&
            actualTitle.intersection(variants).subtracting(title.intersection(variants)).isEmpty
    }
    static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }
    static func sourceID(_ url: URL) -> String? {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return nil }
        let value: String?
        if host == "youtu.be" { value = url.path.split(separator: "/").first.map(String.init) }
        else if ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"].contains(host), url.path == "/watch" {
            value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value
        } else { value = nil }
        return value.flatMap { validID($0) ? $0 : nil }
    }
    private static func nested(_ object: [String: Any], _ path: [String]) -> Any? {
        var cursor: Any = object
        for key in path { guard let next = (cursor as? [String: Any])?[key] else { return nil }; cursor = next }
        return cursor
    }
    private static func runs(_ column: [String: Any]) -> [[String: Any]] {
        nested(column, ["musicResponsiveListItemFlexColumnRenderer", "text", "runs"]) as? [[String: Any]] ?? []
    }
    private static func duration(_ text: String) -> Double? {
        guard text.range(of: "^[0-9]{1,2}:[0-5][0-9](?::[0-5][0-9])?$", options: .regularExpression) != nil else { return nil }
        return text.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
    }
    static func parse(_ object: Any) -> [SGNativeCandidate] {
        var rows: [SGNativeCandidate] = []
        var seen = Set<String>()
        func walk(_ node: Any, _ depth: Int) {
            guard depth < 30, rows.count < 60 else { return }
            if let dictionary = node as? [String: Any] {
                if let row = dictionary["musicResponsiveListItemRenderer"] as? [String: Any],
                   let columns = row["flexColumns"] as? [[String: Any]], !columns.isEmpty {
                    let titleRuns = runs(columns[0])
                    let title = titleRuns.compactMap { $0["text"] as? String }.joined()
                    let endpoint = titleRuns.compactMap { nested($0, ["navigationEndpoint", "watchEndpoint"]) as? [String: Any] }.first
                    let videoID = endpoint?["videoId"] as? String ?? nested(row, ["playlistItemData", "videoId"]) as? String ?? ""
                    let type = endpoint.flatMap { nested($0, ["watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType"]) as? String }
                    let detailRuns = columns.dropFirst().flatMap(runs)
                    let artists = detailRuns.compactMap { run -> String? in
                        let type = nested(run, ["navigationEndpoint", "browseEndpoint", "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType"]) as? String
                        return type == "MUSIC_PAGE_TYPE_ARTIST" ? run["text"] as? String : nil
                    }
                    let seconds = detailRuns.compactMap { ($0["text"] as? String).flatMap(duration) }.first
                    if validID(videoID), !title.isEmpty, !artists.isEmpty, let seconds, seen.insert(videoID).inserted {
                        rows.append(SGNativeCandidate(videoID: videoID, title: title, artists: artists, seconds: seconds, audioTrack: type == "MUSIC_VIDEO_TYPE_ATV"))
                    }
                    return
                }
                for child in dictionary.values { walk(child, depth + 1) }
            } else if let array = node as? [Any] { for child in array { walk(child, depth + 1) } }
        }
        walk(object, 0)
        return rows
    }
}

enum SGNativeResolverEngine {
    static func candidates(_ track: SGNativeTrack) async throws -> [SGNativeCandidate] {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "yyyyMMdd"
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.\(date.string(from: Date())).01.00", "hl": "en"]],
            "query": "\(track.title) \(track.artist)",
            "params": "EgWKAQIIAUICCAFqDBAOEAoQAxAEEAkQBQ%3D%3D"
        ]
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/search?alt=json")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        let (data, _) = try await SGNativeHTTP.data(for: request)
        let results = SGNativeMatch.parse(try JSONSerialization.jsonObject(with: data))
        return results.filter { SGNativeMatch.accepts($0, track) }.sorted {
            abs($0.seconds - track.seconds) < abs($1.seconds - track.seconds)
        }
    }

    static func resolve(_ row: [String: Any], sourceURL: URL?) async throws -> [String: Any] {
        let track = try SGNativeTrack(row)
        let chosenID = try sourceURL.map { source -> String in
            guard let value = SGNativeMatch.sourceID(source) else {
                throw sgAudioError(21, "Colle un lien YouTube Music ou YouTube du morceau, ou importe un fichier audio.")
            }
            return value
        }
        let matches = try await candidates(track).filter { chosenID == nil || $0.videoID == chosenID }
        guard !matches.isEmpty else {
            throw sgAudioError(22, "Aucune version avec le bon titre, artiste et durée. Ajoute un fichier ou un lien audio direct.")
        }
        // Serial attempts avoid competing JavaScriptCore work and keep resource
        // use bounded. No server is contacted for extraction or conversion.
        var lastFailure: String?
        for candidate in matches.prefix(2) {
            try Task.checkCancellation()
            do {
                let streams = try await YouTube(videoID: candidate.videoID, useOAuth: false, allowOAuthCache: false, methods: [.local]).streams
                guard let stream = streams.filter({ $0.includesAudioTrack && !$0.includesVideoTrack && $0.fileExtension == .m4a && $0.isNativelyPlayable && SGNativeHTTP.allowed($0.url) }).max(by: { ($0.averageBitrate ?? $0.bitrate ?? 0) < ($1.averageBitrate ?? $1.bitrate ?? 0) }) else {
                    lastFailure = "no_native_audio_stream"
                    continue
                }
                return ["url": stream.url.absoluteString,
                        "sourceURL": "https://music.youtube.com/watch?v=\(candidate.videoID)",
                        "sourceID": candidate.videoID, "sourceKind": "youtube-music",
                        "seconds": candidate.seconds, "bitrate": stream.averageBitrate ?? stream.bitrate ?? 0,
                        "format": "m4a"]
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                // Keep diagnostics free of ephemeral stream URLs or webpage data.
                let value = error as NSError
                lastFailure = "\(value.domain):\(value.code)"
            }
        }
        throw NSError(domain: "spoti.nativeAudio", code: 23, userInfo: [
            NSLocalizedDescriptionKey: "La source audio est indisponible sur cet appareil. Réessaie ou ajoute un fichier/lien audio.",
            "sourceFailure": lastFailure ?? "unknown"
        ])
    }
}

@objc(SGNativeAudioRequest)
final class SGNativeAudioRequest: NSObject {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    func register(_ value: Task<Void, Never>) {
        lock.lock(); task = value; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { value.cancel() }
    }
    @objc func cancel() {
        lock.lock(); cancelled = true; let value = task; lock.unlock()
        value?.cancel()
    }
}

@objc(SGNativeAudioResolver)
final class SGNativeAudioResolver: NSObject {
    @objc(resolveTrack:sourceURL:completion:)
    static func resolveTrack(_ row: NSDictionary, sourceURL: NSURL?, completion: @escaping (NSDictionary?, NSError?) -> Void) -> SGNativeAudioRequest {
        let token = SGNativeAudioRequest()
        let task = Task.detached(priority: .utility) {
            do {
                let result = try await SGNativeResolverEngine.resolve(row as? [String: Any] ?? [:], sourceURL: sourceURL as URL?)
                try Task.checkCancellation()
                DispatchQueue.main.async { completion(result as NSDictionary, nil) }
            } catch {
                let nsError = error as NSError
                DispatchQueue.main.async { completion(nil, nsError) }
            }
        }
        token.register(task)
        return token
    }
}
