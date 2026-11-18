-- Site boosts: per-site CSS, JavaScript and hidden elements, last writer wins
-- per identity. Deletions use the shared permanent tombstones, so a re-created
-- boost for the same host takes a fresh identity.
CREATE TABLE boosts (
  id text NOT NULL,
  user_id uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  host text NOT NULL,
  is_enabled boolean NOT NULL,
  css text NOT NULL,
  java_script text NOT NULL,
  zapped_selectors jsonb NOT NULL,
  deleted_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  revision bigint NOT NULL DEFAULT 1,
  updated_by_device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
  PRIMARY KEY (user_id, id)
);

-- Readers before version 6 never receive boost events. Like the folder and
-- expiry markers, any older pull resets this one, and an upgrade replays from zero.
ALTER TABLE devices ADD COLUMN boost_sync_enabled boolean NOT NULL DEFAULT false;

ALTER TABLE sync_events DROP CONSTRAINT sync_events_entity_type_check;
ALTER TABLE sync_events ADD CONSTRAINT sync_events_entity_type_check
  CHECK (entity_type IN ('space', 'tab', 'folder', 'boost'));
ALTER TABLE sync_tombstones DROP CONSTRAINT sync_tombstones_entity_type_check;
ALTER TABLE sync_tombstones ADD CONSTRAINT sync_tombstones_entity_type_check
  CHECK (entity_type IN ('space', 'tab', 'folder', 'boost'));
