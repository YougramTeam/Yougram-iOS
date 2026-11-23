import Foundation
import Postbox
import SwiftSignalKit

// MARK: - Advanced Forward Public Types

public struct YougramAdvancedForwardTarget: Equatable {
    public let peerId: EnginePeer.Id
    public let threadId: Int64?

    public init(peerId: EnginePeer.Id, threadId: Int64? = nil) {
        self.peerId = peerId
        self.threadId = threadId
    }
}

public struct YougramAdvancedForwardComment: Equatable {
    public let text: String
    public let entities: [MessageTextEntity]

    public init(text: String, entities: [MessageTextEntity] = []) {
        self.text = text
        self.entities = entities
    }
}

public struct YougramAdvancedForwardProgress: Equatable {
    public enum Phase: Equatable {
        case preparing
        case downloading(current: Int, total: Int, currentMediaProgress: Float)
        case sending(current: Int, total: Int)
    }

    public let phase: Phase
    public let fraction: Float
    public let isIndeterminate: Bool

    public init(phase: Phase, fraction: Float, isIndeterminate: Bool) {
        self.phase = phase
        self.fraction = fraction
        self.isIndeterminate = isIndeterminate
    }
}

public struct YougramAdvancedForwardResult: Equatable {
    public let sentMessageCount: Int
    public let targetCount: Int
    public let skippedMediaCount: Int

    public init(sentMessageCount: Int, targetCount: Int, skippedMediaCount: Int) {
        self.sentMessageCount = sentMessageCount
        self.targetCount = targetCount
        self.skippedMediaCount = skippedMediaCount
    }
}

public enum YougramAdvancedForwardEvent: Equatable {
    case progress(YougramAdvancedForwardProgress)
    case completed(YougramAdvancedForwardResult)
    case cancelled
    case failed(reason: String?)
}

// MARK: - Internal Plan Structures

private enum ExtractedMediaItem {
    case image(sourceMessage: Message, image: TelegramMediaImage, representation: TelegramMediaImageRepresentation)
    case file(sourceMessage: Message, file: TelegramMediaFile)
    case direct(media: Media, canAlbum: Bool)
}

private struct SourceStep {
    let sourceMessageId: MessageId?
    let text: String
    let attributes: [MessageAttribute]
    let inlineStickers: [MediaId: Media]
    let sourceGroupingKey: Int64?
    let isDeletedMessage: Bool
    let mediaItem: ExtractedMediaItem?
}

private struct PreparedStep {
    let text: String
    let attributes: [MessageAttribute]
    let inlineStickers: [MediaId: Media]
    let media: Media?
    let sourceGroupingKey: Int64?
    let canAlbum: Bool
}

// MARK: - Pure Helpers

private func filterAttributesForAdvancedForward(_ attributes: [MessageAttribute]) -> [MessageAttribute] {
    var result: [MessageAttribute] = []
    for attribute in attributes {
        if let entities = attribute as? TextEntitiesMessageAttribute {
            result.append(TextEntitiesMessageAttribute(entities: entities.entities))
        } else if attribute is MediaSpoilerMessageAttribute {
            result.append(MediaSpoilerMessageAttribute())
        } else if attribute is InvertMediaMessageAttribute {
            result.append(InvertMediaMessageAttribute())
        } else if let preview = attribute as? WebpagePreviewMessageAttribute {
            result.append(WebpagePreviewMessageAttribute(
                leadingPreview: preview.leadingPreview,
                forceLargeMedia: preview.forceLargeMedia,
                isManuallyAdded: preview.isManuallyAdded,
                isSafe: preview.isSafe
            ))
        }
    }
    return result
}

private func extractInlineStickers(from message: Message, attributes: [MessageAttribute]) -> [MediaId: Media] {
    var result: [MediaId: Media] = [:]
    for attribute in attributes {
        if let entitiesAttr = attribute as? TextEntitiesMessageAttribute {
            for entity in entitiesAttr.entities {
                if case let .CustomEmoji(_, fileId) = entity.type {
                    let mediaId = MediaId(namespace: Namespaces.Media.CloudFile, id: fileId)
                    if let stickerFile = message.associatedMedia[mediaId] as? TelegramMediaFile {
                        result[mediaId] = stickerFile
                    }
                }
            }
        }
    }
    return result
}

