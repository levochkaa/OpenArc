-- Keep deletions independently of entity rows, including IDs deleted before their
-- first upload. No expiry is safe until every offline device has a reset protocol.
CREATE TABLE sync_tombstones (
  user_id uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  entity_type text NOT NULL CHECK (entity_type IN ('space', 'tab')),
  entity_id text NOT NULL,
  server_seq bigint NOT NULL REFERENCES sync_events(server_seq),
  PRIMARY KEY (user_id, entity_type, entity_id)
);

-- Preserve legacy deletions, including deletes for which no entity row existed.
-- A historical delete followed by an upsert was already restored under v1 rules;
-- do not retroactively discard that user's currently live data.
INSERT INTO sync_tombstones (user_id, entity_type, entity_id, server_seq)
SELECT user_id, entity_type, entity_id, server_seq
FROM (
  SELECT DISTINCT ON (user_id, entity_type, entity_id)
    user_id, entity_type, entity_id, server_seq, op
  FROM sync_events
  ORDER BY user_id, entity_type, entity_id, server_seq DESC
) AS latest
WHERE op = 'delete';

-- v1 did not cascade space deletions. Preserve their meaning for clients that
-- reconnect later and try to move a formerly orphaned child to another space.
-- A child already moved to a live space before migration remains untouched.
WITH deleted_children AS (
  UPDATE tabs t SET deleted_at = now(), updated_at = now(), revision = revision + 1
  FROM sync_tombstones s
  WHERE s.user_id = t.user_id AND s.entity_type = 'space' AND s.entity_id = t.space_id
    AND t.deleted_at IS NULL
  RETURNING t.user_id, t.id, t.updated_by_device_id
), deletion_events AS (
  INSERT INTO sync_events (user_id, device_id, entity_type, entity_id, op, payload)
  SELECT user_id, updated_by_device_id, 'tab', id, 'delete', jsonb_build_object('id', id)
  FROM deleted_children
  RETURNING user_id, entity_type, entity_id, server_seq
)
INSERT INTO sync_tombstones (user_id, entity_type, entity_id, server_seq)
SELECT user_id, entity_type, entity_id, server_seq FROM deletion_events
ON CONFLICT (user_id, entity_type, entity_id) DO NOTHING;
