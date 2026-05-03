import Foundation
import CryptoKit

/// Generates Postgres DDL for the v2 mirror.
///
/// Schema shape:
///   - `memories` carries canonical metadata; **no embedding column**.
///   - `embedding_profiles` registers each (backend, model_name, dim, seq_len).
///   - `memory_embeddings_<profile_safe_id>` holds the vectors for one profile.
///     pgvector columns require fixed dimension, so heterogeneous backends each
///     get their own table rather than a single wide column.
///   - `entity_mentions`, `entities`, `relations`, `tags`, `memory_tags` mirror
///     the Core Data graph for SQL joins.
public enum SchemaGenerator {
    public struct ProfileDescriptor: Sendable, Equatable {
        public let id: String        // logical, e.g. "minilm-l6-v2"
        public let backend: String   // "coreml" / "nl"
        public let modelName: String
        public let dim: Int
        public let seqLen: Int

        public init(id: String, backend: String, modelName: String, dim: Int, seqLen: Int) {
            self.id = id; self.backend = backend; self.modelName = modelName
            self.dim = dim; self.seqLen = seqLen
        }

        /// Sanitized id + 6-hex-char hash of (id, backend, dim).
        /// The hash defends against collisions when two distinct logical profiles
        /// sanitize to the same Postgres identifier (e.g. "x.y" and "x-y" both
        /// become "x_y"), and against accidental cross-vector-space joins
        /// (different backends or dims of the same human name).
        public var safeID: String {
            let base = SchemaGenerator.sanitize(id)
            let key  = "\(id)|\(backend)|\(dim)"
            let h    = SHA256.hash(data: Data(key.utf8))
            let hex  = h.prefix(3).map { String(format: "%02x", $0) }.joined()  // 6 chars
            return "\(base)_\(hex)"
        }

        public var embeddingsTable: String { "memory_embeddings_\(safeID)" }
    }

    /// Derive a descriptor straight from the live enricher. Single source of
    /// truth: profile id, backend label, and dimension all come from the same
    /// running enricher, so remember-stamping, profile registration, table
    /// naming, and recall SQL can never disagree.
    public static func descriptor(
        enricher: any Enricher,
        modelName: String,
        seqLen: Int
    ) -> ProfileDescriptor {
        ProfileDescriptor(
            id: enricher.profile,
            backend: enricher.backend,
            modelName: modelName,
            dim: enricher.dimension,
            seqLen: seqLen
        )
    }

