-- Receipts survive device rotation, retries, and offline clients. Never expire a
-- receipt until the protocol can prove its mutation cannot be replayed again.
CREATE TABLE sync_mutation_receipts (
  user_id uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  mutation_id uuid NOT NULL,
  payload_digest text NOT NULL,
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, mutation_id)
);