private func cleanFileAttributesForReupload(_ attributes: [TelegramMediaFileAttribute]) -> [TelegramMediaFileAttribute] {
    var result: [TelegramMediaFileAttribute] = []
    for attribute in attributes {
        switch attribute {
        case let .FileName(fileName):
            result.append(.FileName(fileName: fileName))
        case let .ImageSize(size):
            result.append(.ImageSize(size: size))
        case .Animated:
            result.append(.Animated)
        case let .Video(duration, size, flags, _, coverTime, videoCodec):
            result.append(.Video(duration: duration, size: size, flags: flags, preloadSize: nil, coverTime: coverTime, videoCodec: videoCodec))
        case let .Audio(isVoice, duration, title, performer, waveform):
            result.append(.Audio(isVoice: isVoice, duration: duration, title: title, performer: performer, waveform: waveform))
        case .hintFileIsLarge:
            result.append(.hintFileIsLarge)
        case let .Sticker(displayText, _, maskData):
            // Drop pack reference so forwarded stickers don't retain restricted/deleted source references.
            result.append(.Sticker(displayText: displayText, packReference: nil, maskData: maskData))
        case .HasLinkedStickers, .hintIsValidated, .NoPremium, .CustomEmoji:
            break
        }
    }
    return result
}

private func canFileJoinAlbum(_ file: TelegramMediaFile) -> Bool {
    if file.isSticker || file.isAnimatedSticker || file.isCustomEmoji || file.isVoice || file.isInstantVideo || file.isAnimated {
        return false
    }
    return true
}

private func makeCleanPoll(_ poll: TelegramMediaPoll) -> TelegramMediaPoll {
    let emptyResults = TelegramMediaPollResults(
        voters: nil,
        totalVoters: nil,
        recentVoters: [],
        solution: nil,
        hasUnseenVotes: nil,
        canViewStats: false
    )
    let cleanOptions = poll.options.map { option in
        TelegramMediaPollOption(
            text: option.text,
            entities: option.entities,
            opaqueIdentifier: option.opaqueIdentifier,
            media: nil,
            date: nil,
            addedBy: nil
        )
    }
    return TelegramMediaPoll(
        pollId: MediaId(namespace: Namespaces.Media.LocalPoll, id: Int64.random(in: Int64.min ... Int64.max)),
        publicity: poll.publicity,
        kind: poll.kind,
        text: poll.text,
        textEntities: poll.textEntities,
        options: cleanOptions,
        correctAnswers: poll.correctAnswers,
        results: emptyResults,
        isClosed: false,
        deadlineTimeout: poll.deadlineTimeout,
        deadlineDate: nil,
        pollHash: 0,
        openAnswers: poll.openAnswers,
        revotingDisabled: poll.revotingDisabled,
        shuffleAnswers: poll.shuffleAnswers,
        hideResultsUntilClose: poll.hideResultsUntilClose,
        isCreator: false,
        attachedMedia: nil,
        restrictToSubscribers: poll.restrictToSubscribers,
        countries: poll.countries
    )
}

private func extractMediaItems(from message: Message) -> [ExtractedMediaItem] {
    if message.containsSecretMedia {
        return []
    }
    var items: [ExtractedMediaItem] = []
    for media in message.media {
        if media is TelegramMediaAction || media is TelegramMediaExpiredContent || media is TelegramMediaWebpage {
            continue
        }
        if let image = media as? TelegramMediaImage {
            if let rep = largestImageRepresentation(image.representations) {
                items.append(.image(sourceMessage: message, image: image, representation: rep))
            }
        } else if let file = media as? TelegramMediaFile {
            items.append(.file(sourceMessage: message, file: file))
        } else if let paid = media as? TelegramMediaPaidContent {
            for extended in paid.extendedMedia {
                if case let .full(innerMedia) = extended {
                    if let image = innerMedia as? TelegramMediaImage {
                        if let rep = largestImageRepresentation(image.representations) {
                            items.append(.image(sourceMessage: message, image: image, representation: rep))
                        }
                    } else if let file = innerMedia as? TelegramMediaFile {
                        items.append(.file(sourceMessage: message, file: file))
                    }
                }
            }
        } else if let map = media as? TelegramMediaMap {
            let staticMap = TelegramMediaMap(
                latitude: map.latitude,
                longitude: map.longitude,
                heading: nil,
                accuracyRadius: map.accuracyRadius,
                venue: map.venue,
                address: map.address,
                liveBroadcastingTimeout: nil,
                liveProximityNotificationRadius: nil
            )
            items.append(.direct(media: staticMap, canAlbum: false))
        } else if let contact = media as? TelegramMediaContact {
            items.append(.direct(media: contact, canAlbum: false))
        } else if let dice = media as? TelegramMediaDice {
            items.append(.direct(media: dice, canAlbum: false))
        } else if let poll = media as? TelegramMediaPoll {
            items.append(.direct(media: makeCleanPoll(poll), canAlbum: false))
        }
    }
    return items
}

