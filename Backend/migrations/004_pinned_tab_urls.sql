ALTER TABLE tabs ADD COLUMN pinned_url_string text;

-- Legacy servers only kept the current URL. Use that as the initial home until
-- a client uploads the separately persisted pinned URL.
UPDATE tabs SET pinned_url_string = url_string WHERE placement = 'spacePinned';
