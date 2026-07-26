import Foundation

/// Loads the trackable quest subset and synchronizes it with `/api_get_member/questlist`.
/// The store is a value type: reducers can keep `QuestListSnapshot` as their authoritative state.
public struct QuestDefinitionStore: Sendable {
    private struct TrackRecord: Decodable {
        let type: Int
        let cond: [Int]
    }

    private struct TranslationRecord: Decodable {
        let code: String?
        let name: String?
        let desc: String?
    }

    public let definitions: [Int: QuestDefinition]
    private let resetCalendar: QuestResetCalendar

    public init(
        trackData: Data,
        translationData: Data? = nil,
        resetCalendar: QuestResetCalendar = QuestResetCalendar()
    ) throws {
        let decoder = JSONDecoder()
        let tracks: [String: TrackRecord]
        do {
            tracks = try decoder.decode([String: TrackRecord].self, from: trackData)
        } catch {
            throw QuestDefinitionStoreError.invalidJSON
        }

        let translations: [String: TranslationRecord]
        if let translationData {
            do {
                translations = try decoder.decode([String: TranslationRecord].self, from: translationData)
            } catch {
                throw QuestDefinitionStoreError.invalidJSON
            }
        } else {
            translations = [:]
        }

        var definitions: [Int: QuestDefinition] = [:]
        for (key, track) in tracks {
            guard let id = Int(key), id > 0, let resetKind = QuestResetKind(rawValue: track.type) else {
                throw QuestDefinitionStoreError.invalidTrackDefinition(id: key)
            }
            let translation = translations[key]
            definitions[id] = QuestDefinition(
                id: id,
                resetKind: resetKind,
                conditionTargets: track.cond,
                code: translation?.code,
                title: translation?.name,
                detail: translation?.desc
            )
        }
        self.definitions = definitions
        self.resetCalendar = resetCalendar
    }

    public func definition(for questID: Int) -> QuestDefinition? { definitions[questID] }

    /// Merges one quest-list response into the prior snapshot. Quest list responses may be
    /// paged, so entries absent from this response are retained rather than interpreted as stop.
    public func synchronize(
        apiListData: Data,
        previous: QuestListSnapshot = QuestListSnapshot(),
        at date: Date
    ) throws -> QuestListSnapshot {
        let serverItems = try decodeServerList(from: apiListData)
        return synchronize(serverItems: serverItems, previous: previous, at: date)
    }

    /// Envelope-native variant used by the unified pipeline. It avoids decoding
    /// the raw response a second time after `APIEnvelopeParser` validated it.
    public func synchronize(
        apiData: JSONValue,
        previous: QuestListSnapshot = QuestListSnapshot(),
        at date: Date
    ) throws -> QuestListSnapshot {
        guard let list = apiData.objectValue?["api_list"]?.arrayValue else {
            throw QuestDefinitionStoreError.invalidQuestList
        }
        let serverItems = try list.compactMap { value -> ServerItem? in
            if value.intValue == -1 { return nil }
            guard let object = value.objectValue,
                  let id = object.int("api_no"), id > 0 else {
                throw QuestDefinitionStoreError.invalidQuestList
            }
            return ServerItem(
                id: id,
                category: object.int("api_category") ?? 0,
                type: object.int("api_type") ?? 0,
                state: object.int("api_state") ?? 1,
                progressFlag: object.int("api_progress_flag") ?? 0,
                title: object["api_title"]?.stringValue ?? "",
                detail: object["api_detail"]?.stringValue ?? ""
            )
        }
        return synchronize(serverItems: serverItems, previous: previous, at: date)
    }

    private func synchronize(
        serverItems: [ServerItem],
        previous: QuestListSnapshot,
        at date: Date
    ) -> QuestListSnapshot {
        var snapshot = previous

        for server in serverItems {
            let definition = definitions[server.id]
            let precision: QuestTrackingPrecision = definition == nil ? .serverOnly : .exact
            let title = nonempty(definition?.title) ?? server.title
            let detail = nonempty(definition?.detail) ?? server.detail
            snapshot.items[server.id] = QuestListItem(
                id: server.id,
                category: server.category,
                type: server.type,
                state: server.state,
                serverProgressFlag: server.progressFlag,
                title: title,
                detail: detail,
                precision: precision
            )

            guard server.state >= 2 else {
                if var tracking = validTracking(snapshot.tracking[server.id], definition: definition, at: date) {
                    tracking.isActive = false
                    snapshot.tracking[server.id] = tracking
                } else {
                    snapshot.tracking.removeValue(forKey: server.id)
                }
                continue
            }

            if var tracking = validTracking(snapshot.tracking[server.id], definition: definition, at: date) {
                tracking.isActive = true
                snapshot.tracking[server.id] = tracking
            } else {
                snapshot.tracking[server.id] = makeTracking(
                    questID: server.id,
                    definition: definition,
                    active: true,
                    at: date
                )
            }
        }

        snapshot.updatedAt = date
        return snapshot
    }