private func buildSourceSteps(from messages: [Message]) -> [SourceStep] {
    var steps: [SourceStep] = []
    for message in messages {
        if message.containsSecretMedia {
            continue
        }
        let hasOnlyActionOrExpired = !message.media.isEmpty && message.media.allSatisfy {
            $0 is TelegramMediaAction || $0 is TelegramMediaExpiredContent
        }
        if hasOnlyActionOrExpired && message.text.isEmpty {
            continue
        }

        let cleanAttributes = filterAttributesForAdvancedForward(message.attributes)
        let inlineStickers = extractInlineStickers(from: message, attributes: cleanAttributes)
        let extractedItems = extractMediaItems(from: message)
        let isDeleted = message.isYougramDeleted

        if extractedItems.isEmpty {
            if !message.text.isEmpty {
                steps.append(SourceStep(
                    sourceMessageId: message.id,
                    text: message.text,
                    attributes: cleanAttributes,
                    inlineStickers: inlineStickers,
                    sourceGroupingKey: nil,
                    isDeletedMessage: isDeleted,
                    mediaItem: nil
                ))
            }
        } else {
            let fallbackGroupKey: Int64? = extractedItems.count > 1
                ? (message.groupingKey ?? Int64.random(in: Int64.min ... Int64.max))
                : message.groupingKey

            for (idx, item) in extractedItems.enumerated() {
                let isFirst = (idx == 0)
                steps.append(SourceStep(
                    sourceMessageId: message.id,
                    text: isFirst ? message.text : "",
                    attributes: isFirst ? cleanAttributes : [],
                    inlineStickers: isFirst ? inlineStickers : [:],
                    sourceGroupingKey: fallbackGroupKey,
                    isDeletedMessage: isDeleted,
                    mediaItem: item
                ))
            }
        }
    }
    return steps
}

private func resolvedCompletedSize(mediaBox: MediaBox, resource: MediaResource, fallbackSize: Int64?) -> Int64? {
    if let size = resource.size ?? fallbackSize {
        return size
    }
    if let path = mediaBox.completedResourcePath(resource),
       let attrs = try? FileManager.default.attributesOfItem(atPath: path),
       let size = (attrs[.size] as? NSNumber)?.int64Value {
        return size
    }
    return nil
}

private func copyPreviewRepresentationsIfLocal(
    mediaBox: MediaBox,
    representations: [TelegramMediaImageRepresentation]
) -> [TelegramMediaImageRepresentation] {
    var result: [TelegramMediaImageRepresentation] = []
    for rep in representations {
        guard let completedPath = mediaBox.completedResourcePath(rep.resource) else {
            continue
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: completedPath)
        let resolvedSize = rep.resource.size ?? (attrs?[.size] as? NSNumber)?.int64Value
        let localThumbResource = LocalFileMediaResource(
            fileId: Int64.random(in: Int64.min ... Int64.max),
            size: resolvedSize
        )
        mediaBox.copyResourceData(from: rep.resource.id, to: localThumbResource.id, synchronous: true)
        result.append(TelegramMediaImageRepresentation(
            dimensions: rep.dimensions,
            resource: localThumbResource,
            progressiveSizes: rep.progressiveSizes,
            immediateThumbnailData: rep.immediateThumbnailData,
            hasVideo: rep.hasVideo,
            isPersonal: false,
            typeHint: rep.typeHint
        ))
    }
    return result
}

private func makeLocalImageMedia(
    mediaBox: MediaBox,
    image: TelegramMediaImage,
    representation: TelegramMediaImageRepresentation
) -> TelegramMediaImage {
    let resolvedSize = resolvedCompletedSize(mediaBox: mediaBox, resource: representation.resource, fallbackSize: nil)
    let localResource = LocalFileMediaResource(
        fileId: Int64.random(in: Int64.min ... Int64.max),
        size: resolvedSize
    )
    mediaBox.copyResourceData(from: representation.resource.id, to: localResource.id, synchronous: true)
    let localRep = TelegramMediaImageRepresentation(
        dimensions: representation.dimensions,
        resource: localResource,
        progressiveSizes: [],
        immediateThumbnailData: nil,
        hasVideo: false,
        isPersonal: false,
        typeHint: representation.typeHint
    )
    return TelegramMediaImage(
        imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: Int64.random(in: Int64.min ... Int64.max)),
        representations: [localRep],
        videoRepresentations: [],
        immediateThumbnailData: image.immediateThumbnailData,
        emojiMarkup: nil,
        reference: nil,
        partialReference: nil,
        flags: [],
        video: nil
    )
}

