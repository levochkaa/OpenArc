-- Folder identities and ranks share their account's canonical event history.
-- Parent lifetime/cycles are validated under the sync account transaction lock;
-- soft deletion must not cascade through foreign-key actions.
CREATE TABLE folders (
  id text NOT NULL,
  user_id uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  space_id text NOT NULL,
  parent_folder_id text,
  title text NOT NULL,
  system_image_name text,
  rank double precision NOT NULL,
  deleted_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  revision bigint NOT NULL DEFAULT 1,
  updated_by_device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
  PRIMARY KEY (user_id, id),
  CHECK (parent_folder_id IS NULL OR parent_folder_id <> id)
);

CREATE INDEX folders_user_parent_rank_idx ON folders(user_id, space_id, parent_folder_id, rank, id)
  WHERE deleted_at IS NULL;
CREATE INDEX folders_user_updated_idx ON folders(user_id, updated_at);

ALTER TABLE tabs ADD COLUMN pinned_folder_id text;
ALTER TABLE tabs ADD CONSTRAINT tabs_pinned_folder_placement_check
  CHECK (pinned_folder_id IS NULL OR placement = 'spacePinned');
CREATE INDEX tabs_user_folder_rank_idx ON tabs(user_id, space_id, pinned_folder_id, rank, id)
  WHERE placement = 'spacePinned' AND deleted_at IS NULL;

-- A legacy pull resets this marker. Upgrading or re-upgrading must replay from
-- cursor zero so folder events hidden from older readers cannot be skipped.
ALTER TABLE devices ADD COLUMN folder_sync_enabled boolean NOT NULL DEFAULT false;

ALTER TABLE sync_events DROP CONSTRAINT sync_events_entity_type_check;
ALTER TABLE sync_events ADD CONSTRAINT sync_events_entity_type_check
  CHECK (entity_type IN ('space', 'tab', 'folder'));
ALTER TABLE sync_tombstones DROP CONSTRAINT sync_tombstones_entity_type_check;
ALTER TABLE sync_tombstones ADD CONSTRAINT sync_tombstones_entity_type_check
  CHECK (entity_type IN ('space', 'tab', 'folder'));
