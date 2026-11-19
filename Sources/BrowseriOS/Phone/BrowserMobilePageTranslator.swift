// BrowserMobilePageTranslator.swift

import NaturalLanguage
import SwiftUI
import Translation
import UIKit

// MARK: - BrowserMobilePageTranslator

/// Translates the open page in place with the system's on-device
/// translation, into the app's language. The system asks to download a
/// language the first time it is needed.
@MainActor final class BrowserMobilePageTranslator {
    // MARK: Internal

    enum Failure: Error, Equatable {
        /// The page is already in the language it would be translated into.
        case sameLanguage(String)
        case unsupported
    }

    // MARK: Private

    @Observable @MainActor fileprivate final class Model {
        struct Job {
            let texts: [String]
            let deliver: @MainActor @Sendable (_ start: Int, _ texts: [String]) -> Void
            let finish: @MainActor @Sendable (Error?) -> Void
        }

        var configuration: TranslationSession.Configuration?
        @ObservationIgnored var job: Job?

        func takeJob() -> Job? {
            defer { job = nil }
            return job
        }
    }

    /// The session lives only inside its task; this hands it to `run` there.
    private struct SessionBox: @unchecked Sendable {
        let session: TranslationSession
    }

    private struct HostView: View {
        let model: Model

        var body: some View {
            Color.clear
                .translationTask(model.configuration) { session in
                    await BrowserMobilePageTranslator.run(SessionBox(session: session), model: model)
                }
        }
    }

    /// Strings translated in one request; the page fills in batch by batch, from the top.
    nonisolated static let batchSize = 48

    private let model = Model()
    private lazy var host = UIHostingController(rootView: HostView(model: model))

    /// The language pages translate into: the app's own.
    var targetLanguage: Locale.Language { Locale.current.language }

    /// The page's language: its text's, else what the document declares.
    static func sourceLanguage(of text: BrowserMobilePageText) -> Locale.Language? {
        var sample = ""
        for string in text.texts where !string.isEmpty {
            sample += string + "\n"
            if sample.count > 4000 { break }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        if let language = recognizer.dominantLanguage, language != .undetermined {
            return Locale.Language(identifier: language.rawValue)
        }
        let declared = text.language.trimmingCharacters(in: .whitespaces)
        return declared.isEmpty ? nil : Locale.Language(identifier: declared)
    }

    /// Translates the texts batch by batch, handing each batch to the job as it comes.
    private nonisolated static func run(_ box: SessionBox, model: Model) async {
        guard let job = await model.takeJob() else { return }
        do {
            try await box.session.prepareTranslation()
            var start = 0
            while start < job.texts.count {
                let end = min(start + batchSize, job.texts.count)
                let requests = (start..<end).compactMap { index -> TranslationSession.Request? in
                    job.texts[index].isEmpty
                        ? nil
                        : TranslationSession.Request(sourceText: job.texts[index], clientIdentifier: String(index))
                }
                var translated = Array(job.texts[start..<end])
                if !requests.isEmpty {
                    for response in try await box.session.translations(from: requests) {
                        guard let id = response.clientIdentifier, let index = Int(id) else { continue }
                        translated[index - start] = response.targetText
                    }
                }
                let batch = translated
                let batchStart = start
                await job.deliver(batchStart, batch)
                start = end
            }
            await job.finish(nil)
        } catch {
            await job.finish(error)
        }
    }

    /// Adds the invisible view that hosts translation sessions.
    func install(in parent: UIViewController) {
        guard host.parent == nil else { return }
        parent.addChild(host)
        host.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        host.view.isUserInteractionEnabled = false
        host.view.backgroundColor = .clear
        host.view.alpha = 0
        parent.view.insertSubview(host.view, at: 0)
        host.didMove(toParent: parent)
    }

    func translate(
        _ text: BrowserMobilePageText,
        deliver: @escaping @MainActor @Sendable (_ start: Int, _ texts: [String]) -> Void,
        finish: @escaping @MainActor @Sendable (Error?) -> Void,
    ) {
        let target = targetLanguage
        let source = Self.sourceLanguage(of: text)
        if let source, source.languageCode == target.languageCode {
            let name = Locale.current.localizedString(forLanguageCode: target.languageCode?.identifier ?? "") ?? ""
            finish(Failure.sameLanguage(name))
            return
        }
        Task { @MainActor in
            if let source, await LanguageAvailability().status(from: source, to: target) == .unsupported {
                finish(Failure.unsupported)
                return
            }
            model.job = Model.Job(texts: text.texts, deliver: deliver, finish: finish)
            let configuration = TranslationSession.Configuration(source: source, target: target)
            if model.configuration?.source == configuration.source,
               model.configuration?.target == configuration.target
            {
                model.configuration?.invalidate()
            } else {
                model.configuration = configuration
            }
        }
    }
}