private func makeLocalFileMedia(
    mediaBox: MediaBox,
    file: TelegramMediaFile
) -> TelegramMediaFile {
    let resolvedSize = resolvedCompletedSize(mediaBox: mediaBox, resource: file.resource, fallbackSize: file.size)
    let localResource = LocalFileMediaResource(
        fileId: Int64.random(in: Int64.min ... Int64.max),
        size: resolvedSize
    )
    mediaBox.copyResourceData(from: file.resource.id, to: localResource.id, synchronous: true)
    let copiedPreviews = copyPreviewRepresentationsIfLocal(mediaBox: mediaBox, representations: file.previewRepresentations)
    return TelegramMediaFile(
        fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)),
        partialReference: nil,
        resource: localResource,
        previewRepresentations: copiedPreviews,
        videoThumbnails: [],
        videoCover: nil,
        immediateThumbnailData: file.immediateThumbnailData,
        mimeType: file.mimeType,
        size: resolvedSize,
        attributes: cleanFileAttributesForReupload(file.attributes),
        alternativeRepresentations: []
    )
}

private func cloneMediaForAdditionalTarget(mediaBox: MediaBox, media: Media) -> Media {
    if let image = media as? TelegramMediaImage, let rep = image.representations.first {
        return makeLocalImageMedia(mediaBox: mediaBox, image: image, representation: rep)
    } else if let file = media as? TelegramMediaFile {
        return makeLocalFileMedia(mediaBox: mediaBox, file: file)
    } else if let poll = media as? TelegramMediaPoll {
        return makeCleanPoll(poll)
    }
    return media
}

private func makeOutgoingMessages(
    mediaBox: MediaBox,
    preparedSteps: [PreparedStep],
    target: YougramAdvancedForwardTarget,
    comment: YougramAdvancedForwardComment?,
    silent: Bool,
    scheduleTime: Int32?,
    repeatPeriod: Int32?,
    cloneResources: Bool
) -> [EnqueueMessage] {
    var extraAttributes: [MessageAttribute] = []
    if silent {
        extraAttributes.append(NotificationInfoMessageAttribute(flags: [.muted]))
    }
    if let scheduleTime {
        extraAttributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: scheduleTime, repeatPeriod: repeatPeriod))
    }

    var result: [EnqueueMessage] = []

    if let comment, !comment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        var commentAttrs: [MessageAttribute] = extraAttributes
        if !comment.entities.isEmpty {
            commentAttrs.append(TextEntitiesMessageAttribute(entities: comment.entities))
        }
        result.append(.message(
            text: comment.text,
            attributes: commentAttrs,
            inlineStickers: [:],
            mediaReference: nil,
            threadId: target.threadId,
            replyToMessageId: nil,
            replyToStoryId: nil,
            localGroupingKey: nil,
            correlationId: Int64.random(in: Int64.min ... Int64.max),
            bubbleUpEmojiOrStickersets: []
        ))
    }

    // Group contiguous/same-key album-compatible items into batches of at most 10.
    var rawGroupCounts: [Int64: Int] = [:]
    for step in preparedSteps where step.canAlbum {
        if let key = step.sourceGroupingKey {
            rawGroupCounts[key, default: 0] += 1
        }
    }

    var assignedGroupKeys: [Int64: (key: Int64, countInBatch: Int)] = [:]

    for step in preparedSteps {
        var localGroupingKey: Int64? = nil
        if step.canAlbum, let sourceKey = step.sourceGroupingKey, (rawGroupCounts[sourceKey] ?? 0) > 1 {
            if let existing = assignedGroupKeys[sourceKey], existing.countInBatch < 10 {
                localGroupingKey = existing.key
                assignedGroupKeys[sourceKey] = (existing.key, existing.countInBatch + 1)
            } else {
                let freshKey = Int64.random(in: Int64.min ... Int64.max)
                localGroupingKey = freshKey
                assignedGroupKeys[sourceKey] = (freshKey, 1)
            }
        }

        let finalMedia: Media?
        if let media = step.media {
            finalMedia = cloneResources ? cloneMediaForAdditionalTarget(mediaBox: mediaBox, media: media) : media
        } else {
            finalMedia = nil
        }

        if finalMedia == nil && step.text.isEmpty {
            continue
        }

        var attrs = step.attributes
        attrs.append(contentsOf: extraAttributes)

        result.append(.message(
            text: step.text,
            attributes: attrs,
            inlineStickers: step.inlineStickers,
            mediaReference: finalMedia.map { .standalone(media: $0) },
            threadId: target.threadId,
            replyToMessageId: nil,
            replyToStoryId: nil,
            localGroupingKey: localGroupingKey,
            correlationId: Int64.random(in: Int64.min ... Int64.max),
            bubbleUpEmojiOrStickersets: []
        ))
    }

    return result
}

