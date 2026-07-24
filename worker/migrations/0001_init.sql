-- Migration 0001: scenarios table.
-- Timestamps are ISO-8601 UTC strings (lexicographically ordered), matching the
-- client-supplied createdAt/updatedAt in shared/schema/scenario.schema.json.
CREATE TABLE IF NOT EXISTS scenarios (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  title TEXT NOT NULL,
  status TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  deleted_at TEXT,
  body TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_scenarios_account ON scenarios (account_id);
CREATE INDEX IF NOT EXISTS idx_scenarios_deleted
  ON scenarios (deleted_at) WHERE deleted_at IS NOT NULL;
