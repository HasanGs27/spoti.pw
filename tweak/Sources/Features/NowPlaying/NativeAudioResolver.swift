import Foundation

private func sgAudioError(_ code: Int, _ message: String) -> NSError {
    NSError(domain: "spoti.nativeAudio", code: code, userInfo: [NSLocalizedDescriptionKey: message])
}

enum SGNativeFailure {
    static func http(_ status: Int) -> NSError {
        switch status {
        case 401, 403: return sgAudioError(33, "Cette source refuse l’accès. Réessaie plus tard ou ajoute un fichier/lien audio direct.")
        case 429: return sgAudioError(32, "La source reçoit trop de demandes. Réessaie dans quelques minutes.")
        case 404, 410: return sgAudioError(35, "Cette source n’est plus disponible. Ajoute un autre lien ou un fichier.")
        case 500...599: return sgAudioError(34, "La source est temporairement indisponible. Réessaie dans quelques instants.")
        default: return sgAudioError(11, "La source ne répond pas correctement. Réessaie ou ajoute un fichier.")
        }
    }
    static func localized(_ error: Error) -> NSError {
        let value = error as NSError
        if error is CancellationError || (value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled) {
            return NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                           userInfo: [NSLocalizedDescriptionKey: "Téléchargement mis en pause."])
        }
        if value.domain == "spoti.nativeAudio" { return value }
        if value.domain == NSURLErrorDomain {
            if [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff].contains(value.code) {
                return sgAudioError(30, "Connexion interrompue. Reconnecte-toi puis reprends le téléchargement.")
            }
            return sgAudioError(31, "La source est injoignable pour le moment. Vérifie ta connexion puis réessaie.")
        }
        if value.domain == "spoti.nativeAudio.player", let status = value.userInfo["sourceStatus"] as? String {
            let code = status.contains("LOGIN_REQUIRED") ? 33 : 35
            let failure = http(code == 33 ? 403 : 404)
            return NSError(domain: failure.domain, code: failure.code, userInfo: [
                NSLocalizedDescriptionKey: failure.localizedDescription,
                "sourceFailure": "\(value.domain):\(value.code):\(String(status.prefix(512)))"
            ])
        }
        return NSError(domain: "spoti.nativeAudio", code: 23, userInfo: [
            NSLocalizedDescriptionKey: "La source audio est indisponible. Essaie un autre lien ou ajoute un fichier MP3/M4A.",
            "sourceFailure": "\(value.domain):\(value.code)"
        ])
    }
    static func shouldStop(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain || (error.domain == "spoti.nativeAudio" && (30...34).contains(error.code))
    }
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
        try Task.checkCancellation()
        guard allowed(request.url) else { throw sgAudioError(10, "Adresse de la source refusée.") }
        var clean = request
        clean.httpShouldHandleCookies = false
        clean.setValue(nil, forHTTPHeaderField: "Cookie")
        clean.setValue(nil, forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: clean) }
        catch { throw SGNativeFailure.localized(error) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, allowed(http.url), data.count <= 8 * 1024 * 1024 else {
            throw sgAudioError(11, "La source ne répond pas correctement. Réessaie ou ajoute un fichier.")
        }
        guard (200...299).contains(http.statusCode) else { throw SGNativeFailure.http(http.statusCode) }
        return (data, response)
    }
}