// MARK: - Media Download Helper

private enum ResourceAcquireOutcome {
    case local
    case unavailable
    case cancelled
}

private func ensureResourceLocal(
    mediaBox: MediaBox,
    userLocation: MediaResourceUserLocation,
    userContentType: MediaResourceUserContentType,
    reference: MediaResourceReference,
    statsCategory: MediaResourceStatsCategory,
    isDeletedMessage: Bool,
    workQueue: Queue,
    cancelledFlag: Atomic<Bool>,
    activeResource: Atomic<MediaResource?>,
    activeTimer: Atomic<SwiftSignalKit.Timer?>,
    fetchDisposable: MetaDisposable,
    statusDisposable: MetaDisposable,
    progressUpdate: @escaping (Float) -> Void,
    completion: @escaping (ResourceAcquireOutcome) -> Void
) {
    let resource = reference.resource
    let completed = Atomic<Bool>(value: false)

    func finish(_ outcome: ResourceAcquireOutcome) {
        let alreadyFinished = completed.swap(true)
        if alreadyFinished {
            return
        }
        activeTimer.swap(nil)?.invalidate()
        let _ = activeResource.swap(nil)
        fetchDisposable.set(nil)
        statusDisposable.set(nil)
        completion(outcome)
    }

    func armInactivityTimer() {
        activeTimer.swap(nil)?.invalidate()
        let timeoutSeconds: Double = isDeletedMessage ? 12.0 : 45.0
        let timer = SwiftSignalKit.Timer(timeout: timeoutSeconds, repeat: false, completion: {
            workQueue.async {
                if !completed.with({ $0 }) {
                    mediaBox.cancelInteractiveResourceFetch(resource)
                    finish(cancelledFlag.with { $0 } ? .cancelled : .unavailable)
                }
            }
        }, queue: workQueue)
        let _ = activeTimer.swap(timer)
        timer.start()
    }

    let initialStatusSignal = mediaBox.resourceStatus(resource, approximateSynchronousValue: false)
    |> take(1)
    |> deliverOn(workQueue)

    let _ = initialStatusSignal.start(next: { status in
        if cancelledFlag.with({ $0 }) {
            finish(.cancelled)
            return
        }
        if case .Local = status {
            finish(.local)
            return
        }

        let _ = activeResource.swap(resource)
        armInactivityTimer()

        var lastProgress: Float = -1.0
        let statusSignal = mediaBox.resourceStatus(resource)
        |> deliverOn(workQueue)

        statusDisposable.set(statusSignal.start(next: { currentStatus in
            if cancelledFlag.with({ $0 }) {
                finish(.cancelled)
                return
            }
            switch currentStatus {
            case .Local:
                progressUpdate(1.0)
                finish(.local)
            case let .Fetching(_, progress):
                if abs(progress - lastProgress) >= 0.01 {
                    lastProgress = progress
                    armInactivityTimer()
                }
                progressUpdate(max(0.0, min(1.0, progress)))
            case let .Remote(progress):
                progressUpdate(max(0.0, min(1.0, progress)))
            case let .Paused(progress):
                progressUpdate(max(0.0, min(1.0, progress)))
            }
        }))

        let fetchSignal = fetchedMediaResource(
            mediaBox: mediaBox,
            userLocation: userLocation,
            userContentType: userContentType,
            reference: reference,
            statsCategory: statsCategory,
            continueInBackground: true
        )
        |> deliverOn(workQueue)

        fetchDisposable.set(fetchSignal.start(next: { sourceType in
            let _ = sourceType
            if cancelledFlag.with({ $0 }) {
                finish(.cancelled)
            }
        }, error: { _ in
            finish(cancelledFlag.with { $0 } ? .cancelled : .unavailable)
        }, completed: {
            workQueue.after(0.05) {
                if !completed.with({ $0 }) {
                    if mediaBox.completedResourcePath(resource) != nil {
                        progressUpdate(1.0)
                        finish(.local)
                    } else {
                        finish(.unavailable)
                    }
                }
            }
        }))
    })
}

