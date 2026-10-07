# home_shopper

Supermarket price monitor: canonical catalogue, cross-store price comparison,
and an analytics dashboard.

> **Status:** data modelling phase. The schema and the domain tests are done
> and verified; the API does not exist yet.

---

## The problem

Comparing the price of the same product across stores fails for three
reasons, and this project solves all three.

**1. The same product has a different name in every store.**
`CARNE MOIDA COMBO 1kg` (receipt A, R$ 29,90) and `MOIDA COMBO 1KG` (note 3,
R$ 27,90) are the same cut of beef. Normalising text cannot bridge that — no
string rule turns one into the other. Equivalence is a **learned fact**, and a
learned fact lives in a table (`synonyms`), not in code.

**2. The same product is sold in different units.**
R$ 5,49 per `UN` and R$ 59,88 per `CX` of 12 are not 10× apart — they are the
same price. Every price is re-expressed in the product's **base unit**
(`base_price`) before any comparison happens.

**3. Fresh food has no barcode.**
Across 42 line items in three receipts, **zero** had an EAN. The 7-digit
code printed on the receipt belongs to the *emitter* and changes between
CNPJs, so it is not an identity either. Real identity is
`brand + normalised name + size`.

---

## Current state

```
20 tables · 8 views · 67 indexes · 22 triggers · 8 enums
```

Built on PostgreSQL 16 and verified by domain tests that use a NFC-e
receipt (anonymised) as the fixture.

| Assertion | Result |
|---|---|
| Accounting checksum | `337,00 = 337,00`, divergence 0 |
| Discount lives in the totals | 550,93 − 6,00 = 544,93, divergence 0 |
| Base price (250 g vs 1 kg) | Surimi `0,043600/g` · Tripe `0,039900/g` |
| Trigger refuses a line with no presentation | PASS |
| Idempotency on the access key | PASS |
| `NUMERIC` vs `float` | float errs by `5,5e-17` · NUMERIC errs by 0 |
| LGPD erasure | data removed, audit trail preserved |
| Every constraint is named | PASS |

---

## Conventions

Taken from the author's study notes, applied consistently:

- `snake_case`, lowercase, **English** identifiers
- Tables in the **plural** (Django / Rails / Laravel convention)
- **Every constraint named**:
  - `pk_<table>` — primary key
  - `fk_<child>_<parent>` — foreign key
  - `uk_<table>_<columns>` — uniqueness
  - `ck_<table>_<rule>` — check

A named constraint is what makes an error message actionable. Postgres would
otherwise emit `line_items_total_check`, which says nothing about which
business rule was violated. The CI fails the build if any constraint lacks the
prefix.

---

## Run it

Prerequisites: Docker with Compose. A host `psql` client is used for one of the
two schema loops below, but the container path works without it.

**1. Prepare the environment.** A worktree starts with no `.env`, and Compose
refuses to start without `DB_PASSWORD`. One command creates `.env` byte for byte
from the versioned model. It never touches an existing `.env`, never reads or
copies another worktree's `.env`, refuses a tracked/ungitignored/symlinked
`.env`, and never prints a variable's value:

```bash
python3 scripts/prepare_env.py            # create .env from .env.example
python3 scripts/prepare_env.py --check    # report only; writes nothing
```

Exit codes: `0` ready · `1` `.env` in place but `DB_PASSWORD` is still unset or
at the model value (human action pending) · `2` environment error (not a git
worktree, `.env` tracked or not ignored, `.env` a symlink, `.env.example`
missing).

**2. Set a real `DB_PASSWORD`.** Generate one, then edit `.env` and replace the
value — never paste a secret into a card, log or chat (see *Personal data*):

```bash
openssl rand -base64 32        # paste the output into .env: DB_PASSWORD=<value>
```

Re-run `python3 scripts/prepare_env.py` and confirm `DB_PASSWORD ok` followed by
`STATUS: pronto -- exit 0`. `SECRET_KEY` and `SEFAZ_CSC_POR_LOJA` stay listed as
pending; they are required only by later phases (API, NFC-e ingest).

**3. Start the server and apply the schema.**

```bash
docker compose up -d
for f in db/*.sql; do
  psql -h localhost -U home_shopper -d home_shopper -v ON_ERROR_STOP=1 -f "$f"
done
```

`db/*.sql` applied in order is the **single source of truth of the schema**.
The Compose service only starts the server; it deliberately does not mount the
schema into the database, so the loop above is the only thing that applies it.
That loop applies **schema, not data**. Without a host `psql`, apply the same
files inside the container:

```bash
for f in db/*.sql; do
  docker compose exec -T db psql -U home_shopper -d home_shopper -v ON_ERROR_STOP=1 < "$f"
done
```

`docker compose exec` interpolates `docker-compose.yml` too, so it must run from
the worktree whose Compose project is up — that directory's `.env` supplies
`DB_PASSWORD`. From a directory without `.env` it fails with
`required variable DB_PASSWORD is missing a value`.

