# NoteMaster DB Schema (notes_db)

This container runs PostgreSQL (see `startup.sh`) and stores data for the notes app.

## Connection

Always connect using the connection string saved by `startup.sh`:

```bash
cd notes_db
psql "$(cat db_connection.txt)"
```

## Tables

### `notes`
- `id` UUID primary key
- `title` text (<= 200 chars)
- `content` text
- `created_at` timestamptz
- `updated_at` timestamptz (auto-maintained by trigger)

### `tags`
- `id` UUID primary key
- `name` text unique (1..50 chars)
- `created_at` timestamptz
- `updated_at` timestamptz (auto-maintained by trigger)

### `note_tags`
Join table (many-to-many)
- `note_id` UUID -> `notes(id)` ON DELETE CASCADE
- `tag_id` UUID -> `tags(id)` ON DELETE CASCADE
- composite primary key (`note_id`, `tag_id`)
- `created_at` timestamptz

## Constraints / Indexes

- `tags.name` unique + indexed
- `notes.updated_at` indexed (DESC) for efficient sorting
- `note_tags.tag_id` indexed for “notes by tag” queries

## Timestamps (`updated_at`)

A single trigger function is used for both `notes` and `tags`:
- `set_updated_at()` sets `NEW.updated_at = now()` before each update

## Seed Data (minimal demo)

Seed includes:
- tags: `retro`, `work`, `personal`
- notes: “Welcome to NoteMaster”, “Keyboard shortcuts”
- note_tags relationships for the above notes/tags

Seed operations are safe to re-run using `ON CONFLICT DO NOTHING` where applicable.

## How schema/seed are applied

Currently applied by running SQL commands via `psql -c ...` using `db_connection.txt` (same convention used by other scripts in this container).

If you need to recreate from scratch, use `backup_db.sh` / `restore_db.sh`, or drop tables manually then re-apply the DDL/DML one statement at a time.
