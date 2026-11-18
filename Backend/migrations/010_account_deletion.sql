-- Sign in with Apple refresh tokens, kept so deleting an account can revoke
-- the app's access at Apple. A token is stored only when the server holds a
-- Sign in with Apple key; accounts from before this migration have none.
-- Nullable columns without defaults: adding them does not rewrite the table.
ALTER TABLE auth_identities ADD COLUMN IF NOT EXISTS apple_refresh_token text;
-- The client ID the token was issued to: the app's bundle ID for native
-- sign-in, the Services ID for sign-in on the web.
ALTER TABLE auth_identities ADD COLUMN IF NOT EXISTS apple_client_id text;

-- Revocations that have not reached Apple yet. The account is already
-- deleted; a row lives only until Apple accepts the revocation or a week
-- passes, and holds nothing but the token and its client ID.
CREATE TABLE IF NOT EXISTS apple_token_revocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id text NOT NULL,
  refresh_token text NOT NULL,
  attempts integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