    /// Canonical schema split into individual statements so a Postgres client
    /// that sends one statement per round-trip (postgres-nio) can apply each.
    public static var canonicalStatements: [String] {
        var out: [String] = []
        out.append("CREATE EXTENSION IF NOT EXISTS vector")
        out.append("""
        CREATE TABLE IF NOT EXISTS memories (
            id UUID PRIMARY KEY,
            text TEXT NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            occurred_at TIMESTAMPTZ,
            source TEXT,
            conversation_id TEXT,
            language TEXT,
            sentiment DOUBLE PRECISION,
            metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
            search_document TSVECTOR,
            tombstoned BOOLEAN NOT NULL DEFAULT FALSE
        )
        """)
        out.append("CREATE INDEX IF NOT EXISTS memories_occurred_at_idx ON memories (occurred_at DESC)")
        out.append("CREATE INDEX IF NOT EXISTS memories_created_at_idx  ON memories (created_at DESC)")
        out.append("CREATE INDEX IF NOT EXISTS memories_source_idx      ON memories (source)")
        out.append("CREATE INDEX IF NOT EXISTS memories_conversation_idx ON memories (conversation_id)")
        out.append("CREATE INDEX IF NOT EXISTS memories_search_doc_gin  ON memories USING GIN (search_document)")
        out.append("""
        CREATE OR REPLACE FUNCTION memories_search_document_trigger() RETURNS trigger AS $$
        BEGIN
            NEW.search_document :=
                setweight(to_tsvector('english', coalesce(NEW.text, '')), 'A') ||
                setweight(to_tsvector('english', coalesce(NEW.source, '')), 'B') ||
                setweight(to_tsvector('english', coalesce(NEW.conversation_id, '')), 'C');
            RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """)
        out.append("DROP TRIGGER IF EXISTS memories_search_document_update ON memories")
        out.append("""
        CREATE TRIGGER memories_search_document_update
            BEFORE INSERT OR UPDATE OF text, source, conversation_id ON memories
            FOR EACH ROW EXECUTE FUNCTION memories_search_document_trigger()
        """)
        out.append("""
        CREATE TABLE IF NOT EXISTS embedding_profiles (
            id           TEXT PRIMARY KEY,
            backend      TEXT NOT NULL,
            model_name   TEXT NOT NULL,
            dim          INTEGER NOT NULL,
            seq_len      INTEGER,
            created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """)
        out.append("""
        CREATE TABLE IF NOT EXISTS entities (
            id UUID PRIMARY KEY,
            canonical_name TEXT NOT NULL,
            entity_type    TEXT NOT NULL,
            aliases        JSONB NOT NULL DEFAULT '[]'::jsonb
        )
        """)
        out.append("CREATE INDEX IF NOT EXISTS entities_name_idx ON entities (canonical_name)")
        out.append("CREATE INDEX IF NOT EXISTS entities_type_idx ON entities (entity_type)")
        out.append("""
        CREATE TABLE IF NOT EXISTS mentions (
            id           UUID PRIMARY KEY,
            memory_id    UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            entity_id    UUID NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            start_offset INTEGER NOT NULL,
            end_offset   INTEGER NOT NULL
        )
        """)
        out.append("CREATE INDEX IF NOT EXISTS mentions_memory_idx ON mentions (memory_id)")
        out.append("CREATE INDEX IF NOT EXISTS mentions_entity_idx ON mentions (entity_id)")
        out.append("""
        CREATE TABLE IF NOT EXISTS relations (
            id                   UUID PRIMARY KEY,
            subject_entity_id    UUID NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            predicate            TEXT NOT NULL,
            object_entity_id     UUID NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            provenance_memory_id UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """)
        out.append("CREATE INDEX IF NOT EXISTS relations_subject_idx ON relations (subject_entity_id)")
        out.append("CREATE INDEX IF NOT EXISTS relations_object_idx  ON relations (object_entity_id)")
        out.append("""
        CREATE TABLE IF NOT EXISTS tags (
            id   UUID PRIMARY KEY,
            name TEXT NOT NULL UNIQUE
        )
        """)
        out.append("""
        CREATE TABLE IF NOT EXISTS memory_tags (
            memory_id UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            tag_id    UUID NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            PRIMARY KEY (memory_id, tag_id)
        )
        """)
        return out
    }

    /// Per-profile statements. Caller binds nothing; values are inlined safely
    /// because they come from the trusted descriptor.
    public static func profileStatements(_ p: ProfileDescriptor) -> [String] {
        let table = p.embeddingsTable
        // Use postgres dollar-quoting for any text values to keep us safe even though
        // values come from a trusted descriptor.
        return [
            """
            INSERT INTO embedding_profiles (id, backend, model_name, dim, seq_len)
            VALUES (\(quote(p.id)), \(quote(p.backend)), \(quote(p.modelName)), \(p.dim), \(p.seqLen))
            ON CONFLICT (id) DO UPDATE
                SET backend = EXCLUDED.backend,
                    model_name = EXCLUDED.model_name,
                    dim = EXCLUDED.dim,
                    seq_len = EXCLUDED.seq_len
            """,
            """
            CREATE TABLE IF NOT EXISTS \(table) (
                memory_id  UUID PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
                embedding  VECTOR(\(p.dim)) NOT NULL,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """,
            "CREATE INDEX IF NOT EXISTS \(table)_hnsw_cosine ON \(table) USING hnsw (embedding vector_cosine_ops)",
            "CREATE INDEX IF NOT EXISTS \(table)_updated_at_idx ON \(table) (updated_at DESC)"
        ]
    }

    private static func quote(_ s: String) -> String {
        // Dollar-quoted string literal; tag chosen to avoid collision with content.
        let tag = "cmm"
        return "$\(tag)$\(s)$\(tag)$"
    }

    /// Canonical schema as a single string (kept for sql/pgvector_schema.sql parity).
    public static let canonicalDDL: String = #"""
    CREATE EXTENSION IF NOT EXISTS vector;

    CREATE TABLE IF NOT EXISTS memories (
        id UUID PRIMARY KEY,
        text TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        occurred_at TIMESTAMPTZ,
        source TEXT,
        conversation_id TEXT,
        language TEXT,
        sentiment DOUBLE PRECISION,
        metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
        search_document TSVECTOR,
        tombstoned BOOLEAN NOT NULL DEFAULT FALSE
    );
    CREATE INDEX IF NOT EXISTS memories_occurred_at_idx ON memories (occurred_at DESC);
    CREATE INDEX IF NOT EXISTS memories_created_at_idx  ON memories (created_at DESC);
    CREATE INDEX IF NOT EXISTS memories_source_idx      ON memories (source);
    CREATE INDEX IF NOT EXISTS memories_conversation_idx ON memories (conversation_id);
    CREATE INDEX IF NOT EXISTS memories_search_doc_gin  ON memories USING GIN (search_document);

