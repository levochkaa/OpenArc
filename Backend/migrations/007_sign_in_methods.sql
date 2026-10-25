-- One account can sign in several ways. Each way is an identity: a provider
-- and the provider's stable subject. Native Sign in with Apple users keep
-- their accounts as Apple identities.
CREATE TABLE IF NOT EXISTS auth_identities (
  provider text NOT NULL CHECK (provider IN ('apple', 'google', 'github', 'email')),
  subject text NOT NULL,
  user_id uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  email text,
  -- Only verified emails link a new identity to an existing account.
  email_verified boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider, subject)
);

CREATE INDEX IF NOT EXISTS auth_identities_user_idx ON auth_identities(user_id);
CREATE INDEX IF NOT EXISTS auth_identities_verified_email_idx
  ON auth_identities(lower(email)) WHERE email_verified;

-- Apple shares email addresses only once they are verified.
INSERT INTO auth_identities (provider, subject, user_id, email, email_verified)
SELECT 'apple', apple_subject, id, email, email IS NOT NULL
FROM app_users
WHERE apple_subject IS NOT NULL
ON CONFLICT DO NOTHING;

ALTER TABLE app_users ALTER COLUMN apple_subject DROP NOT NULL;

-- A web sign-in in progress. The provider round trip carries a state whose
-- hash finds the row; the app then redeems a single-use code with the PKCE
-- verifier whose challenge started the sign-in.
CREATE TABLE IF NOT EXISTS auth_web_sign_ins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL,
  state_hash text NOT NULL UNIQUE,
  nonce text NOT NULL,
  code_challenge text NOT NULL,
  expires_at timestamptz NOT NULL,
  code_hash text UNIQUE,
  user_id uuid REFERENCES app_users(id) ON DELETE CASCADE,
  code_expires_at timestamptz,
  redeemed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS auth_web_sign_ins_expires_idx ON auth_web_sign_ins(expires_at);

-- The latest emailed code per address, with its attempts and send history.
CREATE TABLE IF NOT EXISTS auth_email_codes (
  email text PRIMARY KEY,
  code_hash text NOT NULL,
  attempts integer NOT NULL DEFAULT 0,
  sent_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  window_started_at timestamptz NOT NULL,
  sends_in_window integer NOT NULL DEFAULT 1
);
