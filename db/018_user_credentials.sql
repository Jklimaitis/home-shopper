-- =============================================================================
-- home_shopper -- user_credentials: table for API authentication
-- PostgreSQL 16
--
-- internal task / server parity work (2026-10-10).
--
-- WHY THIS MIGRATION EXISTS
--   `api/main.py` reads `user_credentials` on login to fetch `password_hash`
--   and verify the password (bcrypt via passlib). The table was created BY HAND
--   on the canonical database and NEVER entered `db/`, so any environment
--   built from `db/*.sql` -- the server the the server included -- had an API
--   whose login endpoint pointed at a table that did not exist. The 2026-10-10
--   data migration to the server hit exactly this: the server was cloned at the
--   same commit as the the local environment and still had no `user_credentials`.
--
-- WHY THE HASH LIVES IN ITS OWN TABLE, NOT IN `users`
--   `users` is shared catalog/profile data with a GDPR erasure path
--   (`DELETE FROM users` cascades). Keeping the credential in a separate table
--   with `ON DELETE CASCADE` means erasing a user destroys the login without
--   touching the profile columns, and lets the credential be created only when
--   a password is actually set. The API already reads it as a LEFT JOIN-style
--   optional: a user with no credential row gets the same 401 as a wrong
--   password, so an absent row must stay representable.
--
-- WHY THE CONSTRAINT IS RENAMED
--   The hand-made table on the canonical database named its FK
--   `user_credentials_user_id_fkey`. The project convention is
--   `fk_<origin>_<target>` (all other FKs in this schema follow it) and the CI
--   fails on an unnamed or off-convention constraint. This migration renames it
--   where the old name exists, and creates it directly under the right name
--   where it does not.
--
-- IDEMPOTENT BY DESIGN: it must run clean on three different starting states --
--   (a) fresh database (table absent)                 -> CREATE TABLE IF NOT EXISTS
--   (b) canonical database (table present, old FK name) -> rename in place
--   (c) server after manual creation (already correct)  -> no-op, guarded by DO
--
-- KNOWN LIMITATION -- full-chain replay on a database that already has the
-- hand-made table. The smoke test inside db/016 checks EVERY constraint in
-- `public` against the pk_/uk_/ck_/fk_ convention. On such a database,
-- `user_credentials_pkey` is still off-convention when 016 runs, so the chain
-- stops there -- before this migration gets a chance to rename it. A fresh
-- database never hits this (the table does not exist until this file). The
-- remedy on an existing database is to run THIS FILE directly; that is the
-- one-time repair. Reproduced on 2026-10-10: chain stops at 016 with
-- "unnamed constraints after db/016: user_credentials_pkey"; this file alone
-- then renames both objects and the chain resumes clean.
--
-- All named objects follow the pk_/uk_/ck_/fk_ convention.
-- =============================================================================

BEGIN;

-- (a) fresh database. The PK is `user_id` itself: one credential per user, and
-- the lookup in the API is always by user, never by a surrogate id.
CREATE TABLE IF NOT EXISTS user_credentials (
    user_id       uuid PRIMARY KEY,
    password_hash text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

-- (b) canonical database: the hand-made objects carry off-convention names.
-- `user_credentials_user_id_fkey` for the FK and `user_credentials_pkey` for
-- the PK. The project convention is pk_/uk_/ck_/fk_, and the smoke test in
-- db/016 fails on anything that does not match -- so a hand-made table makes
-- the whole chain fail. Both renames are no-ops on a fresh database.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'user_credentials'::regclass
          AND conname  = 'user_credentials_user_id_fkey'
    ) THEN
        ALTER TABLE user_credentials
            RENAME CONSTRAINT user_credentials_user_id_fkey
            TO fk_user_credentials_users;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'user_credentials'::regclass
          AND conname  = 'user_credentials_pkey'
    ) THEN
        ALTER TABLE user_credentials
            RENAME CONSTRAINT user_credentials_pkey
            TO pk_user_credentials;
    END IF;
END $$;

-- (c) the FK itself, when neither name exists yet. Guarded so a second run of
-- this migration does not fail on a duplicate constraint.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'user_credentials'::regclass
          AND contype  = 'f'
    ) THEN
        ALTER TABLE user_credentials
            ADD CONSTRAINT fk_user_credentials_users
            FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE;
    END IF;
END $$;

COMMIT;

-- -----------------------------------------------------------------------------
-- Assertions. Expected: 2 RESULT: PASS lines, 0 FAIL, 0 ERROR.
-- -----------------------------------------------------------------------------

-- The table exists with exactly the four columns the API reads.
DO $$
DECLARE
    cols text;
BEGIN
    SELECT string_agg(column_name, ',' ORDER BY column_name)
      INTO cols
      FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name   = 'user_credentials';

    IF cols = 'created_at,password_hash,updated_at,user_id' THEN
        RAISE NOTICE 'RESULT: PASS -- user_credentials has the expected columns (%)', cols;
    ELSE
        RAISE EXCEPTION 'FAIL -- user_credentials columns are %', cols;
    END IF;
END $$;

-- Both constraints follow the pk_/fk_ convention and the FK cascades on user
-- erasure, which is what makes the GDPR path safe for the credential.
DO $$
DECLARE
    bad_names text;
    fk_name   text;
    fk_def    text;
BEGIN
    SELECT string_agg(conname, ', ')
      INTO bad_names
      FROM pg_constraint
     WHERE conrelid = 'user_credentials'::regclass
       AND conname !~ '^(pk|uk|ck|fk)_';

    IF bad_names IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL -- off-convention constraint names: %', bad_names;
    END IF;

    SELECT conname, pg_get_constraintdef(oid)
      INTO fk_name, fk_def
      FROM pg_constraint
     WHERE conrelid = 'user_credentials'::regclass
       AND contype  = 'f';

    IF fk_name = 'fk_user_credentials_users'
       AND fk_def LIKE '%REFERENCES users(id)%'
       AND fk_def LIKE '%ON DELETE CASCADE%' THEN
        RAISE NOTICE 'RESULT: PASS -- constraints follow pk_/fk_ and FK % (%)',
                     fk_name, fk_def;
    ELSE
        RAISE EXCEPTION 'FAIL -- FK is name=% def=%', fk_name, fk_def;
    END IF;
END $$;
