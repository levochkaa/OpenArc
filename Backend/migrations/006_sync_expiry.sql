-- Earlier clients discard additive expiry recovery data while advancing their
-- cursor. Upgrading after any older pull must replay history from zero.
ALTER TABLE devices ADD COLUMN expiry_sync_enabled boolean NOT NULL DEFAULT false;

CREATE INDEX sync_events_user_entity_seq_idx
  ON sync_events (user_id, entity_type, entity_id, server_seq DESC);