    public func start(
        questID: Int,
        in snapshot: QuestListSnapshot,
        at date: Date
    ) throws -> QuestListSnapshot {
        guard var item = snapshot.items[questID] else {
            throw QuestDefinitionStoreError.questNotFound(questID)
        }
        var result = snapshot
        let definition = definitions[questID]
        item.state = max(2, item.state)
        result.items[questID] = item
        if var tracking = validTracking(result.tracking[questID], definition: definition, at: date) {
            tracking.isActive = true
            result.tracking[questID] = tracking
        } else {
            result.tracking[questID] = makeTracking(
                questID: questID, definition: definition, active: true, at: date
            )
        }
        result.updatedAt = date
        return result
    }

    public func stop(
        questID: Int,
        in snapshot: QuestListSnapshot,
        at date: Date
    ) throws -> QuestListSnapshot {
        guard var item = snapshot.items[questID] else {
            throw QuestDefinitionStoreError.questNotFound(questID)
        }
        var result = snapshot
        item.state = 1
        result.items[questID] = item
        if var tracking = validTracking(result.tracking[questID], definition: definitions[questID], at: date) {
            tracking.isActive = false
            result.tracking[questID] = tracking
        } else {
            result.tracking.removeValue(forKey: questID)
        }
        result.updatedAt = date
        return result
    }

    public func clear(
        questID: Int,
        in snapshot: QuestListSnapshot,
        at date: Date
    ) throws -> QuestListSnapshot {
        guard snapshot.items[questID] != nil else {
            throw QuestDefinitionStoreError.questNotFound(questID)
        }
        var result = snapshot
        result.items.removeValue(forKey: questID)
        result.tracking.removeValue(forKey: questID)
        result.completed.append(CompletedQuest(questID: questID, completedAt: date))
        result.updatedAt = date
        return result
    }

    private struct ServerItem {
        let id: Int
        let category: Int
        let type: Int
        let state: Int
        let progressFlag: Int
        let title: String
        let detail: String
    }

    private func decodeServerList(from data: Data) throws -> [ServerItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw QuestDefinitionStoreError.invalidJSON
        }
        let list: [Any]?
        if let array = root as? [Any] {
            list = array
        } else if let object = root as? [String: Any] {
            if let apiData = object["api_data"] as? [String: Any] {
                list = apiData["api_list"] as? [Any]
            } else {
                list = object["api_list"] as? [Any]
            }
        } else {
            list = nil
        }
        guard let list else { throw QuestDefinitionStoreError.invalidQuestList }

        return try list.compactMap { value in
            if let number = value as? NSNumber, number.intValue == -1 { return nil }
            guard let object = value as? [String: Any],
                  let id = integer(object["api_no"]), id > 0 else {
                throw QuestDefinitionStoreError.invalidQuestList
            }
            return ServerItem(
                id: id,
                category: integer(object["api_category"]) ?? 0,
                type: integer(object["api_type"]) ?? 0,
                state: integer(object["api_state"]) ?? 1,
                progressFlag: integer(object["api_progress_flag"]) ?? 0,
                title: string(object["api_title"]),
                detail: string(object["api_detail"])
            )
        }
    }

    private func validTracking(
        _ tracking: QuestTrackingState?,
        definition: QuestDefinition?,
        at date: Date
    ) -> QuestTrackingState? {
        guard let tracking else { return nil }
        guard let definition else { return tracking }
        if resetCalendar.isExpired(
            startedAt: tracking.startedAt,
            now: date,
            questID: tracking.questID,
            resetKind: definition.resetKind
        ) {
            return nil
        }
        return tracking
    }

    private func makeTracking(
        questID: Int,
        definition: QuestDefinition?,
        active: Bool,
        at date: Date
    ) -> QuestTrackingState {
        let count = definition?.conditionTargets.count ?? 0
        var counters = Array(repeating: 0, count: count)
        if [411, 607, 608].contains(questID), !counters.isEmpty { counters[0] = 1 }
        return QuestTrackingState(
            questID: questID,
            isActive: active,
            counters: counters,
            startedAt: date,
            precision: definition == nil ? .serverOnly : .exact
        )
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func string(_ value: Any?) -> String { value as? String ?? "" }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
