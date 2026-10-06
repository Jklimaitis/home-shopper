-- =============================================================================
-- home_shopper -- users.email: format CHECK and case-insensitive uniqueness
-- PostgreSQL 16
--
-- internal task. This closes the structural FAIL of `users` reported by
-- internal task. Two defects, one column:
--
--   1. No format CHECK. `email` accepted 'sem-arroba', 'a@b', '   ' and
--      the empty string. `NOT NULL` only keeps the column from being
--      omitted; it says nothing about the value being an address.
--
--   2. Uniqueness was case-SENSITIVE. `uk_users_email UNIQUE (email)`
--      treats 'Foo@x.com' and 'foo@x.com' as two different people. The
--      same human registering twice under a different capitalisation gets
--      two logins, two purchase histories and two erasure records -- the
--      exact LGPD cost the single-holder design (PRD 2.1) exists to avoid.
--      Reproduced before the fix: both rows coexist.
--
-- WHY lower() IN AN EXPRESSION INDEX, AND NOT citext
--   `citext` would change the column type and add an extension dependency
--   to every environment. `lower(email)` is a dependency-free expression
--   index: it protects new rows without touching the existing column type.
--   A UNIQUE constraint cannot sit on an expression, so this is an index
--   (`uq_users_email_ci`), not a table constraint.
--
-- WHY THE FORMAT CHECK ACCEPTS example.com
--   `example.com` is a RESERVED test domain (RFC 2606) and is what the CI
--   fixture and the canonical seed use ('user@example.com'). A check that
--   rejected reserved/test domains would break the CI. This one only
--   rejects strings that are not shaped like an address at all:
--     'sem-arroba'  -> no '@'            -> refused
--     'a@b'         -> no dot in domain  -> refused
--     'a b@c.com'   -> space in local    -> refused
--     '   ' / ''    -> blank             -> refused
--     'user@example.com' -> accepted
--
-- All named objects follow the pk_/uk_/ck_/fk_ convention; an unnamed
-- constraint produces an error message that names no business rule.
-- =============================================================================

BEGIN;

-- Not blank. '' and whitespace-only are not addresses. (The column is
-- already NOT NULL; this closes the empty-string hole NOT NULL leaves.)
ALTER TABLE users
    ADD CONSTRAINT ck_users_email_not_blank
    CHECK (btrim(email) <> '');

-- Shaped like an address: local@domain.tld, no whitespace, at least one
-- character on each side of the '@' and at least one dot in the domain.
-- Deliberately permissive -- it is a shape check, not an RFC 5322 parser.
ALTER TABLE users
    ADD CONSTRAINT ck_users_email_format
    CHECK (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');

-- Case-insensitive uniqueness: 'Foo@x.com' and 'foo@x.com' are the same
-- mailbox. The expression index is what the plain UNIQUE (email) could not
-- provide.
CREATE UNIQUE INDEX uq_users_email_ci ON users (lower(email));

COMMIT;
