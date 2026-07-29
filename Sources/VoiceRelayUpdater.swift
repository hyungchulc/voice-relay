import Foundation

struct VoiceRelaySemanticVersion: Comparable, Equatable {
    enum PrereleaseKind: Int, Comparable {
        case alpha = 0
        case beta = 1
        case rc = 2

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let major: Int
    let minor: Int
    let patch: Int
    let prereleaseKind: PrereleaseKind?
    let prereleaseNumber: Int?

    init?(tag: String) {
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let pattern =
            #"^([0-9]+)\.([0-9]+)\.([0-9]+)(?:-(alpha|beta|rc)(?:\.([0-9]+))?)?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ),
              match.range.location != NSNotFound,
              let majorRange = Range(match.range(at: 1), in: value),
              let minorRange = Range(match.range(at: 2), in: value),
              let patchRange = Range(match.range(at: 3), in: value),
              let major = Int(value[majorRange]),
              let minor = Int(value[minorRange]),
              let patch = Int(value[patchRange]) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        if let kindRange = Range(match.range(at: 4), in: value) {
            guard let kind = PrereleaseKind(
                rawValue: ["alpha", "beta", "rc"].firstIndex(
                    of: String(value[kindRange])
                ) ?? -1
            ) else {
                return nil
            }
            prereleaseKind = kind
            if let numberRange = Range(match.range(at: 5), in: value) {
                guard let number = Int(value[numberRange]) else {
                    return nil
                }
                prereleaseNumber = number
            } else {
                prereleaseNumber = 0
            }
        } else {
            prereleaseKind = nil
            prereleaseNumber = nil
        }
    }

    var isPrerelease: Bool {
        prereleaseKind != nil
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let lhsCore = (lhs.major, lhs.minor, lhs.patch)
        let rhsCore = (rhs.major, rhs.minor, rhs.patch)
        if lhsCore != rhsCore {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }
        switch (lhs.prereleaseKind, rhs.prereleaseKind) {
        case (nil, nil):
            return false
        case (nil, _):
            return false
        case (_, nil):
            return true
        case let (lhsKind?, rhsKind?):
            if lhsKind != rhsKind { return lhsKind < rhsKind }
            return (lhs.prereleaseNumber ?? 0)
                < (rhs.prereleaseNumber ?? 0)
        }
    }
}

struct VoiceRelayReleaseIdentity {
    let shortVersion: String
    let build: String
    let releaseTag: String
    let channel: String

    init(bundle: Bundle = .main) {
        shortVersion =
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "0.0.0"
        build =
            bundle.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String ?? "0"
        releaseTag =
            bundle.object(forInfoDictionaryKey: "VoiceRelayReleaseTag")
                as? String ?? ""
        channel =
            bundle.object(forInfoDictionaryKey: "VoiceRelayDistributionChannel")
                as? String ?? "development"
    }

    var displayVersion: String {
        if releaseTag.hasPrefix("v") {
            return String(releaseTag.dropFirst())
        }
        return releaseTag.isEmpty ? shortVersion : releaseTag
    }

    var canCheckForUpdates: Bool {
        VoiceRelaySemanticVersion(tag: releaseTag) != nil
    }
}

struct VoiceRelayGitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
    }
}

struct VoiceRelayUpdateCandidate: Equatable {
    let tag: String
    let version: VoiceRelaySemanticVersion
    let pageURL: URL
}

enum VoiceRelayUpdateCheckResult: Equatable {
    case upToDate
    case available(VoiceRelayUpdateCandidate)
}

enum VoiceRelayUpdatePolicy {
    private static let repositoryPath = [
        "hyungchulc", "voice-relay", "releases", "tag",
    ]

    static func selectCandidate(
        currentTag: String,
        releases: [VoiceRelayGitHubRelease]
    ) -> VoiceRelayUpdateCandidate? {
        guard let current = VoiceRelaySemanticVersion(tag: currentTag) else {
            return nil
        }
        return releases.compactMap { release in
            guard !release.draft,
                  let version = VoiceRelaySemanticVersion(
                      tag: release.tagName
                  ),
                  version > current,
                  release.prerelease == version.isPrerelease else {
                return nil
            }
            if current.isPrerelease {
                if !version.isPrerelease {
                    guard version.major == 1,
                          version.minor == 0,
                          version.patch == 0 else {
                        return nil
                    }
                }
            } else if version.isPrerelease {
                return nil
            }
            guard let pageURL = validatedReleasePageURL(
                release.htmlURL,
                tag: release.tagName
            ) else {
                return nil
            }
            return VoiceRelayUpdateCandidate(
                tag: release.tagName,
                version: version,
                pageURL: pageURL
            )
        }.max { $0.version < $1.version }
    }

    static func validatedReleasePageURL(
        _ value: String,
        tag: String
    ) -> URL? {
        guard !value.localizedCaseInsensitiveContains("%2f"),
              var components = URLComponents(string: value),
              components.scheme == "https",
              components.host?.lowercased() == "github.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        let path = components.path.split(separator: "/").map(String.init)
        guard path == repositoryPath + [tag],
              VoiceRelaySemanticVersion(tag: tag) != nil else {
            return nil
        }
        components.path = "/" + path.joined(separator: "/")
        return components.url
    }
}

enum VoiceRelayUpdateError: LocalizedError {
    case badResponse
    case responseTooLarge
    case unavailable

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "The update service returned an invalid response."
        case .responseTooLarge:
            return "The update response was unexpectedly large."
        case .unavailable:
            return "Update checking is not available for this build."
        }
    }
}

final class VoiceRelayUpdateChecker {
    private static let endpoint = URL(
        string:
            "https://api.github.com/repos/hyungchulc/voice-relay/releases?per_page=100"
    )!
    private static let maximumResponseBytes = 2_000_000
    private let session: URLSession
    private var activeTask: URLSessionDataTask?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }

    func check(
        currentTag: String,
        completion: @escaping (Result<VoiceRelayUpdateCheckResult, Error>) -> Void
    ) {
        cancel()
        guard VoiceRelaySemanticVersion(tag: currentTag) != nil else {
            completion(.failure(VoiceRelayUpdateError.unavailable))
            return
        }
        var request = URLRequest(
            url: Self.endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 12
        )
        request.setValue(
            "Voice-Relay/\(currentTag)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "2022-11-28",
            forHTTPHeaderField: "X-GitHub-Api-Version"
        )
        activeTask = session.dataTask(with: request) { [weak self] data, response, error in
            defer { self?.activeTask = nil }
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data else {
                completion(.failure(VoiceRelayUpdateError.badResponse))
                return
            }
            guard data.count <= Self.maximumResponseBytes else {
                completion(.failure(VoiceRelayUpdateError.responseTooLarge))
                return
            }
            do {
                let releases = try JSONDecoder().decode(
                    [VoiceRelayGitHubRelease].self,
                    from: data
                )
                if let candidate = VoiceRelayUpdatePolicy.selectCandidate(
                    currentTag: currentTag,
                    releases: releases
                ) {
                    completion(.success(.available(candidate)))
                } else {
                    completion(.success(.upToDate))
                }
            } catch {
                completion(.failure(error))
            }
        }
        activeTask?.resume()
    }
}
