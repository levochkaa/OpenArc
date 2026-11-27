-- Mobile tabs: the tab list of a phone or tablet, kept apart from desktop
-- Spaces. The last committed write wins per identity, except the activity
-- instant, which keeps the maximum. Deletions use the shared permanent
-- tombstones, so a reopened page takes a fresh identity.
CREATE TABLE mobile_tabs (
  id text NOT NULL,
  user_id uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  url_string text NOT NULL,
  -- NULL until the page reports a title.
  title text,
  created_at timestamptz NOT NULL,
  -- NULL until a device reports activity; never lowered or erased.
  last_activity_at timestamptz,
  deleted_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  revision bigint NOT NULL DEFAULT 1,
  updated_by_device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
  PRIMARY KEY (user_id, id)
);

-- Readers before version 7 never receive mobile tab events. Like the folder,
-- expiry and boost markers, any older pull resets this one, and an upgrade
-- replays from zero.
ALTER TABLE devices ADD COLUMN mobile_tab_sync_enabled boolean NOT NULL DEFAULT false;

ALTER TABLE sync_events DROP CONSTRAINT sync_events_entity_type_check;
ALTER TABLE sync_events ADD CONSTRAINT sync_events_entity_type_check
  CHECK (entity_type IN ('space', 'tab', 'folder', 'boost', 'mobileTab'));
ALTER TABLE sync_tombstones DROP CONSTRAINT sync_tombstones_entity_type_check;
ALTER TABLE sync_tombstones ADD CONSTRAINT sync_tombstones_entity_type_check
  CHECK (entity_type IN ('space', 'tab', 'folder', 'boost', 'mobileTab'));
