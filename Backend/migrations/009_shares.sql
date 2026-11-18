-- Public links to a snapshot of a Space, a folder or a quote. Anyone with
-- the link can read the content; only the owner can list or remove it. The
-- content holds only what the owner chose to share, never the account.
CREATE TABLE IF NOT EXISTS shares (
  id text PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('space', 'folder', 'quote')),
  -- The shared Space or folder in the owner's sidebar, or the quote's digest:
  -- sharing it again updates the same link.
  source_id text NOT NULL,
  title text NOT NULL,
  -- The quote's opening words, for the owner's list.
  excerpt text,
  item_count integer NOT NULL DEFAULT 0,
  content jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS shares_source_idx ON shares(user_id, kind, source_id);
CREATE INDEX IF NOT EXISTS shares_user_updated_idx ON shares(user_id, updated_at DESC);

-- Each publish in the last hour, for the per-account rate limit.
CREATE TABLE IF NOT EXISTS share_publishes (
  user_id uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  published_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS share_publishes_user_idx ON share_publishes(user_id, published_at);