    CREATE OR REPLACE FUNCTION memories_search_document_trigger() RETURNS trigger AS $$
    BEGIN
        NEW.search_document :=
            setweight(to_tsvector('english', coalesce(NEW.text, '')), 'A') ||
            setweight(to_tsvector('english', coalesce(NEW.source, '')), 'B') ||
            setweight(to_tsvector('english', coalesce(NEW.conversation_id, '')), 'C');
        RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    DROP TRIGGER IF EXISTS memories_search_document_update ON memories;
    CREATE TRIGGER memories_search_document_update
        BEFORE INSERT OR UPDATE OF text, source, conversation_id ON memories
        FOR EACH ROW EXECUTE FUNCTION memories_search_document_trigger();

    CREATE TABLE IF NOT EXISTS embedding_profiles (
        id           TEXT PRIMARY KEY,
        backend      TEXT NOT NULL,
        model_name   TEXT NOT NULL,
        dim          INTEGER NOT NULL,
        seq_len      INTEGER,
        created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE TABLE IF NOT EXISTS entities (
        id UUID PRIMARY KEY,
        canonical_name TEXT NOT NULL,
        entity_type    TEXT NOT NULL,
        aliases        JSONB NOT NULL DEFAULT '[]'::jsonb
    );
    CREATE INDEX IF NOT EXISTS entities_name_idx ON entities (canonical_name);
    CREATE INDEX IF NOT EXISTS entities_type_idx ON entities (entity_type);

    CREATE TABLE IF NOT EXISTS mentions (
        id           UUID PRIMARY KEY,
        memory_id    UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
        entity_id    UUID NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
        start_offset INTEGER NOT NULL,
        end_offset   INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS mentions_memory_idx ON mentions (memory_id);
    CREATE INDEX IF NOT EXISTS mentions_entity_idx ON mentions (entity_id);

    CREATE TABLE IF NOT EXISTS relations (
        id                   UUID PRIMARY KEY,
        subject_entity_id    UUID NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
        predicate            TEXT NOT NULL,
        object_entity_id     UUID NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
        provenance_memory_id UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
        created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE INDEX IF NOT EXISTS relations_subject_idx ON relations (subject_entity_id);
    CREATE INDEX IF NOT EXISTS relations_object_idx  ON relations (object_entity_id);

    CREATE TABLE IF NOT EXISTS tags (
        id   UUID PRIMARY KEY,
        name TEXT NOT NULL UNIQUE
    );

    CREATE TABLE IF NOT EXISTS memory_tags (
        memory_id UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
        tag_id    UUID NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
        PRIMARY KEY (memory_id, tag_id)
    );
    """#

    /// Per-profile DDL.  One table + one HNSW cosine index per active profile.
    public static func profileDDL(_ p: ProfileDescriptor) -> String {
        let table = p.embeddingsTable
        return """
        INSERT INTO embedding_profiles (id, backend, model_name, dim, seq_len)
        VALUES ($$\(p.id)$$, $$\(p.backend)$$, $$\(p.modelName)$$, \(p.dim), \(p.seqLen))
        ON CONFLICT (id) DO UPDATE
            SET backend = EXCLUDED.backend,
                model_name = EXCLUDED.model_name,
                dim = EXCLUDED.dim,
                seq_len = EXCLUDED.seq_len;

        CREATE TABLE IF NOT EXISTS \(table) (
            memory_id  UUID PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
            embedding  VECTOR(\(p.dim)) NOT NULL,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
        );

        CREATE INDEX IF NOT EXISTS \(table)_hnsw_cosine
            ON \(table) USING hnsw (embedding vector_cosine_ops);
        CREATE INDEX IF NOT EXISTS \(table)_updated_at_idx
            ON \(table) (updated_at DESC);
        """
    }

    // MARK: hybrid recall (v2.5)
    //
    // The seed pool is the union of three independent branches: vector, lexical,
    // and entity-mention. Each branch returns up to its own K candidates with
    // its own score. Dedupe + rerank happens in the caller.
    //
    // Common bind plan (for vector + lexical + entity-mention):
    //   $1 from   timestamptz?
    //   $2 to     timestamptz?
    //   $3 source text?
    //   $4 conv   text?
    //   $5 limit  int
    // Plus the branch-specific lead bind (see below).

    /// Vector branch. Binds: $0 = query vector as text (cast `::vector`).
    /// Final placeholders: $1 vec, $2 from, $3 to, $4 source, $5 conv, $6 limit.
    public static func recallVectorQuery(_ p: ProfileDescriptor) -> String {
        let table = p.embeddingsTable
        return """
        SELECT m.id, m.text, m.created_at, m.occurred_at, m.source,
               m.conversation_id, m.language, m.sentiment,
               (1 - (e.embedding <=> $1::vector)) AS semantic_score,
               0.0::float8 AS lexical_score
          FROM memories m
          JOIN \(table) e ON e.memory_id = m.id
         WHERE m.tombstoned = FALSE
           AND ($2::timestamptz IS NULL OR m.occurred_at >= $2 OR (m.occurred_at IS NULL AND m.created_at >= $2))
           AND ($3::timestamptz IS NULL OR m.occurred_at <= $3 OR (m.occurred_at IS NULL AND m.created_at <= $3))
           AND ($4::text       IS NULL OR m.source = $4)
           AND ($5::text       IS NULL OR m.conversation_id = $5)
         ORDER BY e.embedding <=> $1::vector
         LIMIT $6;
        """
    }

    /// Lexical branch. Hits the GIN index on `search_document` via
    /// `websearch_to_tsquery`. Skips when the query yields no terms.
    /// Binds: $1 ts_query string, $2 from, $3 to, $4 source, $5 conv, $6 limit.
    public static let recallLexicalQuery: String = """
    SELECT m.id, m.text, m.created_at, m.occurred_at, m.source,
           m.conversation_id, m.language, m.sentiment,
           0.0::float8 AS semantic_score,
           ts_rank_cd(m.search_document, websearch_to_tsquery('english', $1)) AS lexical_score
      FROM memories m
     WHERE m.tombstoned = FALSE
       AND m.search_document @@ websearch_to_tsquery('english', $1)
       AND ($2::timestamptz IS NULL OR m.occurred_at >= $2 OR (m.occurred_at IS NULL AND m.created_at >= $2))
       AND ($3::timestamptz IS NULL OR m.occurred_at <= $3 OR (m.occurred_at IS NULL AND m.created_at <= $3))
       AND ($4::text       IS NULL OR m.source = $4)
       AND ($5::text       IS NULL OR m.conversation_id = $5)
     ORDER BY lexical_score DESC
     LIMIT $6;
    """

    /// Entity-mention branch. Surfaces memories that mention any entity in the
    /// query's NER set, regardless of vector/lexical rank. This is the main
    /// v2.5 fix for entity-name miss queries.
    /// Binds: $1 entity-name array text[], $2 from, $3 to, $4 source, $5 conv, $6 limit.
    public static let recallEntityMentionQuery: String = """
    SELECT DISTINCT ON (m.id)
           m.id, m.text, m.created_at, m.occurred_at, m.source,
           m.conversation_id, m.language, m.sentiment,
           0.0::float8 AS semantic_score,
           0.0::float8 AS lexical_score
      FROM memories m
      JOIN mentions men ON men.memory_id = m.id
      JOIN entities ent ON ent.id = men.entity_id
     WHERE m.tombstoned = FALSE
       AND lower(ent.canonical_name) = ANY ($1::text[])
       AND ($2::timestamptz IS NULL OR m.occurred_at >= $2 OR (m.occurred_at IS NULL AND m.created_at >= $2))
       AND ($3::timestamptz IS NULL OR m.occurred_at <= $3 OR (m.occurred_at IS NULL AND m.created_at <= $3))
       AND ($4::text       IS NULL OR m.source = $4)
       AND ($5::text       IS NULL OR m.conversation_id = $5)
     ORDER BY m.id, m.created_at DESC
     LIMIT $6;
    """

    /// Compatibility shim for existing callers; returns the vector branch.
    public static func recallQuery(_ p: ProfileDescriptor) -> String { recallVectorQuery(p) }

    /// Sanitize a profile id for use in a Postgres identifier (table name).
    /// Lowercases, replaces non-[a-z0-9_] with `_`, ensures it starts with a letter or underscore.
    public static func sanitize(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "_" {
                out.append(ch)
            } else {
                out.append("_")
            }
        }
        if let first = out.first, first.isNumber { out = "_" + out }
        return out.isEmpty ? "default" : out
    }
}
