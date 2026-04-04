import Foundation

class OpenClawSession: NSObject, AgentSession, URLSessionDataDelegate {

    private let characterName: String
    private var urlSession: URLSession?
    private var currentTask: URLSessionDataTask?
    private var sseBuffer = ""
    private var currentResponseText = ""
    private var messages: [[String: String]] = []

    private(set) var isRunning = false
    private(set) var isBusy = false
    var history: [AgentMessage] = []

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?

    init(characterName: String) {
        self.characterName = characterName
        super.init()
    }

    func start() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.connectionProxyDictionary = [:]  // Bypass system proxies for Tailscale direct connection
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        isRunning = true

        // Prepopulate system prompt from config
        if let systemPrompt = OpenClawConfig.systemPrompt(for: characterName), !systemPrompt.isEmpty {
            messages = [["role": "system", "content": systemPrompt]]
        }

        DispatchQueue.main.async {
            self.onSessionReady?()
        }
    }

    func send(message: String) {
        guard isRunning else { return }
        guard let token = OpenClawConfig.token, !token.isEmpty else {
            let err = "OpenClaw auth token not configured.\nUse the provider menu to configure OpenClaw."
            DispatchQueue.main.async {
                self.onError?(err)
                self.history.append(AgentMessage(role: .error, text: err))
            }
            return
        }

        isBusy = true
        history.append(AgentMessage(role: .user, text: message))
        messages.append(["role": "user", "content": message])
        currentResponseText = ""
        sseBuffer = ""

        let url = URL(string: "\(OpenClawConfig.baseURL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "messages": messages,
            "stream": true,
            "user": characterName.lowercased()
        ]
        if let agentId = OpenClawConfig.agentId(for: characterName), !agentId.isEmpty {
            body["model"] = "openclaw/\(agentId)"
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            let err = "Failed to encode request: \(error.localizedDescription)"
            DispatchQueue.main.async {
                self.isBusy = false
                self.onError?(err)
                self.history.append(AgentMessage(role: .error, text: err))
            }
            return
        }

        NSLog("[OpenClaw] URL: %@", url.absoluteString)
        NSLog("[OpenClaw] Authorization: Bearer %@", String(token.prefix(8)) + "...")
        if let bodyData = request.httpBody, let bodyStr = String(data: bodyData, encoding: .utf8) {
            NSLog("[OpenClaw] Body: %@", bodyStr)
        }

        let task = urlSession?.dataTask(with: request)
        currentTask = task
        task?.resume()
    }

    func terminate() {
        currentTask?.cancel()
        currentTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isRunning = false
        isBusy = false
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse {
            NSLog("[OpenClaw] Response status: %d", httpResponse.statusCode)
            NSLog("[OpenClaw] Response headers: %@", httpResponse.allHeaderFields)
        }
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let err = "OpenClaw server returned HTTP \(httpResponse.statusCode)"
            DispatchQueue.main.async {
                self.isBusy = false
                self.onError?(err)
                self.history.append(AgentMessage(role: .error, text: err))
            }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        sseBuffer += text
        processSSEBuffer()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            if let error = error as? NSError, error.code != NSURLErrorCancelled {
                let err = "Connection error: \(error.localizedDescription)"
                self.onError?(err)
                self.history.append(AgentMessage(role: .error, text: err))
            }
            self.finishTurn()
        }
    }

    // MARK: - SSE Parsing

    private func processSSEBuffer() {
        // SSE events are separated by double newlines
        while let range = sseBuffer.range(of: "\n\n") {
            let event = String(sseBuffer[sseBuffer.startIndex..<range.lowerBound])
            sseBuffer = String(sseBuffer[range.upperBound...])
            parseSSEEvent(event)
        }
        // Also handle single-line data (some servers send data: ...\n without double newline until next chunk)
        let lines = sseBuffer.components(separatedBy: "\n")
        if lines.count > 1 {
            // Process all complete lines, keep the last (possibly incomplete) one
            let completeLines = lines.dropLast()
            sseBuffer = lines.last ?? ""
            for line in completeLines {
                if !line.isEmpty {
                    parseSSEEvent(line)
                }
            }
        }
    }

    private func parseSSEEvent(_ event: String) {
        for line in event.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)

            if payload == "[DONE]" {
                DispatchQueue.main.async {
                    self.finishTurn()
                }
                return
            }

            guard let jsonData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any] else { continue }

            if let content = delta["content"] as? String, !content.isEmpty {
                DispatchQueue.main.async {
                    self.currentResponseText += content
                    self.onText?(content)
                }
            }
        }
    }

    private func finishTurn() {
        guard isBusy else { return }
        isBusy = false
        if !currentResponseText.isEmpty {
            history.append(AgentMessage(role: .assistant, text: currentResponseText))
            messages.append(["role": "assistant", "content": currentResponseText])
        }
        currentResponseText = ""
        onTurnComplete?()
    }
}
