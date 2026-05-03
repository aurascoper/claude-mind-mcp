import CoreData
import Foundation

public enum MemoryEntity {
    public static let memory   = "MemoryRecord"
    public static let entity   = "EntityRecord"
    public static let mention  = "MentionRecord"
    public static let relation = "RelationRecord"
    public static let tag      = "TagRecord"
    public static let outbox   = "OutboxRecord"
}

public enum ManagedObjectModelBuilder {
    public static func make() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let memory   = entity(name: MemoryEntity.memory,   attrs: memoryAttributes())
        let entityE  = entity(name: MemoryEntity.entity,   attrs: entityAttributes())
        let mention  = entity(name: MemoryEntity.mention,  attrs: mentionAttributes())
        let relation = entity(name: MemoryEntity.relation, attrs: relationAttributes())
        let tag      = entity(name: MemoryEntity.tag,      attrs: tagAttributes())
        let outbox   = entity(name: MemoryEntity.outbox,   attrs: outboxAttributes())

        // Relationships ...
        let memoryMentions = relationship(name: "mentions", destination: mention, toMany: true, deleteRule: .cascadeDeleteRule)
        let mentionMemory  = relationship(name: "memory",   destination: memory,  toMany: false, deleteRule: .nullifyDeleteRule)
        memoryMentions.inverseRelationship = mentionMemory
        mentionMemory.inverseRelationship  = memoryMentions

        let entityMentions = relationship(name: "mentions", destination: mention, toMany: true, deleteRule: .cascadeDeleteRule)
        let mentionEntity  = relationship(name: "entity",   destination: entityE, toMany: false, deleteRule: .nullifyDeleteRule)
        entityMentions.inverseRelationship = mentionEntity
        mentionEntity.inverseRelationship  = entityMentions

        let entityOutgoing = relationship(name: "outgoingRelations", destination: relation, toMany: true, deleteRule: .cascadeDeleteRule)
        let relationSubject = relationship(name: "subject",          destination: entityE,  toMany: false, deleteRule: .nullifyDeleteRule)
        entityOutgoing.inverseRelationship = relationSubject
        relationSubject.inverseRelationship = entityOutgoing

        let entityIncoming = relationship(name: "incomingRelations", destination: relation, toMany: true, deleteRule: .cascadeDeleteRule)
        let relationObject = relationship(name: "object",            destination: entityE,  toMany: false, deleteRule: .nullifyDeleteRule)
        entityIncoming.inverseRelationship = relationObject
        relationObject.inverseRelationship = entityIncoming

        let relationProvenance = relationship(name: "provenanceMemory", destination: memory, toMany: false, deleteRule: .nullifyDeleteRule)
        let memoryProvenanceRelations = relationship(name: "provenanceRelations", destination: relation, toMany: true, deleteRule: .cascadeDeleteRule)
        relationProvenance.inverseRelationship = memoryProvenanceRelations
        memoryProvenanceRelations.inverseRelationship = relationProvenance

        let memoryTags = relationship(name: "tags",     destination: tag,    toMany: true,  deleteRule: .nullifyDeleteRule)
        let tagMemories = relationship(name: "memories", destination: memory, toMany: true,  deleteRule: .nullifyDeleteRule)
        memoryTags.inverseRelationship  = tagMemories
        tagMemories.inverseRelationship = memoryTags

        memory.properties   += [memoryMentions, memoryTags, memoryProvenanceRelations]
        entityE.properties  += [entityMentions, entityOutgoing, entityIncoming]
        mention.properties  += [mentionMemory, mentionEntity]
        relation.properties += [relationSubject, relationObject, relationProvenance]
        tag.properties      += [tagMemories]

        // Single-attribute fetch indexes on hot paths. Compound indexes deferred until profiling says otherwise.
        memory.indexes = [
            idx(memory, attr: "id",             name: "memory_id_idx"),
            idx(memory, attr: "createdAt",      name: "memory_createdAt_idx"),
            idx(memory, attr: "occurredAt",     name: "memory_occurredAt_idx"),
            idx(memory, attr: "source",         name: "memory_source_idx"),
            idx(memory, attr: "conversationID", name: "memory_conv_idx"),
            idx(memory, attr: "tombstoned",     name: "memory_tombstoned_idx")
        ]
        entityE.indexes = [
            idx(entityE, attr: "id",            name: "entity_id_idx"),
            idx(entityE, attr: "canonicalName", name: "entity_name_idx"),
            idx(entityE, attr: "type",          name: "entity_type_idx")
        ]
        mention.indexes = [
            idx(mention, attr: "id", name: "mention_id_idx")
        ]
        relation.indexes = [
            idx(relation, attr: "id",        name: "relation_id_idx"),
            idx(relation, attr: "predicate", name: "relation_predicate_idx"),
            idx(relation, attr: "createdAt", name: "relation_createdAt_idx")
        ]
        tag.indexes = [
            idx(tag, attr: "id",   name: "tag_id_idx"),
            idx(tag, attr: "name", name: "tag_name_idx")
        ]
        outbox.indexes = [
            idx(outbox, attr: "id",        name: "outbox_id_idx"),
            idx(outbox, attr: "recordID",  name: "outbox_recordID_idx"),
            idx(outbox, attr: "createdAt", name: "outbox_createdAt_idx")
        ]

