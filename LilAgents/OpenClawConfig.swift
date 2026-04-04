import AppKit

enum OpenClawConfig {

    private static let tokenKey = "OpenClawToken"
    private static let systemPromptPrefix = "OpenClawSystemPrompt_"
    private static let agentIdPrefix = "OpenClawAgentId_"

    static var token: String? {
        get { UserDefaults.standard.string(forKey: tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: tokenKey) }
    }

    static var isConfigured: Bool {
        guard let t = token else { return false }
        return !t.isEmpty
    }

    static func systemPrompt(for characterName: String) -> String? {
        UserDefaults.standard.string(forKey: systemPromptPrefix + characterName)
    }

    static func setSystemPrompt(_ prompt: String?, for characterName: String) {
        UserDefaults.standard.set(prompt, forKey: systemPromptPrefix + characterName)
    }

    /// The agent ID to route to (maps to the `model` field in the chat completions request).
    /// e.g. "writer", "coder", "main". Nil means use the server default.
    static func agentId(for characterName: String) -> String? {
        if let saved = UserDefaults.standard.string(forKey: agentIdPrefix + characterName) {
            return saved
        }
        // Default mappings
        switch characterName {
        case "Bruce": return "coder"
        case "Jazz":  return "writer"
        default:      return nil
        }
    }

    static func setAgentId(_ agentId: String?, for characterName: String) {
        UserDefaults.standard.set(agentId, forKey: agentIdPrefix + characterName)
    }

    static let baseURL = "http://100.105.160.91:18789"

    // MARK: - Config Dialog

    static func showConfigDialog(for characterName: String, in window: NSWindow?, completion: (() -> Void)? = nil) {
        let panelHeight: CGFloat = 380
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: panelHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        panel.title = "OpenClaw — \(characterName)"
        panel.isFloatingPanel = true
        panel.level = .statusBar + 20

        let container = NSView(frame: panel.contentView!.bounds)
        container.autoresizingMask = [.width, .height]

        let margin: CGFloat = 20
        var y: CGFloat = panelHeight - 40

        // Token
        let tokenLabel = NSTextField(labelWithString: "Auth Token:")
        tokenLabel.frame = NSRect(x: margin, y: y, width: 380, height: 18)
        tokenLabel.font = .systemFont(ofSize: 13, weight: .medium)
        container.addSubview(tokenLabel)
        y -= 28

        let tokenField = NSSecureTextField(frame: NSRect(x: margin, y: y, width: 380, height: 24))
        tokenField.font = .systemFont(ofSize: 13)
        tokenField.placeholderString = "Bearer token for gateway auth"
        tokenField.stringValue = token ?? ""
        container.addSubview(tokenField)
        y -= 36

        // Agent ID
        let agentLabel = NSTextField(labelWithString: "Agent ID for \"\(characterName)\":")
        agentLabel.frame = NSRect(x: margin, y: y, width: 380, height: 18)
        agentLabel.font = .systemFont(ofSize: 13, weight: .medium)
        container.addSubview(agentLabel)
        y -= 28

        let agentField = NSTextField(frame: NSRect(x: margin, y: y, width: 380, height: 24))
        agentField.font = .systemFont(ofSize: 13)
        agentField.placeholderString = "e.g. writer, coder, main (leave blank for default)"
        agentField.stringValue = agentId(for: characterName) ?? ""
        container.addSubview(agentField)
        y -= 36

        // System prompt
        let promptLabel = NSTextField(labelWithString: "System Prompt for \"\(characterName)\" (optional):")
        promptLabel.frame = NSRect(x: margin, y: y, width: 380, height: 18)
        promptLabel.font = .systemFont(ofSize: 13, weight: .medium)
        container.addSubview(promptLabel)
        y -= 8

        let scrollView = NSScrollView(frame: NSRect(x: margin, y: y - 110, width: 380, height: 110))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 110))
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.string = systemPrompt(for: characterName) ?? ""
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scrollView.documentView = textView
        container.addSubview(scrollView)
        y = scrollView.frame.minY - 20

        // Buttons
        let saveButton = NSButton(title: "Save", target: nil, action: nil)
        saveButton.frame = NSRect(x: 320, y: y, width: 80, height: 32)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        container.addSubview(saveButton)

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.frame = NSRect(x: 230, y: y, width: 80, height: 32)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        container.addSubview(cancelButton)

        panel.contentView = container

        class DialogDelegate: NSObject {
            let panel: NSPanel
            let tokenField: NSSecureTextField
            let agentField: NSTextField
            let textView: NSTextView
            let characterName: String
            let completion: (() -> Void)?

            init(panel: NSPanel, tokenField: NSSecureTextField, agentField: NSTextField,
                 textView: NSTextView, characterName: String, completion: (() -> Void)?) {
                self.panel = panel
                self.tokenField = tokenField
                self.agentField = agentField
                self.textView = textView
                self.characterName = characterName
                self.completion = completion
            }

            @objc func save(_ sender: Any) {
                let t = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                OpenClawConfig.token = t.isEmpty ? nil : t

                let a = agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                OpenClawConfig.setAgentId(a.isEmpty ? nil : a, for: characterName)

                let p = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
                OpenClawConfig.setSystemPrompt(p.isEmpty ? nil : p, for: characterName)

                panel.close()
                completion?()
            }

            @objc func cancel(_ sender: Any) {
                panel.close()
            }
        }

        let delegate = DialogDelegate(panel: panel, tokenField: tokenField, agentField: agentField,
                                      textView: textView, characterName: characterName, completion: completion)
        objc_setAssociatedObject(panel, "dialogDelegate", delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        saveButton.target = delegate
        saveButton.action = #selector(DialogDelegate.save(_:))
        cancelButton.target = delegate
        cancelButton.action = #selector(DialogDelegate.cancel(_:))

        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }
}