struct SGNativeTrack: Sendable {
    let title: String
    let artist: String
    let artists: [String]
    let seconds: Double
    init(_ row: [String: Any]) throws {
        title = (row["expectedTitle"] as? String ?? row["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        artist = (row["expectedArtist"] as? String ?? row["artist"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let suppliedArtists = (row["expectedArtists"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        artists = suppliedArtists.isEmpty ? [artist] : suppliedArtists
        seconds = (row["expectedSeconds"] as? NSNumber ?? row["seconds"] as? NSNumber)?.doubleValue ?? 0
        guard !title.isEmpty, !artist.isEmpty, title.count <= 500, artist.count <= 500,
              seconds.isFinite, (1...1800).contains(seconds) else {
            throw sgAudioError(20, "Titre, artiste ou durée indisponibles pour vérifier le bon morceau.")
        }
    }
}

struct SGNativeCandidate: Sendable {
    let videoID: String
    let title: String
    let artists: [String]
    let seconds: Double
    let audioTrack: Bool
}

enum SGNativeMatch {
    private static let bracketedCredit = try! NSRegularExpression(pattern: #"[\(\[]\s*(?:feat(?:uring)?|ft|with)\.?\s+([^\)\]]+)[\)\]]"#, options: .caseInsensitive)
    private static let trailingCredit = try! NSRegularExpression(pattern: #"\s+(?:[-–—]\s*)?(?:feat(?:uring)?|ft)\.?\s+(.+?)\s*$"#, options: .caseInsensitive)
    static func words(_ value: String) -> Set<String> {
        let text = value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        return Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
    // Catalogues put guest credits in different fields: Spotify's "200 Mph"
    // is YouTube Music's "200 MPH FT Diplo (feat. Diplo)". Remove only explicit
    // credits whose complete artist names are independently present in Spotify
    // metadata. Do not strip arbitrary brackets, extra title words or versions.
    private static func titleWords(_ value: String, artists: [String]) -> Set<String> {
        let names = artists.map(words).filter { !$0.isEmpty }
        func knownCredit(_ credit: String) -> Bool {
            let tokens = words(credit).subtracting(["and"])
            guard !tokens.isEmpty else { return false }
            let recognized = names.filter { $0.isSubset(of: tokens) }
                .reduce(into: Set<String>()) { $0.formUnion($1) }
            return recognized == tokens
        }
        var title = value
        for match in bracketedCredit.matches(in: title, range: NSRange(title.startIndex..., in: title)).reversed() {
            guard let creditRange = Range(match.range(at: 1), in: title),
                  knownCredit(String(title[creditRange])), let range = Range(match.range, in: title) else { continue }
            title.replaceSubrange(range, with: " ")
        }
        if let match = trailingCredit.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let creditRange = Range(match.range(at: 1), in: title), knownCredit(String(title[creditRange])),
           let range = Range(match.range, in: title) { title.replaceSubrange(range, with: " ") }
        return words(title)
    }
    static func accepts(_ result: SGNativeCandidate, _ track: SGNativeTrack) -> Bool {
        let title = titleWords(track.title, artists: track.artists)
        let artist = words(track.artists.first ?? track.artist)
        let actualTitle = titleWords(result.title, artists: track.artists)
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
    private static func artistNames(_ detailRuns: [[String: Any]]) -> [String] {
        var names: [String] = []
        // Guest names are sometimes plain text without a browseEndpoint. The
        // first detail column starts with artists, then a bullet, album/duration.
        // Never collect plain text from album, duration or play-count columns.
        for run in detailRuns {
            guard let raw = run["text"] as? String else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("•") || text.contains("·") || duration(text) != nil { break }
            let type = nested(run, ["navigationEndpoint", "browseEndpoint", "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType"]) as? String
            if let type, type != "MUSIC_PAGE_TYPE_ARTIST" { break }
            if !words(text).isEmpty && (type == "MUSIC_PAGE_TYPE_ARTIST" || !["and", "&", ","].contains(text.lowercased())) {
                names.append(text)
            }
        }
        return names
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
                    let artists = columns.count > 1 ? artistNames(runs(columns[1])) : []
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

// Remember only a verified catalogue identity, never a signed audio URL. Each
// download still asks the source for fresh stream URLs. Memory-only and bounded.
actor SGNativeCandidateCache {
    static let shared = SGNativeCandidateCache()
    private struct Key: Hashable {
        let title: String
        let artist: String
        let artists: [String]
        let seconds: Double
        init(_ track: SGNativeTrack) {
            title = track.title; artist = track.artist; artists = track.artists; seconds = track.seconds
        }
    }
    private struct Entry {
        let candidate: SGNativeCandidate
        let expires: TimeInterval
        var accessed: TimeInterval
    }
    private var entries: [Key: Entry] = [:]
    private let capacity: Int
    private let lifetime: TimeInterval
    init(capacity: Int = 128, lifetime: TimeInterval = 15 * 60) {
        self.capacity = max(1, min(128, capacity))
        self.lifetime = max(1, min(15 * 60, lifetime))
    }
    func candidate(for track: SGNativeTrack, sourceID: String? = nil,
                   now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> SGNativeCandidate? {
        entries = entries.filter { $0.value.expires > now }
        let key = Key(track)
        guard var entry = entries[key], sourceID == nil || entry.candidate.videoID == sourceID,
              SGNativeMatch.accepts(entry.candidate, track) else { return nil }
        entry.accessed = now; entries[key] = entry
        return entry.candidate
    }
    func store(_ candidate: SGNativeCandidate, for track: SGNativeTrack,
               now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard SGNativeMatch.validID(candidate.videoID), SGNativeMatch.accepts(candidate, track) else { return }
        entries = entries.filter { $0.value.expires > now }
        let key = Key(track)
        if entries[key] == nil, entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = Entry(candidate: candidate, expires: now + lifetime, accessed: now)
    }
    func remove(_ track: SGNativeTrack, sourceID: String) {
        let key = Key(track)
        if entries[key]?.candidate.videoID == sourceID { entries.removeValue(forKey: key) }
    }
}

enum SGNativeResolverEngine {
    typealias Search = (String) async throws -> [SGNativeCandidate]
    typealias Extract = (SGNativeCandidate) async throws -> [String: Any]

    static func search(_ query: String) async throws -> [SGNativeCandidate] {
        try Task.checkCancellation()
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "yyyyMMdd"
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.\(date.string(from: Date())).01.00", "hl": "en"]],
            "query": query,
            "params": "EgWKAQIIAUICCAFqDBAOEAoQAxAEEAkQBQ%3D%3D"
        ]
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/search?alt=json")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        let (data, _) = try await SGNativeHTTP.data(for: request)
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw sgAudioError(37, "La recherche musicale a renvoyé une réponse illisible. Réessaie plus tard.")
        }
        return SGNativeMatch.parse(object)
    }
    static func candidates(_ track: SGNativeTrack, sourceID: String? = nil,
                           searcher: Search = SGNativeResolverEngine.search) async throws -> [SGNativeCandidate] {
        let fullQuery = "\(track.title) \(track.artist)"
        let primaryQuery = "\(track.title) \(track.artists.first ?? track.artist)"
        var queries = [fullQuery]
        if SGNativeMatch.words(fullQuery) != SGNativeMatch.words(primaryQuery) { queries.append(primaryQuery) }
        for query in queries {
            try Task.checkCancellation()
            let results = try await searcher(query)
            try Task.checkCancellation()
            let matches = results.filter {
                (sourceID == nil || $0.videoID == sourceID) && SGNativeMatch.accepts($0, track)
            }.sorted { abs($0.seconds - track.seconds) < abs($1.seconds - track.seconds) }
            if !matches.isEmpty { return matches }
        }
        return []
    }
    static func extract(_ candidate: SGNativeCandidate) async throws -> [String: Any] {
        try Task.checkCancellation()
        let streams = try await YouTube(videoID: candidate.videoID, useOAuth: false, allowOAuthCache: false, methods: [.local]).streams
        try Task.checkCancellation()
        guard let stream = streams.filter({ $0.includesAudioTrack && !$0.includesVideoTrack && $0.fileExtension == .m4a && $0.isNativelyPlayable && SGNativeHTTP.allowed($0.url) }).max(by: { ($0.averageBitrate ?? $0.bitrate ?? 0) < ($1.averageBitrate ?? $1.bitrate ?? 0) }) else {
            throw sgAudioError(36, "La source ne propose pas de format audio compatible. Ajoute un fichier MP3/M4A ou un autre lien audio.")
        }
        return ["url": stream.url.absoluteString,
                "sourceURL": "https://music.youtube.com/watch?v=\(candidate.videoID)",
                "sourceID": candidate.videoID, "sourceKind": "youtube-music",
                "seconds": candidate.seconds, "bitrate": stream.averageBitrate ?? stream.bitrate ?? 0,
                "format": "m4a"]
    }

    static func resolve(_ row: [String: Any], sourceURL: URL?, cache: SGNativeCandidateCache = .shared,
                        searcher: Search = SGNativeResolverEngine.search,
                        extractor: Extract = SGNativeResolverEngine.extract) async throws -> [String: Any] {
        try Task.checkCancellation()
        let track = try SGNativeTrack(row)
        let chosenID = try sourceURL.map { source -> String in
            guard let value = SGNativeMatch.sourceID(source) else {
                throw sgAudioError(21, "Colle un lien YouTube Music ou YouTube du morceau, ou importe un fichier audio.")
            }
            return value
        }
        var pending: [SGNativeCandidate] = []
        if let cached = await cache.candidate(for: track, sourceID: chosenID) { pending.append(cached) }
        var searched = false
        var attempted = Set<String>()
        var lastFailure: NSError?
        // A cached identity skips the search, not extraction. If that recording
        // disappears, discard it and search once before trying another match.
        for _ in 0..<2 {
            try Task.checkCancellation()
            if pending.isEmpty && !searched {
                pending = try await candidates(track, sourceID: chosenID, searcher: searcher)
                    .filter { !attempted.contains($0.videoID) }
                searched = true
            }
            guard !pending.isEmpty else { break }
            let candidate = pending.removeFirst()
            attempted.insert(candidate.videoID)
            do {
                let result = try await extractor(candidate)
                try Task.checkCancellation()
                await cache.store(candidate, for: track)
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                let failure = SGNativeFailure.localized(error)
                // More searches cannot fix a disconnected phone, rate limit or
                // access refusal. Keep the identity for a later retry.
                if SGNativeFailure.shouldStop(failure) { throw failure }
                await cache.remove(track, sourceID: candidate.videoID)
                lastFailure = failure
            }
        }
        if let lastFailure { throw lastFailure }
        throw sgAudioError(22, "Aucune version avec le bon titre, artiste et durée. Ajoute un fichier ou un lien audio direct.")
    }
}

@objc(SGNativeAudioRequest)
final class SGNativeAudioRequest: NSObject {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    private var finished = false
    func register(_ value: Task<Void, Never>) {
        lock.lock()
        if finished { lock.unlock(); value.cancel(); return }
        task = value; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { value.cancel() }
    }
    @objc func cancel() {
        lock.lock(); cancelled = true; let value = task; lock.unlock()
        value?.cancel()
    }
    func finish(_ result: NSDictionary?, error: NSError?, completion: @escaping (NSDictionary?, NSError?) -> Void) {
        DispatchQueue.main.async {
            self.lock.lock()
            guard !self.finished else { self.lock.unlock(); return }
            self.finished = true
            let wasCancelled = self.cancelled
            self.task = nil
            self.lock.unlock()
            // Pause may arrive after extraction finishes but before the main
            // queue delivers it. Never report success after that cancellation.
            completion(wasCancelled ? nil : result,
                       wasCancelled ? SGNativeFailure.localized(CancellationError()) : error)
        }
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
                token.finish(result as NSDictionary, error: nil, completion: completion)
            } catch {
                token.finish(nil, error: SGNativeFailure.localized(error), completion: completion)
            }
        }
        token.register(task)
        return token
    }
}
