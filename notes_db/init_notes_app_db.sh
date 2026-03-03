#!/bin/bash
set -euo pipefail

# Notes DB initialization (schema + seed) for NoteMaster.
#
# Conventions:
# - Always connect using db_connection.txt (written by startup.sh)
# - Execute statements one-by-one via psql -c, keeping seed re-runnable (idempotent)
#
# Usage:
#   cd notes_db
#   ./init_notes_app_db.sh
#
# This script is safe to run multiple times.

if [ ! -f "db_connection.txt" ]; then
  echo "ERROR: db_connection.txt not found. Run ./startup.sh first (or ensure Postgres is running and db_connection.txt exists)."
  exit 1
fi

DB_CONN_CMD="$(cat db_connection.txt)"

# Helper to execute a single SQL statement.
run_sql() {
  local sql="$1"
  echo "→ $sql"
  # Note: db_connection.txt typically contains: psql postgresql://...
  # We append -v ON_ERROR_STOP=1 for safety.
  ${DB_CONN_CMD} -v ON_ERROR_STOP=1 -c "$sql"
}

echo "Initializing NoteMaster schema + seed..."

# --- Extensions (uuid generation) ---
run_sql "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

# --- Timestamp trigger function ---
# Uses standard dollar quoting to avoid escaping issues.
run_sql "CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS \$\$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
\$\$ LANGUAGE plpgsql;"

# --- Tables ---
run_sql "CREATE TABLE IF NOT EXISTS notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 200),
  content text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);"

run_sql "CREATE TABLE IF NOT EXISTS tags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE CHECK (char_length(name) BETWEEN 1 AND 50),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);"

run_sql "CREATE TABLE IF NOT EXISTS note_tags (
  note_id uuid NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  tag_id uuid NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (note_id, tag_id)
);"

# --- Triggers (idempotent) ---
run_sql "DROP TRIGGER IF EXISTS trg_notes_set_updated_at ON notes;"
run_sql "CREATE TRIGGER trg_notes_set_updated_at
BEFORE UPDATE ON notes
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();"

run_sql "DROP TRIGGER IF EXISTS trg_tags_set_updated_at ON tags;"
run_sql "CREATE TRIGGER trg_tags_set_updated_at
BEFORE UPDATE ON tags
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();"

# --- Indexes (idempotent) ---
# Sorting / filtering
run_sql "CREATE INDEX IF NOT EXISTS idx_notes_updated_at_desc ON notes (updated_at DESC);"
run_sql "CREATE INDEX IF NOT EXISTS idx_note_tags_tag_id ON note_tags (tag_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_note_tags_note_id ON note_tags (note_id);"

# Search: title/content tsvector (english)
# We use a generated column for fast search + GIN index.
# Adding a generated column only if missing (Postgres doesn't support IF NOT EXISTS for ADD COLUMN in older versions cleanly).
run_sql "DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='notes' AND column_name='search_vector'
  ) THEN
    ALTER TABLE notes
      ADD COLUMN search_vector tsvector
      GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title,'')), 'A') ||
        setweight(to_tsvector('english', coalesce(content,'')), 'B')
      ) STORED;
  END IF;
END
\$\$;"

run_sql "CREATE INDEX IF NOT EXISTS idx_notes_search_vector_gin ON notes USING GIN (search_vector);"
run_sql "CREATE INDEX IF NOT EXISTS idx_tags_name ON tags (name);"

# --- Seed data (minimal demo; safe to re-run) ---
# Tags
run_sql "INSERT INTO tags (name) VALUES ('retro') ON CONFLICT (name) DO NOTHING;"
run_sql "INSERT INTO tags (name) VALUES ('work') ON CONFLICT (name) DO NOTHING;"
run_sql "INSERT INTO tags (name) VALUES ('personal') ON CONFLICT (name) DO NOTHING;"

# Notes (use fixed UUIDs so we can safely link note_tags via ON CONFLICT on PK)
run_sql "INSERT INTO notes (id, title, content)
VALUES (
  '11111111-1111-1111-1111-111111111111',
  'Welcome to NoteMaster',
  'This is a demo note. Create, edit, tag, and search notes.\\n\\nTip: try searching for \"retro\" or filtering by a tag.'
)
ON CONFLICT (id) DO NOTHING;"

run_sql "INSERT INTO notes (id, title, content)
VALUES (
  '22222222-2222-2222-2222-222222222222',
  'Keyboard shortcuts',
  '- Ctrl/Cmd+K: focus search (if supported by UI)\\n- Esc: close modal\\n- Ctrl/Cmd+Enter: save note'
)
ON CONFLICT (id) DO NOTHING;"

# Tag relationships (lookup tag_id by name, insert join rows; idempotent due to PK(note_id, tag_id))
run_sql "INSERT INTO note_tags (note_id, tag_id)
SELECT '11111111-1111-1111-1111-111111111111', id FROM tags WHERE name='retro'
ON CONFLICT DO NOTHING;"

run_sql "INSERT INTO note_tags (note_id, tag_id)
SELECT '22222222-2222-2222-2222-222222222222', id FROM tags WHERE name='work'
ON CONFLICT DO NOTHING;"

run_sql "INSERT INTO note_tags (note_id, tag_id)
SELECT '22222222-2222-2222-2222-222222222222', id FROM tags WHERE name='retro'
ON CONFLICT DO NOTHING;"

echo "✓ NoteMaster schema + seed applied successfully."
echo "You can verify with:"
echo "  ${DB_CONN_CMD} -c \"\\dt\""
echo "  ${DB_CONN_CMD} -c \"SELECT title, updated_at FROM notes ORDER BY updated_at DESC;\""