// MARK: - TelegramEngine.Messages Extension

public extension TelegramEngine.Messages {
    func yougramAdvancedForward(
        messageIds: [EngineMessage.Id],
        targets: [YougramAdvancedForwardTarget],
        comment: YougramAdvancedForwardComment? = nil,
        silent: Bool = false,
        scheduleTime: Int32? = nil,
        repeatPeriod: Int32? = nil
    ) -> Signal<YougramAdvancedForwardEvent, NoError> {
        guard !messageIds.isEmpty, !targets.isEmpty else {
            return .single(.failed(reason: nil))
        }

        let account = self.account
        let uniqueSortedIds = Array(Set(messageIds)).sorted()

        return Signal { subscriber in
            let workQueue = Queue(name: "org.yougram.advancedForward")
            let cancelledFlag = Atomic<Bool>(value: false)
            let finishedFlag = Atomic<Bool>(value: false)
            let activeResource = Atomic<MediaResource?>(value: nil)
            let activeTimer = Atomic<SwiftSignalKit.Timer?>(value: nil)
            let fetchDisposable = MetaDisposable()
            let statusDisposable = MetaDisposable()
            let transactionDisposable = MetaDisposable()

            func emit(_ event: YougramAdvancedForwardEvent) {
                if finishedFlag.with({ $0 }) {
                    return
                }
                subscriber.putNext(event)
                switch event {
                case .completed, .cancelled, .failed:
                    let _ = finishedFlag.swap(true)
                    subscriber.putCompletion()
                case .progress:
                    break
                }
            }

            emit(.progress(YougramAdvancedForwardProgress(phase: .preparing, fraction: 0.0, isIndeterminate: true)))

            let loadSignal = account.postbox.transaction { transaction -> [Message] in
                var loaded: [Message] = []
                loaded.reserveCapacity(uniqueSortedIds.count)
                for id in uniqueSortedIds {
                    if let message = transaction.getMessage(id) {
                        loaded.append(message)
                    }
                }
                return loaded
            }
            |> deliverOn(workQueue)

            transactionDisposable.set(loadSignal.start(next: { messages in
                if cancelledFlag.with({ $0 }) {
                    emit(.cancelled)
                    return
                }

                let sourceSteps = buildSourceSteps(from: messages)
                if sourceSteps.isEmpty {
                    emit(.failed(reason: nil))
                    return
                }

                let downloadableIndices = sourceSteps.indices.filter { idx in
                    switch sourceSteps[idx].mediaItem {
                    case .image, .file:
                        return true
                    case .direct, .none:
                        return false
                    }
                }
                let totalDownloads = downloadableIndices.count
                let downloadPositionByStepIndex: [Int: Int] = {
                    var map: [Int: Int] = [:]
                    for (pos, stepIdx) in downloadableIndices.enumerated() {
                        map[stepIdx] = pos + 1
                    }
                    return map
                }()

                var preparedSteps: [PreparedStep] = []
                preparedSteps.reserveCapacity(sourceSteps.count)
                var skippedMediaCount = 0

                func sendAllTargets() {
                    if cancelledFlag.with({ $0 }) {
                        emit(.cancelled)
                        return
                    }
                    let validMessageCount = preparedSteps.filter { $0.media != nil || !$0.text.isEmpty }.count
                    if validMessageCount == 0 {
                        emit(.failed(reason: nil))
                        return
                    }

                    let mediaBox = account.postbox.mediaBox

                    func sendTarget(at targetIndex: Int) {
                        if cancelledFlag.with({ $0 }) {
                            emit(.cancelled)
                            return
                        }
                        if targetIndex >= targets.count {
                            emit(.completed(YougramAdvancedForwardResult(
                                sentMessageCount: validMessageCount,
                                targetCount: targets.count,
                                skippedMediaCount: skippedMediaCount
                            )))
                            return
                        }

                        let fraction = 0.90 + 0.10 * (Float(targetIndex) / Float(max(1, targets.count)))
                        emit(.progress(YougramAdvancedForwardProgress(
                            phase: .sending(current: targetIndex + 1, total: targets.count),
                            fraction: fraction,
                            isIndeterminate: false
                        )))

                        let outgoing = makeOutgoingMessages(
                            mediaBox: mediaBox,
                            preparedSteps: preparedSteps,
                            target: targets[targetIndex],
                            comment: comment,
                            silent: silent,
                            scheduleTime: scheduleTime,
                            repeatPeriod: repeatPeriod,
                            cloneResources: targetIndex > 0
                        )

                        if outgoing.isEmpty {
                            sendTarget(at: targetIndex + 1)
                            return
                        }

                        let _ = (enqueueMessages(account: account, peerId: targets[targetIndex].peerId, messages: outgoing)
                        |> deliverOn(workQueue)).start(next: { _ in
                            sendTarget(at: targetIndex + 1)
                        })
                    }

                    sendTarget(at: 0)
                }

                func acquireMediaStep(
                    step: SourceStep,
                    sourceMessage: Message,
                    reference: MediaResourceReference,
                    contentType: MediaResourceUserContentType,
                    statsCategory: MediaResourceStatsCategory,
                    currentDownloadNumber: Int,
                    onLocal: @escaping () -> (media: Media, canAlbum: Bool),
                    stepIndex: Int
                ) {
                    let initialFraction = 0.05 + 0.85 * (Float(max(0, currentDownloadNumber - 1)) / Float(max(1, totalDownloads)))
                    emit(.progress(YougramAdvancedForwardProgress(
                        phase: .downloading(current: currentDownloadNumber, total: max(1, totalDownloads), currentMediaProgress: 0.0),
                        fraction: initialFraction,
                        isIndeterminate: true
                    )))

                    ensureResourceLocal(
                        mediaBox: account.postbox.mediaBox,
                        userLocation: .peer(sourceMessage.id.peerId),
                        userContentType: contentType,
                        reference: reference,
                        statsCategory: statsCategory,
                        isDeletedMessage: step.isDeletedMessage,
                        workQueue: workQueue,
                        cancelledFlag: cancelledFlag,
                        activeResource: activeResource,
                        activeTimer: activeTimer,
                        fetchDisposable: fetchDisposable,
                        statusDisposable: statusDisposable,
                        progressUpdate: { mediaProgress in
                            let overall = 0.05 + 0.85 * ((Float(max(0, currentDownloadNumber - 1)) + mediaProgress) / Float(max(1, totalDownloads)))
                            emit(.progress(YougramAdvancedForwardProgress(
                                phase: .downloading(current: currentDownloadNumber, total: max(1, totalDownloads), currentMediaProgress: mediaProgress),
                                fraction: overall,
                                isIndeterminate: mediaProgress <= 0.001
                            )))
                        },
                        completion: { outcome in
                            switch outcome {
                            case .cancelled:
                                emit(.cancelled)
                            case .unavailable:
                                skippedMediaCount += 1
                                if !step.text.isEmpty {
                                    preparedSteps.append(PreparedStep(
                                        text: step.text,
                                        attributes: step.attributes,
                                        inlineStickers: step.inlineStickers,
                                        media: nil,
                                        sourceGroupingKey: nil,
                                        canAlbum: false
                                    ))
                                }
                                processStep(at: stepIndex + 1)
                            case .local:
                                let built = onLocal()
                                preparedSteps.append(PreparedStep(
                                    text: step.text,
                                    attributes: step.attributes,
                                    inlineStickers: step.inlineStickers,
                                    media: built.media,
                                    sourceGroupingKey: step.sourceGroupingKey,
                                    canAlbum: built.canAlbum
                                ))
                                processStep(at: stepIndex + 1)
                            }
                        }
                    )
                }

                func processStep(at index: Int) {
                    if cancelledFlag.with({ $0 }) {
                        emit(.cancelled)
                        return
                    }
                    if index >= sourceSteps.count {
                        sendAllTargets()
                        return
                    }

                    let step = sourceSteps[index]
                    guard let mediaItem = step.mediaItem else {
                        preparedSteps.append(PreparedStep(
                            text: step.text,
                            attributes: step.attributes,
                            inlineStickers: step.inlineStickers,
                            media: nil,
                            sourceGroupingKey: step.sourceGroupingKey,
                            canAlbum: false
                        ))
                        processStep(at: index + 1)
                        return
                    }

                    switch mediaItem {
                    case let .direct(media, canAlbum):
                        preparedSteps.append(PreparedStep(
                            text: step.text,
                            attributes: step.attributes,
                            inlineStickers: step.inlineStickers,
                            media: media,
                            sourceGroupingKey: step.sourceGroupingKey,
                            canAlbum: canAlbum
                        ))
                        processStep(at: index + 1)

                    case let .image(sourceMessage, image, representation):
                        let currentDownloadNumber = downloadPositionByStepIndex[index] ?? 1
                        let reference = AnyMediaReference.message(message: MessageReference(sourceMessage), media: image).resourceReference(representation.resource)
                        acquireMediaStep(
                            step: step,
                            sourceMessage: sourceMessage,
                            reference: reference,
                            contentType: .image,
                            statsCategory: .image,
                            currentDownloadNumber: currentDownloadNumber,
                            onLocal: {
                                let localImage = makeLocalImageMedia(
                                    mediaBox: account.postbox.mediaBox,
                                    image: image,
                                    representation: representation
                                )
                                return (localImage, true)
                            },
                            stepIndex: index
                        )

                    case let .file(sourceMessage, file):
                        let currentDownloadNumber = downloadPositionByStepIndex[index] ?? 1
                        let reference = AnyMediaReference.message(message: MessageReference(sourceMessage), media: file).resourceReference(file.resource)
                        let statsCategory = statsCategoryForFileWithAttributes(file.attributes)
                        let contentType = MediaResourceUserContentType(file: file)
                        acquireMediaStep(
                            step: step,
                            sourceMessage: sourceMessage,
                            reference: reference,
                            contentType: contentType,
                            statsCategory: statsCategory,
                            currentDownloadNumber: currentDownloadNumber,
                            onLocal: {
                                let localFile = makeLocalFileMedia(
                                    mediaBox: account.postbox.mediaBox,
                                    file: file
                                )
                                return (localFile, canFileJoinAlbum(localFile))
                            },
                            stepIndex: index
                        )
                    }
                }

                processStep(at: 0)
            }))

            return ActionDisposable {
                let _ = cancelledFlag.swap(true)
                activeTimer.swap(nil)?.invalidate()
                if let resource = activeResource.swap(nil) {
                    account.postbox.mediaBox.cancelInteractiveResourceFetch(resource)
                }
                workQueue.async {
                    transactionDisposable.dispose()
                    fetchDisposable.dispose()
                    statusDisposable.dispose()
                }
            }
        }
    }

