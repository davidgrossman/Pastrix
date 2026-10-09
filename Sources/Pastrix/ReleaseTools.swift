import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ReleaseTools: NSObject {
    private static let latestReleaseAPIURL = URL(
        string: "https://api.github.com/repos/davidgrossman/Pastrix/releases/latest"
    )!
    private static let releasesURL = URL(
        string: "https://github.com/davidgrossman/Pastrix/releases"
    )!
    private static let newIssueURL = URL(
        string: "https://github.com/davidgrossman/Pastrix/issues/new/choose"
    )!

    private var feedbackWindow: NSWindow?
    private weak var feedbackTextView: NSTextView?

    @objc func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)

        guard let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String, !currentVersion.isEmpty else {
            showUpdateUnavailable(
                "Pastrix can’t determine the version of the app that is currently running."
            )
            return
        }

        Task { [weak self] in
            await self?.fetchLatestRelease(currentVersion: currentVersion)
        }
    }

    @objc func sendFeedback() {
        let window = feedbackWindow ?? makeFeedbackWindow()
        feedbackWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(feedbackTextView)
    }

    @objc private func saveFeedbackDraft() {
        guard let feedbackTextView else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Pastrix-feedback.txt"
        panel.prompt = "Save Feedback"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Unknown"
        let macOSVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let draft = """
        Pastrix Feedback Draft

        App version: \(appVersion)
        macOS: \(macOSVersion)

        Feedback:
        \(feedbackTextView.string)
        """

        do {
            try draft.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Pastrix couldn’t save the feedback draft"
            alert.runModal()
        }
    }

    @objc private func openGitHubIssue() {
        NSWorkspace.shared.open(Self.newIssueURL)
    }

    nonisolated static func compareNumericVersions(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult? {
        guard let left = numericVersionComponents(lhs),
              let right = numericVersionComponents(rhs) else { return nil }

        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftComponent = index < left.count ? left[index] : 0
            let rightComponent = index < right.count ? right[index] : 0
            if leftComponent < rightComponent { return .orderedAscending }
            if leftComponent > rightComponent { return .orderedDescending }
        }
        return .orderedSame
    }

    nonisolated static func decodeLatestReleaseVersion(from data: Data) throws -> String {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let tag = release.tagName
        let version: String
        if tag.first == "v" || tag.first == "V" {
            version = String(tag.dropFirst())
        } else {
            version = tag
        }

        guard numericVersionComponents(version) != nil else {
            throw ReleaseResponseError.invalidVersionTag(tag)
        }
        return version
    }

    private func fetchLatestRelease(currentVersion: String) async {
        var request = URLRequest(url: Self.latestReleaseAPIURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Pastrix/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                showUpdateUnavailable("GitHub returned an unreadable response.")
                return
            }
            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 404 {
                    showUpdateUnavailable(
                        "GitHub does not currently have a public Pastrix release to compare."
                    )
                } else {
                    showUpdateUnavailable(
                        "GitHub returned HTTP \(httpResponse.statusCode). Please try again later."
                    )
                }
                return
            }

            let latestVersion: String
            do {
                latestVersion = try Self.decodeLatestReleaseVersion(from: data)
            } catch {
                showUpdateUnavailable(
                    "GitHub returned release information that Pastrix couldn’t read."
                )
                return
            }

            guard let comparison = Self.compareNumericVersions(latestVersion, currentVersion) else {
                showUpdateUnavailable(
                    "Pastrix couldn’t compare release \(latestVersion) with installed version \(currentVersion)."
                )
                return
            }

            showUpdateResult(
                comparison: comparison,
                latestVersion: latestVersion,
                currentVersion: currentVersion
            )
        } catch let error as URLError where error.code == .timedOut {
            showUpdateUnavailable(
                "The request to GitHub timed out. Check your connection and try again."
            )
        } catch {
            showUpdateUnavailable(
                "Pastrix couldn’t reach GitHub. Check your connection and try again."
            )
        }
    }

    private func showUpdateResult(
        comparison: ComparisonResult,
        latestVersion: String,
        currentVersion: String
    ) {
        let alert = NSAlert()
        if comparison == .orderedDescending {
            alert.messageText = "Pastrix \(latestVersion) is available"
            alert.informativeText = "You’re running Pastrix \(currentVersion). Pastrix will not download or install the update automatically."
            alert.addButton(withTitle: "Open Releases Page")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(Self.releasesURL)
            }
        } else {
            alert.messageText = "Pastrix is up to date"
            alert.informativeText = "Installed version: \(currentVersion)\nLatest public release: \(latestVersion)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private nonisolated static func numericVersionComponents(_ version: String) -> [UInt64]? {
        let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }
        var result: [UInt64] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = UInt64(piece) else { return nil }
            result.append(value)
        }
        return result
    }

    private func showUpdateUnavailable(_ explanation: String) {
        let alert = NSAlert()
        alert.messageText = "Can’t check for updates"
        alert.informativeText = explanation
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func makeFeedbackWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pastrix Feedback"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(
            labelWithString: "Write a local draft, then save it or open GitHub to submit an issue yourself. Pastrix never copies or sends this text automatically."
        )
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 8, height: 8)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        let openIssueButton = NSButton(
            title: "Open GitHub Issue…",
            target: self,
            action: #selector(openGitHubIssue)
        )
        openIssueButton.bezelStyle = .rounded

        let saveButton = NSButton(
            title: "Save Draft…",
            target: self,
            action: #selector(saveFeedbackDraft)
        )
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let buttonStack = NSStackView(views: [openIssueButton, saveButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 10
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        container.addSubview(scrollView)
        container.addSubview(buttonStack)
        window.contentView = container
        feedbackTextView = textView

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -16),
            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            buttonStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20)
        ])

        return window
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
    }
}

private enum ReleaseResponseError: Error {
    case invalidVersionTag(String)
}
