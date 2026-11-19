# Account deletion

People delete their sync account in the app: Settings › Accounts › Delete Account… on Mac, Account & Sync › Delete Account… on iPhone and iPad. App Store guideline 5.1.1(v) requires this for apps that create accounts.

## Server

`DELETE /v1/account` with the account's bearer token answers 204 and deletes the account at once. An account that is already gone answers 204 again, so a client retries safely after a lost reply. The server checks only the token's signature here; every other authenticated route answers 401 once the account is gone, so the account's other devices learn they are signed out. A missing or invalid token answers 401. Each account may send five requests in 15 minutes; more answer 429. The limit lives in the server process and resets when it restarts.

Deletion runs in one transaction under the account row lock, which a push in progress also takes:

1. Pending Apple revocations go to `apple_token_revocations`.
2. Email codes for the account's addresses go from `auth_email_codes`, which is keyed by address, not account.
3. The `app_users` row goes. Every other table references it with `ON DELETE CASCADE`: `devices`, `auth_identities`, `auth_web_sign_ins`, `spaces`, `tabs`, `folders`, `boosts`, `sync_events`, `sync_tombstones` and `sync_mutation_receipts`. Tombstones reference events without an action of their own; both rows go in the same statement, so the check at its end passes.

Access tokens are stateless JWTs and stay valid until they expire, but every route that uses one needs the account to exist.

## Sign in with Apple tokens

Apple asks apps to revoke a user's tokens when the account is deleted, with `POST https://appleid.apple.com/auth/revoke`. That needs a refresh token and a client secret: an ES256 JWT signed with a Sign in with Apple key from the developer account.

- Configuration: `OPENARC_APPLE_TEAM_ID`, `OPENARC_APPLE_KEY_ID` and `OPENARC_APPLE_PRIVATE_KEY` (the `.p8` PEM; on one line, write its line breaks as `\n`). All three or none; startup fails on a key that does not parse. The key must be enabled for Sign in with Apple on the app's primary App ID, which the Services ID is grouped with.
- Sign-in: with the key set, native sign-in sends the `authorizationCode` from `ASAuthorizationAppleIDCredential`, and web sign-in posts Apple's `code`. The server redeems the code at `/auth/token` (client ID: the token's audience natively, the Services ID with its redirect URI on the web) and keeps the refresh token in `auth_identities.apple_refresh_token`, with the client ID in `apple_client_id`. The latest sign-in's token replaces the previous one; one token revokes the app's access for that Apple ID. A failed redemption only logs a warning; sign-in goes on.
- Deletion: after the commit, the server revokes each stored token. Apple answering `invalid_grant` means the token is already invalid and counts as revoked. A failed revocation stays in `apple_token_revocations`; the server retries it at start and every hour, and drops it after a week. That table holds only the token and its client ID.

### Gap for existing accounts

Accounts that signed in with Apple before migration `010_account_deletion.sql`, or while no key is configured, have no refresh token. Deleting them deletes all their data but cannot revoke at Apple; OpenArc stays listed under the user's Apple Account › Sign in with Apple until they remove it there. The next sign-in after the key is configured stores a token, so the gap closes for every account that signs in again.

## Clients

`BrowserAccountStore.deleteAccount()` serves both apps:

1. It stops sync transport, so no push or pull runs while the server deletes.
2. It calls `BrowserRemoteSyncClient.deleteAccount(authSession:)`.
3. On success, `BrowserSyncService.forgetAccount` unbinds the profile: `BrowserSQLiteSessionStore.forgetSyncAccount()` deletes the owner, cursor, outbox, baselines and expiry records, and keeps Spaces, tabs, folders, Boosts and the Archive. Then the Keychain session goes, and sign-in stops being required. A later sign-in makes a new account, which adopts the profile from its local data. If the Keychain removal fails, sign-in stays required, as after Sign Out.
4. On failure the account stays signed in and sync resumes. `lastError` says why: no connection, sign-in expired (401: sign out and in again), too many requests, or the server's message.

The confirmation names what goes (the account, and the Spaces, tabs and Boosts synced to it, on every device) and what stays on this device. On Mac, a checkbox opens Clear Browsing Data after deletion. On iPhone and iPad, Delete Account and Website Data also removes every kind of data in the shared WebKit store.

Tests: `Tests/OpenArcTests/BrowserAccountDeletionTests.swift` (HTTP client against a fake server, the profile database before and after), `Tests/OpenArciOSTests/BrowserMobileSyncSessionTests.swift` and `BrowserMobileAccountTests.swift`, `Backend/tests/account-deletion.ts` (PostgreSQL, a stand-in for Apple's endpoints) and `Backend/src/account.rs` (client secrets, configuration).

## Deploy

Migration `010_account_deletion.sql` adds two nullable columns to `auth_identities` and creates `apple_token_revocations`. Neither rewrites a table, and existing rows stay as they are. The migrate command applies every pending migration in one transaction, so a failure leaves the database as it was. Steps on the services droplet, with the image built and uploaded as `/home/agent/openarc/README.md` describes:

1. Back up the database: `docker compose exec -T postgres pg_dump -U openarc openarc | gzip > backup-before-010.sql.gz`.
2. Create a Sign in with Apple key in the developer account (Keys › +, Sign in with Apple, primary App ID `com.levochkaa.OpenArc`), and add `OPENARC_APPLE_TEAM_ID`, `OPENARC_APPLE_KEY_ID` and `OPENARC_APPLE_PRIVATE_KEY` to `/home/agent/openarc/.env`. Without them the server still deletes accounts, without Apple revocation.
3. Apply the migrations with `docker compose run --rm api openarc-sync-server migrate` from the new image, then `OPENARC_IMAGE_TAG=<sha> docker compose up -d api`.
4. Check: `curl -i -X DELETE https://api.openarc.su/v1/account` answers 401, and `/openapi.yaml` lists `deleteAccount`.

Ship the server before the apps: older servers answer 404 to `DELETE /v1/account`, which the apps show as an error.
