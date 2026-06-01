import Foundation
import LLMkit
import os

/// Provides Google Vertex AI access for the Enhancement feature without an API key.
///
/// Vertex AI's OpenAI-compatible chat endpoint authenticates with a short-lived
/// OAuth2 bearer token, not a static API key. We obtain that token from the user's
/// existing gcloud login (`gcloud auth print-access-token`), so the whole flow works
/// under corporate security policies that forbid API keys. The token is cached and
/// refreshed well within its ~1h lifetime.
final class VertexAIService {
    static let shared = VertexAIService()

    static let projectKey = "vertexAIProject"
    static let locationKey = "vertexAILocation"
    static let defaultLocation = "global"

    private let logger = Logger(subsystem: "com.prakashjoshipax.VoiceInk", category: "VertexAIService")

    private let tokenQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.vertexai.token")
    private var cachedToken: String?
    private var cachedTokenFetchedAt: Date?
    private let tokenTTL: TimeInterval = 50 * 60  // refresh comfortably inside the ~1h token lifetime

    private init() {}

    // MARK: - Configuration (persisted)

    var project: String {
        get { UserDefaults.standard.string(forKey: Self.projectKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.projectKey) }
    }

    var location: String {
        get { UserDefaults.standard.string(forKey: Self.locationKey) ?? Self.defaultLocation }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? Self.defaultLocation : trimmed, forKey: Self.locationKey)
        }
    }

    var isConfigured: Bool {
        !project.isEmpty
    }

    /// OpenAI-compatible chat-completions endpoint for the configured project/location.
    var baseURL: String {
        let proj = project
        guard !proj.isEmpty else { return "" }
        let loc = location
        if loc.isEmpty || loc == "global" {
            return "https://aiplatform.googleapis.com/v1beta1/projects/\(proj)/locations/global/endpoints/openapi/chat/completions"
        }
        return "https://\(loc)-aiplatform.googleapis.com/v1beta1/projects/\(proj)/locations/\(loc)/endpoints/openapi/chat/completions"
    }

    // MARK: - Access token

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let token = cachedTokenSnapshot() {
            return token
        }
        let raw = try await runGcloud(["auth", "print-access-token"], timeout: 15)
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw VertexAIError.emptyToken }
        storeToken(token)
        return token
    }

    private func cachedTokenSnapshot() -> String? {
        tokenQueue.sync {
            guard let token = cachedToken,
                  let at = cachedTokenFetchedAt,
                  Date().timeIntervalSince(at) < tokenTTL else { return nil }
            return token
        }
    }

    private func storeToken(_ token: String) {
        tokenQueue.sync {
            cachedToken = token
            cachedTokenFetchedAt = Date()
        }
    }

    /// Best-effort read of the user's default gcloud project, used to prefill the UI.
    func defaultProjectFromGcloud() async -> String? {
        guard let out = try? await runGcloud(["config", "get-value", "project"], timeout: 10) else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "(unset)" { return nil }
        return trimmed
    }

    /// Fetch a token and make one tiny request to confirm the project/region/model work.
    func verify(model: String) async -> (isValid: Bool, errorMessage: String?) {
        guard isConfigured else {
            return (false, "Enter a Google Cloud Project ID first.")
        }
        guard let url = URL(string: baseURL) else {
            return (false, "Invalid Vertex AI endpoint URL.")
        }
        do {
            let token = try await accessToken(forceRefresh: true)
            return await OpenAILLMClient.verifyAPIKey(baseURL: url, apiKey: token, model: model)
        } catch {
            return (false, (error as? VertexAIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - gcloud runner

    /// Runs gcloud through a login shell so the Homebrew PATH resolves even when the
    /// app is launched from Finder (mirrors LocalCLIService's approach).
    private func runGcloud(_ args: [String], timeout: Double) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                let command = (["gcloud"] + args).joined(separator: " ")
                process.arguments = ["-lc", command]

                var environment = ProcessInfo.processInfo.environment
                let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                if let existing = environment["PATH"], !existing.isEmpty {
                    environment["PATH"] = "\(extraPaths):\(existing)"
                } else {
                    environment["PATH"] = extraPaths
                }
                process.environment = environment

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: VertexAIError.gcloudLaunchFailed(error.localizedDescription))
                    return
                }

                let semaphore = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in semaphore.signal() }

                if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                    if process.isRunning {
                        process.terminate()
                        _ = semaphore.wait(timeout: .now() + 2)
                    }
                    continuation.resume(throwing: VertexAIError.timeout)
                    return
                }

                let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                if process.terminationStatus != 0 {
                    let trimmedErr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    let looksMissing = process.terminationStatus == 127 || trimmedErr.lowercased().contains("command not found")
                    if looksMissing {
                        continuation.resume(throwing: VertexAIError.gcloudNotFound)
                    } else {
                        continuation.resume(throwing: VertexAIError.gcloudFailed(trimmedErr.isEmpty ? "exit code \(process.terminationStatus)" : trimmedErr))
                    }
                    return
                }

                continuation.resume(returning: stdout)
            }
        }
    }
}

enum VertexAIError: Error, LocalizedError {
    case gcloudNotFound
    case gcloudLaunchFailed(String)
    case gcloudFailed(String)
    case emptyToken
    case timeout

    var errorDescription: String? {
        switch self {
        case .gcloudNotFound:
            return "gcloud was not found. Install the Google Cloud SDK and run `gcloud auth login`."
        case .gcloudLaunchFailed(let message):
            return "Failed to run gcloud: \(message)"
        case .gcloudFailed(let message):
            return "gcloud error: \(message). Try `gcloud auth login`."
        case .emptyToken:
            return "gcloud returned an empty access token. Run `gcloud auth login` and try again."
        case .timeout:
            return "gcloud timed out while fetching an access token."
        }
    }
}
