import Foundation
import SwiftSignalKit
import Speech

private var sharedRecognizers: [String: SFSpeechRecognizer] = [:]

private struct TranscriptionResult {
    var text: String
    var isFinal: Bool
}

/// "en_US@calendar=gregorian" -> "en-us".
private func normalizedLocaleIdentifier(_ identifier: String) -> String {
    var value = identifier
    if let range = value.range(of: "@") {
        value = String(value[..<range.lowerBound])
    }
    return value.replacingOccurrences(of: "_", with: "-").lowercased()
}

private func localeLanguage(_ normalizedIdentifier: String) -> String {
    return normalizedIdentifier.components(separatedBy: "-").first ?? normalizedIdentifier
}

private func localeRegion(_ normalizedIdentifier: String) -> String? {
    let components = normalizedIdentifier.components(separatedBy: "-")
    guard components.count > 1, let last = components.last else {
        return nil
    }
    if last.count == 2 || (last.count == 3 && last.allSatisfy({ $0.isNumber })) {
        return last
    }
    return nil
}

/// The region a bare language most likely means when neither the language nor the device names a usable one.
private let preferredRegionForLanguage: [String: String] = [
    "en": "us", "pt": "br", "zh": "cn", "ar": "sa", "uk": "ua", "ja": "jp", "ko": "kr", "he": "il",
    "sv": "se", "da": "dk", "cs": "cz", "el": "gr", "vi": "vn", "ms": "my", "hi": "in", "ca": "es",
    "nb": "no", "fa": "ir", "ur": "pk"
]

/// Recognizer locales to try, best first: the app's language, the device locale, the device's preferred
/// languages and finally en-US, each mapped onto a locale `SFSpeechRecognizer` supports.
private func recognizerLocaleCandidates(appLocale: String) -> [String] {
    let supported = SFSpeechRecognizer.supportedLocales().map({ $0.identifier }).sorted()
    let supportedNormalized = supported.map(normalizedLocaleIdentifier)
    let deviceRegion = localeRegion(normalizedLocaleIdentifier(Locale.current.identifier))

    var result: [String] = []
    func add(_ candidate: String) {
        let normalized = normalizedLocaleIdentifier(candidate)
        if normalized.isEmpty {
            return
        }
        if supported.isEmpty {
            if !result.contains(candidate) {
                result.append(candidate)
            }
            return
        }

        var index = supportedNormalized.firstIndex(of: normalized)
        if index == nil {
            let language = localeLanguage(normalized)
            var regions: [String] = []
            if let region = localeRegion(normalized) {
                regions.append(region)
            }
            if let deviceRegion {
                regions.append(deviceRegion)
            }
            if let region = preferredRegionForLanguage[language] {
                regions.append(region)
            }
            regions.append(language)
            for region in regions {
                if let regionIndex = supportedNormalized.firstIndex(of: "\(language)-\(region)") {
                    index = regionIndex
                    break
                }
            }
            if index == nil {
                index = supportedNormalized.firstIndex(where: { localeLanguage($0) == language })
            }
        }
        if let index, !result.contains(supported[index]) {
            result.append(supported[index])
        }
    }

    add(appLocale)
    add(Locale.current.identifier)
    for language in Locale.preferredLanguages.prefix(2) {
        add(language)
    }
    add("en-US")
    return result
}

private func speechRecognitionAuthorized() -> Signal<Bool, NoError> {
    return Signal { subscriber in
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            subscriber.putNext(true)
            subscriber.putCompletion()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                subscriber.putNext(status == .authorized)
                subscriber.putCompletion()
            }
        default:
            subscriber.putNext(false)
            subscriber.putCompletion()
        }
        return EmptyDisposable
    }
}

private func transcribeAudio(path: String, locale: String) -> Signal<TranscriptionResult?, NoError> {
    return Signal { subscriber in
        let speechRecognizer: SFSpeechRecognizer
        if let sharedRecognizer = sharedRecognizers[locale] {
            speechRecognizer = sharedRecognizer
        } else {
            guard let speechRecognizerValue = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
                subscriber.putNext(nil)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            speechRecognizerValue.defaultTaskHint = .dictation
            sharedRecognizers[locale] = speechRecognizerValue
            speechRecognizer = speechRecognizerValue
        }

        guard speechRecognizer.isAvailable else {
            subscriber.putNext(nil)
            subscriber.putCompletion()
            return EmptyDisposable
        }

        let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        // On the device whenever the recognizer can do this language there; it reports that itself.
        request.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = false

        let task = speechRecognizer.recognitionTask(with: request, resultHandler: { result, error in
            if let result = result {
                subscriber.putNext(TranscriptionResult(text: result.bestTranscription.formattedString, isFinal: result.isFinal))
                if result.isFinal {
                    subscriber.putCompletion()
                }
            } else {
                print("transcribeAudio: locale: \(locale), error: \(String(describing: error))")

                subscriber.putNext(nil)
                subscriber.putCompletion()
            }
        })

        return ActionDisposable {
            task.cancel()
        }
    }
    |> runOn(.mainQueue())
}

public struct LocallyTranscribedAudio {
    public var text: String
    public var isFinal: Bool
}

/// Whether the user (or a device policy) has refused speech recognition, so a local transcription cannot run.
public var isLocalAudioTranscriptionDenied: Bool {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .denied, .restricted:
        return true
    default:
        return false
    }
}

/// Transcribes the audio file at `path` with Apple's speech recognition, asking for permission first if needed.
///
/// `appLocale` (the app's language code, e.g. "en", "pt-br") is tried first, then the device locale and
/// languages, then en-US, each mapped onto a supported recognizer locale; the next one is tried when a locale
/// has no recognizer or fails. `pathExtension` names the file's format for AVFoundation: "m4a" for AAC audio,
/// "mp4" for a video. Emits nil when nothing could be recognized or permission is denied.
public func transcribeAudio(path: String, appLocale: String, pathExtension: String = "m4a") -> Signal<LocallyTranscribedAudio?, NoError> {
    return speechRecognitionAuthorized()
    |> mapToSignal { authorized -> Signal<LocallyTranscribedAudio?, NoError> in
        if !authorized {
            return .single(nil)
        }

        let tempFilePath = NSTemporaryDirectory() + "/\(UInt64.random(in: 0 ... UInt64.max)).\(pathExtension)"
        do {
            try FileManager.default.copyItem(atPath: path, toPath: tempFilePath)
        } catch {
            return .single(nil)
        }

        var signal: Signal<TranscriptionResult?, NoError> = .single(nil)
        for locale in recognizerLocaleCandidates(appLocale: appLocale).prefix(3).reversed() {
            let fallback = signal
            signal = transcribeAudio(path: tempFilePath, locale: locale)
            |> mapToSignal { result -> Signal<TranscriptionResult?, NoError> in
                if let result {
                    return .single(result)
                } else {
                    return fallback
                }
            }
        }

        return signal
        |> map { result -> LocallyTranscribedAudio? in
            return result.flatMap { result in
                return LocallyTranscribedAudio(text: result.text, isFinal: result.isFinal)
            }
        }
        |> afterDisposed {
            let _ = try? FileManager.default.removeItem(atPath: tempFilePath)
        }
    }
}