    func yougramAdvancedForwardDeletedRecord(
        record: YougramDeletedMessageRecord,
        targets: [YougramAdvancedForwardTarget],
        comment: YougramAdvancedForwardComment? = nil,
        silent: Bool = false,
        scheduleTime: Int32? = nil,
        repeatPeriod: Int32? = nil
    ) -> Signal<YougramAdvancedForwardEvent, NoError> {
        guard !targets.isEmpty else {
            return .single(.failed(reason: nil))
        }

        let account = self.account
        return account.postbox.transaction { transaction -> Bool in
            return transaction.getMessage(record.messageId) != nil
        }
        |> mapToSignal { existsInPostbox -> Signal<YougramAdvancedForwardEvent, NoError> in
            if existsInPostbox {
                return self.yougramAdvancedForward(
                    messageIds: [record.messageId],
                    targets: targets,
                    comment: comment,
                    silent: silent,
                    scheduleTime: scheduleTime,
                    repeatPeriod: repeatPeriod
                )
            }

            let bodyText = record.text.isEmpty ? (record.mediaSummary ?? "") : record.text
            if bodyText.isEmpty && (comment?.text.isEmpty ?? true) {
                return .single(.failed(reason: nil))
            }

            return Signal { subscriber in
                let step = PreparedStep(
                    text: bodyText,
                    attributes: [],
                    inlineStickers: [:],
                    media: nil,
                    sourceGroupingKey: nil,
                    canAlbum: false
                )

                let disposables = DisposableSet()
                for (idx, target) in targets.enumerated() {
                    let fraction = 0.5 + 0.5 * (Float(idx) / Float(max(1, targets.count)))
                    subscriber.putNext(.progress(YougramAdvancedForwardProgress(
                        phase: .sending(current: idx + 1, total: targets.count),
                        fraction: fraction,
                        isIndeterminate: false
                    )))
                    let outgoing = makeOutgoingMessages(
                        mediaBox: account.postbox.mediaBox,
                        preparedSteps: step.text.isEmpty ? [] : [step],
                        target: target,
                        comment: comment,
                        silent: silent,
                        scheduleTime: scheduleTime,
                        repeatPeriod: repeatPeriod,
                        cloneResources: false
                    )
                    if !outgoing.isEmpty {
                        disposables.add(enqueueMessages(account: account, peerId: target.peerId, messages: outgoing).start())
                    }
                }
                subscriber.putNext(.completed(YougramAdvancedForwardResult(
                    sentMessageCount: step.text.isEmpty ? 0 : 1,
                    targetCount: targets.count,
                    skippedMediaCount: 0
                )))
                subscriber.putCompletion()

                return ActionDisposable {
                    disposables.dispose()
                }
            }
        }
    }
}