        model.entities = [memory, entityE, mention, relation, tag, outbox]
        return model
    }

    private static func entity(name: String, attrs: [NSAttributeDescription]) -> NSEntityDescription {
        let e = NSEntityDescription()
        e.name = name
        e.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        e.properties = attrs
        return e
    }

    private static func attribute(
        _ name: String,
        type: NSAttributeType,
        optional: Bool = false,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = type
        a.isOptional = optional
        if let defaultValue { a.defaultValue = defaultValue }
        return a
    }

    private static func relationship(
        name: String,
        destination: NSEntityDescription,
        toMany: Bool,
        deleteRule: NSDeleteRule
    ) -> NSRelationshipDescription {
        let r = NSRelationshipDescription()
        r.name = name
        r.destinationEntity = destination
        r.minCount = 0
        r.maxCount = toMany ? 0 : 1
        r.deleteRule = deleteRule
        r.isOptional = true
        return r
    }

    private static func idx(_ entity: NSEntityDescription, attr: String, name: String) -> NSFetchIndexDescription {
        guard let property = entity.attributesByName[attr] else {
            fatalError("ManagedObjectModelBuilder: \(entity.name ?? "?") missing attribute \(attr) for index \(name)")
        }
        return NSFetchIndexDescription(
            name: name,
            elements: [NSFetchIndexElementDescription(property: property, collationType: .binary)]
        )
    }

    private static func memoryAttributes() -> [NSAttributeDescription] {
        [
            attribute("id",               type: .UUIDAttributeType),
            attribute("text",             type: .stringAttributeType),
            attribute("createdAt",        type: .dateAttributeType),
            attribute("occurredAt",       type: .dateAttributeType, optional: true),
            attribute("source",           type: .stringAttributeType, optional: true),
            attribute("conversationID",   type: .stringAttributeType, optional: true),
            attribute("language",         type: .stringAttributeType, optional: true),
            attribute("sentiment",        type: .doubleAttributeType, defaultValue: 0.0),
            attribute("embeddingBlob",    type: .binaryDataAttributeType, optional: true),
            attribute("embeddingBackend", type: .stringAttributeType, optional: true),
            attribute("embeddingProfile", type: .stringAttributeType, optional: true),
            attribute("embeddingDim",     type: .integer32AttributeType, defaultValue: 0),
            attribute("metadataJSON",     type: .binaryDataAttributeType, optional: true),
            attribute("tombstoned",       type: .booleanAttributeType, defaultValue: false)
        ]
    }

    private static func entityAttributes() -> [NSAttributeDescription] {
        [
            attribute("id",            type: .UUIDAttributeType),
            attribute("canonicalName", type: .stringAttributeType),
            attribute("type",          type: .stringAttributeType),
            attribute("aliasesJSON",   type: .binaryDataAttributeType, optional: true)
        ]
    }

    private static func mentionAttributes() -> [NSAttributeDescription] {
        [
            attribute("id",          type: .UUIDAttributeType),
            attribute("entityID",    type: .UUIDAttributeType, optional: true),
            attribute("startOffset", type: .integer64AttributeType, defaultValue: 0),
            attribute("endOffset",   type: .integer64AttributeType, defaultValue: 0)
        ]
    }

    private static func relationAttributes() -> [NSAttributeDescription] {
        [
            attribute("id",        type: .UUIDAttributeType),
            attribute("predicate", type: .stringAttributeType),
            attribute("createdAt", type: .dateAttributeType)
        ]
    }

    private static func tagAttributes() -> [NSAttributeDescription] {
        [
            attribute("id",   type: .UUIDAttributeType),
            attribute("name", type: .stringAttributeType)
        ]
    }

    private static func outboxAttributes() -> [NSAttributeDescription] {
        [
            attribute("id",            type: .UUIDAttributeType),
            attribute("recordType",    type: .stringAttributeType),
            attribute("recordID",      type: .UUIDAttributeType),
            attribute("operation",     type: .stringAttributeType),
            attribute("payloadJSON",   type: .binaryDataAttributeType, optional: true),
            attribute("createdAt",     type: .dateAttributeType),
            attribute("sentAt",        type: .dateAttributeType, optional: true),
            attribute("lastAttemptAt", type: .dateAttributeType, optional: true),
            attribute("lastError",     type: .stringAttributeType, optional: true),
            attribute("attemptCount",  type: .integer32AttributeType, defaultValue: 0)
        ]
    }
}
