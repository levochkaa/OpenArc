CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS app_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  apple_subject text NOT NULL UNIQUE,
  email text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  name text NOT NULL,
  platform text NOT NULL,
  public_key text,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS devices_user_id_idx ON devices(user_id);

CREATE TABLE IF NOT EXISTS spaces (
  id text NOT NULL,
  user_id uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  title text NOT NULL,
  system_image_name text NOT NULL,
  rank double precision NOT NULL,
  is_pinned_section_collapsed boolean NOT NULL DEFAULT false,
  selected_tab_id text,
  deleted_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  revision bigint NOT NULL DEFAULT 1,
  updated_by_device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
  PRIMARY KEY (user_id, id)
);

CREATE INDEX IF NOT EXISTS spaces_user_updated_idx ON spaces(user_id, updated_at);

CREATE TABLE IF NOT EXISTS tabs (
  id text NOT NULL,
  user_id uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  space_id text NOT NULL,
  placement text NOT NULL CHECK (placement IN ('temporary', 'spacePinned', 'app')),
  rank double precision NOT NULL,
  url_string text NOT NULL,
  title text,
  user_title_override text,
  favicon_url_string text,
  last_activity_at timestamptz,
  deleted_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  revision bigint NOT NULL DEFAULT 1,
  updated_by_device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
  PRIMARY KEY (user_id, id)
);

CREATE INDEX IF NOT EXISTS tabs_user_space_rank_idx ON tabs(user_id, space_id, placement, rank);
CREATE INDEX IF NOT EXISTS tabs_user_updated_idx ON tabs(user_id, updated_at);

CREATE TABLE IF NOT EXISTS sync_events (
  server_seq bigserial PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
  entity_type text NOT NULL CHECK (entity_type IN ('space', 'tab')),
  entity_id text NOT NULL,
  op text NOT NULL CHECK (op IN ('upsert', 'delete')),
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sync_events_user_seq_idx ON sync_events(user_id, server_seq);
