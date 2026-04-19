import Foundation

struct ServerGroup: Codable, Hashable, Sendable {
    let id: Int
    let name: String
}

struct ServerStory: Codable, Hashable, Sendable {
    let id: Int
    let title: String
    let url: String
}

struct ServerGroupStories: Codable, Hashable, Sendable {
    let groupId: Int
    let groupName: String
    let stories: [ServerStory]
}

enum FlowClientError: Error {
    case invalidURL
    case http(Int)
    case unauthorized
    case decoding
    case transport(String)
}

final class FlowClient {
    private var baseURL: URL?
    private var password: String

    init(baseURL: String, password: String) {
        self.password = password
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = trimmed.isEmpty ? nil : URL(string: trimmed)
    }

    func update(password: String) {
        self.password = password
    }

    private func makeRequest(path: String) -> URLRequest? {
        guard let base = baseURL, let url = URL(string: path, relativeTo: base) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    struct VerifyResult: Codable { let ok: Bool }

    func verify() async throws {
        let _: VerifyResult = try await get(path: "/api/verify")
    }

    func groups() async throws -> [ServerGroup] {
        try await get(path: "/api/groups")
    }

    func stories(forGroupIds ids: [Int]) async throws -> [ServerGroupStories] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(String.init).joined(separator: ",")
        return try await get(path: "/api/stories?ids=\(list)")
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        guard let req = makeRequest(path: path) else { throw FlowClientError.invalidURL }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw FlowClientError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw FlowClientError.http(-1) }
        if http.statusCode == 401 { throw FlowClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw FlowClientError.http(http.statusCode) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FlowClientError.decoding
        }
    }
}
