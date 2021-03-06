//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import GRDB

// MARK: -

@objc
public class ReactionFinder: NSObject {

    @objc
    public let uniqueMessageId: String

    @objc
    public init(uniqueMessageId: String) {
        self.uniqueMessageId = uniqueMessageId
    }

    /// Returns the given users reaction if it exists, otherwise nil
    @objc
    public func reaction(for reactor: SignalServiceAddress, transaction: GRDBReadTransaction) -> OWSReaction? {
        if let reaction = reactionForUUID(reactor.uuid, transaction: transaction) {
            return reaction
        } else if let reaction = reactionForE164(reactor.phoneNumber, transaction: transaction) {
            return reaction
        } else {
            return nil
        }
    }

    private func reactionForUUID(_ uuid: UUID?, transaction: GRDBReadTransaction) -> OWSReaction? {
        guard let uuidString = uuid?.uuidString else { return nil }
        let sql = """
            SELECT * FROM \(ReactionRecord.databaseTableName)
            WHERE \(reactionColumn: .uniqueMessageId) = ?
            AND \(reactionColumn: .reactorUUID) = ?
        """
        return OWSReaction.grdbFetchOne(sql: sql, arguments: [uniqueMessageId, uuidString], transaction: transaction)
    }

    private func reactionForE164(_ e164: String?, transaction: GRDBReadTransaction) -> OWSReaction? {
        guard let e164 = e164 else { return nil }
        let sql = """
            SELECT * FROM \(ReactionRecord.databaseTableName)
            WHERE \(reactionColumn: .uniqueMessageId) = ?
            AND \(reactionColumn: .reactorE164) = ?
        """
        return OWSReaction.grdbFetchOne(sql: sql, arguments: [uniqueMessageId, e164], transaction: transaction)
    }

    /// Returns a list of all users who have reacted to this message with a given emoji
    @objc
    public func reactors(for emoji: String, transaction: GRDBReadTransaction) -> [SignalServiceAddress] {
        let sql = """
            SELECT * FROM \(ReactionRecord.databaseTableName)
            WHERE \(reactionColumn: .uniqueMessageId) = ?
            AND \(reactionColumn: .emoji) = ?
            ORDER BY \(reactionColumn: .id) DESC
        """
        let cursor = OWSReaction.grdbFetchCursor(sql: sql, arguments: [uniqueMessageId, emoji], transaction: transaction)

        var reactors = [SignalServiceAddress]()

        do {
            while let reaction = try cursor.next() {
                reactors.append(reaction.reactor)
            }
        } catch {
            owsFailDebug("unexpected error \(error)")
        }

        return reactors
    }

    /// Returns a list of all reactions to this message
    @objc
    public func allReactions(transaction: GRDBReadTransaction) -> [OWSReaction] {
        let sql = """
            SELECT * FROM \(ReactionRecord.databaseTableName)
            WHERE \(reactionColumn: .uniqueMessageId) = ?
            ORDER BY \(reactionColumn: .id) DESC
        """
        let cursor = OWSReaction.grdbFetchCursor(sql: sql, arguments: [uniqueMessageId], transaction: transaction)

        var reactions = [OWSReaction]()

        do {
            while let reaction = try cursor.next() {
                reactions.append(reaction)
            }
        } catch {
            owsFailDebug("unexpected error \(error)")
        }

        return reactions
    }

    /// Returns a list of reactions to this message that have yet to be read
    @objc
    public func unreadReactions(transaction: GRDBReadTransaction) -> [OWSReaction] {
        let sql = """
            SELECT * FROM \(ReactionRecord.databaseTableName)
            WHERE \(reactionColumn: .uniqueMessageId) = ?
            AND \(reactionColumn: .read) IS 0
            ORDER BY \(reactionColumn: .id) DESC
        """
        let cursor = OWSReaction.grdbFetchCursor(sql: sql, arguments: [uniqueMessageId], transaction: transaction)

        var reactions = [OWSReaction]()

        do {
            while let reaction = try cursor.next() {
                reactions.append(reaction)
            }
        } catch {
            owsFailDebug("unexpected error \(error)")
        }

        return reactions
    }

    /// Returns a list of all emoji that have been reacted to this message, and the number
    /// of users who have sent that reaction, ordered from most to least frequent reaction
    public func emojiCounts(transaction: GRDBReadTransaction) -> [(emoji: String, count: Int)] {
        let sql = """
            SELECT COUNT(*) as count, \(reactionColumn: .emoji)
            FROM \(ReactionRecord.databaseTableName)
            WHERE \(reactionColumn: .uniqueMessageId) = ?
            GROUP BY \(reactionColumn: .emoji)
            ORDER BY count DESC
        """
        let sqlRequest = SQLRequest<Void>(sql: sql, arguments: [uniqueMessageId], cached: true)

        do {
            let rows = try Row.fetchAll(transaction.database, sqlRequest)
            return rows.map { (emoji: $0[1], count: $0[0]) }
        } catch {
            owsFailDebug("unexpected error \(error)")
            return []
        }
    }

    /// Returns true if any user has reacted to this message
    @objc
    public func existsReaction(transaction: GRDBReadTransaction) -> Bool {
        let sql = """
            SELECT EXISTS(
                SELECT 1
                FROM \(ReactionRecord.databaseTableName)
                WHERE \(reactionColumn: .uniqueMessageId) = ?
                LIMIT 1
            )
        """
        let arguments: StatementArguments = [uniqueMessageId]

        let exists: Bool
        do {
            exists = try Bool.fetchOne(transaction.database, sql: sql, arguments: arguments) ?? false
        } catch {
            owsFailDebug("Received unexpected error \(error)")
            exists = false
        }

        return exists
    }

    /// Iterate over all the reactions on this message, ordered by creation from oldest to newest
    @objc
    public func enumerateReactions(
        transaction: GRDBReadTransaction,
        block: @escaping (OWSReaction, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        let sql = """
            SELECT *
            FROM \(ReactionRecord.databaseTableName)
            WHERE \(reactionColumn: .uniqueMessageId) = ?
        """
        let cursor = OWSReaction.grdbFetchCursor(sql: sql, arguments: [uniqueMessageId], transaction: transaction)

        do {
            while let reaction = try cursor.next() {
                var stop: ObjCBool = false
                block(reaction, &stop)
                if stop.boolValue { break }
            }
        } catch {
            owsFailDebug("unexpected error \(error)")
        }
    }

    /// A list of all the unique reaction IDs linked to this message, ordered by creation from oldest to neweset
    @objc
    public func allUniqueIds(transaction: GRDBReadTransaction) -> [String] {
        let sql = """
            SELECT \(reactionColumn: .uniqueId)
            FROM \(ReactionRecord.databaseTableName)
            WHERE \(reactionColumn: .uniqueMessageId) = ?
        """
        let sqlRequest = SQLRequest<Void>(sql: sql, arguments: [uniqueMessageId], cached: true)

        do {
            let rows = try Row.fetchAll(transaction.database, sqlRequest)
            return rows.map { $0[0] }
        } catch {
            owsFailDebug("unexpected error \(error)")
            return []
        }
    }

    /// Delete all reaction records associated with this message
    @objc
    public func deleteAllReactions(transaction: GRDBWriteTransaction) {
        let sql = """
            DELETE FROM \(ReactionRecord.databaseTableName)
            WHERE \(reactionColumn: .uniqueMessageId) = ?
        """
        transaction.executeUpdate(sql: sql, arguments: [uniqueMessageId])
    }
}