> **`docker exec` on a running container is a workaround, not a substitute.**
> If the canonical `home_shopper` project is already up, this reaches that
> server from anywhere without starting a second one:
>
> ```bash
> docker exec -i home_shopper-db psql -U home_shopper -d home_shopper -v ON_ERROR_STOP=1 < db/001_schema.sql
> ```
>
> It executes **inside the already-running container**; it does not prepare a
> worktree's `.env`, and it talks to that container's database — not to the
> worktree's own `pgdata` volume. The container name (`home_shopper-db`) is
> fixed in `docker-compose.yml`, while the user and database (`-U`, `-d`) come
> from `.env`; both are environment-dependent, so confirm them with `docker ps`
> before relying on them. Because the container name is fixed, a worktree's
> Compose project **cannot be up at the same time** as the canonical container —
> both want to create `home_shopper-db`. The worktree's own
> `docker compose exec -T db …` then answers `service "db" is not running`. Do
> not remove the canonical container to make room; stop it deliberately if you
> need the worktree's own database.

### Load the test data

The receipts are loaded by `scripts/load_receipts.py`, which reads a
directory of receipt JSON files and emits idempotent SQL on stdout. Nothing is
written to disk (the generated SQL carries personal data — the NFC-e access
keys — and must not land in the repository):

```bash
python3 scripts/load_receipts.py --dry-run                  # summary only
python3 scripts/load_receipts.py | docker compose exec -T db \
    psql -U home_shopper -d home_shopper -v ON_ERROR_STOP=1
```

`--source-dir` points at the preserved sources
(`<evidence>/<private>` by
default) and reads them recursively, so a `recovered/` subdirectory is picked
up too. Those sources cover **11 notes / 467 lines**; the other **4 notes /
106 lines** were reconstructed from the legacy `home_shopper` base by
`scripts/recover_missing_inputs.py` (decision (A)+(c), 2026-10-05 —
[docs/decisions/2026-10-05-canonical-database.md](docs/decisions/2026-10-05-canonical-database.md)):

```bash
python3 scripts/recover_missing_inputs.py \
    --have-dir .../<private> \
    --out-dir  .../<private>      # + --write
```

Together they are the **15 notes / 573 lines** of the canonical base. The load
is idempotent (keyed notes on `(user_id, access_key)`, keyless ones on their
natural key), so re-running the command above inserts nothing new.

### Apply the seeds

The seeds in `seeds/` are **data** (DML), not schema (DDL). They are applied
after `db/*.sql` and before the smoke test. The CI applies only the categories
seed (data-independent); the classification seed requires 384 products and is
applied manually to the canonical database.

```bash
# CI applies this one automatically:
psql -h localhost -U home_shopper -d home_shopper \
     -v ON_ERROR_STOP=1 -f seeds/2026-10-05-categories-and-attributes.sql

# Classification seed — manual, canonical only:
docker exec -i home_shopper-db psql -U home_shopper -d home_shopper \
    -v ON_ERROR_STOP=1 -f - < seeds/2026-10-06-product-category-classification.sql
```

The seeds are idempotent — re-running them changes nothing. They include
self-checks that abort if the result doesn't match the expected state.

| Seed | What it does |
|---|---|
| `seeds/2026-10-05-categories-and-attributes.sql` | 8 categories + 14 attribute declarations |
| `seeds/2026-10-06-product-category-classification.sql` | Classifies all 384 products into the 8 categories |

### Purchase date precision

`purchase_date` in `purchase_notes` has two levels of precision:

| Source | Precision | Notes |
|---|---|---|
| Receipt header | Exact (day/month/year) | 4 of 15 notes |
| Access key (AAMM) | Month/year only | 11 of 15 notes |

`uploaded_at` (added in `db/017`) records when the user registered the note
and is always exact. For MVP, month/year is sufficient for price trend
analysis. The exact day is only critical for future "price dropped today"
alerts.

Tests:

```bash
psql -h localhost -U home_shopper -d home_shopper \
     -v ON_ERROR_STOP=1 -f tests/smoke_test.sql
```

---

## Personal data

An **NFC-e access key is personal data**, not an internal id: anyone holding it
can query the receipt at the tax authority without authenticating and obtain
the buyer's CPF, address and purchase history. So is the buyer's **CPF**.

This repository therefore contains **anonymised fixtures only**, plus a guard
that blocks the leak:

```bash
python scripts/guard_dados_sensiveis.py          # scan everything
python scripts/guard_dados_sensiveis.py --staged # only what will be committed
```

It runs on pre-commit and in CI. Anonymising preserves the *format* (44 digits
become 44 zeros), so the assertions still test the logic rather than the data.

**A store's CNPJ is deliberately not guarded.** It identifies a *legal person*,
not an individual: the registry is public, the number is printed on the receipt
and on the shop front, and sanitising it would protect nobody. Real store CNPJs
belong in the fixtures — a `stores` table with the actual retail networks is what
makes the comparison credible. (The access key embeds the issuer's CNPJ, but the
key stays blocked because it also carries the consumer's data.)

Real secrets live in `.env` (see `.env.example`), never in code.

---

## Documentation

- [`docs/ERD.md`](docs/ERD.md) — Mermaid diagram and the central decisions
- [`docs/lgpd/retention-policy.md`](docs/lgpd/retention-policy.md) — LGPD retention terms, per
  column: purpose, legal basis, window, and the jobs that execute them
- [`docs/lgpd/titular-rights.md`](docs/lgpd/titular-rights.md) — data-subject channel,
  response deadlines and the erasure procedure (order matters)
- `docs/DECISIONS.md` — ADRs (planned)

---

## Planned pipeline

```
FastAPI → PostgreSQL → Celery (queue) → PostgreSQL → dashboard
```

The project's own edge over a generic price tracker is the last step: detect
a price drop and **trigger the communication** — territory where the author
already has MarTech/CRM experience.
