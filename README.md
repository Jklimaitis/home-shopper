# home-shopper

Supermarket price monitor: canonical catalogue, cross-store price comparison,
and receipt ingestion with human review.

---

## The problem

Comparing the price of the same product across stores fails for three reasons,
and this project solves all three.

**1. The same product has a different name in every store.**
`CARNE MOIDA COMBO 1kg` (receipt A, R$ 29,90) and `MOIDA COMBO 1KG` (receipt B,
R$ 27,90) are the same cut of beef. Normalising text cannot bridge that — no
string rule turns one into the other. Equivalence is a **learned fact**, and a
learned fact lives in a table (`synonyms`), not in code.

**2. The same product is sold in different units.**
R$ 5,49 per `UN` and R$ 59,88 per `CX` of 12 are not 10× apart — they are the
same price. Every price is re-expressed in the product's **base unit**
(`base_price`) before any comparison happens.

**3. Fresh food has no barcode.**
Most fresh-produce lines carry no barcode at all. The 7-digit code printed on
the receipt belongs to the *emitter* and changes between CNPJs, so it is not an
identity either. Real identity is `brand + normalised name + size`. Exception:
when the printed value passes the GS1 check it becomes a review candidate —
never a discard nor a confirmation — and stays pending human review.

---

## Current state

```
19 migrations · 221 automated tests · 6 ADRs · FastAPI (catalogue + login + staging routes)
```

Built on PostgreSQL 16. The suite runs against a synthetic NFC-e fixture that
mirrors the real layout — the real receipts stay outside the repository.

| Assertion | Result |
|---|---|
| Accounting checksum | divergence 0 |
| Discount lives in the totals | divergence 0 |
| Base price (250 g vs 1 kg) | normalised to per-gram |
| Trigger refuses a line with no presentation | PASS |
| Idempotency on the access key | PASS |
| `NUMERIC` vs `float` | float errs by `5,5e-17` · NUMERIC errs by 0 |
| LGPD erasure | data removed, audit trail preserved |
| Every constraint is named | PASS |

---

## Engineering decisions

### Staging vs. trusted layer

Receipts land in **staging** tables (`staging_receipts`, `staging_lines`) where
they can be reviewed, corrected, or discarded. Only after human confirmation do
prices flow into the **trusted** layer (`price_refs`). This separation means a
bad match never pollutes the comparison data — it stays in staging until a human
decides.

### Review state machine

Every staging line carries a `review_state` with four values, enforced by
database constraints:

| State | Meaning |
|---|---|
| `PENDING` | Never reviewed by a human. |
| `CONFIRMED` | A human confirmed the link to a product. |
| `NO_MATCH` | A human decided no candidate fits. |
| `SKIPPED` | A human set the line aside (e.g. non-product item). |

The database enforces coherence: `CONFIRMED` requires a `product_id` and
`presentation_id`; `NO_MATCH` requires no link and a reason; a `CONFIRMED` line
whose product is deleted automatically reverts to `PENDING` — the decision
cannot survive without the thing it confirmed.

### Ambiguity is a feature, not a bug

When the matcher finds **two or more candidates** for a line, it does not pick
one. The line is left with no link, `match_source = NONE`, and the candidate
list is stored in `match_note` for the human reviewer. The reasoning: a price
attached to the wrong product is **worse than "I don't know"** — it silently
corrupts every comparison that uses that price.

### Store-printed codes become candidates only after the GS1 check

A 7-digit code printed by the store is not a barcode. But when that code passes
the **GS1 mod-10 check digit**, it becomes a *candidate* — not a confirmation.
The uncertainty is in the origin of the number, not in the match, so it carries
no confidence score and always waits for human review.

### Per-owner isolation

Every query that reads receipts or price references is scoped by `user_id` as a
SQL parameter — never as a post-read filter. A receipt belonging to another
owner returns `404` (not `403`), so the API does not confirm that the resource
exists.

### Textual guard for personal data

An NFC-e access key is personal data: anyone holding it can query the receipt
at the tax authority without authenticating and obtain the buyer's CPF, address
and purchase history. The repository therefore contains **anonymised fixtures
only**, plus a guard that blocks the leak:

```bash
python scripts/guard_dados_sensiveis.py          # scan everything
python scripts/guard_dados_sensiveis.py --staged # only what will be committed
```

It runs in CI on every push to `main` and on pull requests. Anonymising preserves
the *format* (44 digits become 44 zeros), so the assertions still test the logic
rather than the data.

A store's CNPJ is deliberately not guarded. It identifies a *legal person*,
not an individual: the registry is public, the number is printed on the receipt
and on the shop front, and sanitising it would protect nobody.

---

## How this was built

Every change followed the same loop: a written spec, tests written before the
code, an independent review pass, and a recorded evidence log for each
acceptance criterion. The architectural decisions, the acceptance criteria and
the privacy boundary of what is published here are mine — AI assistance was
used for drafting and for the review passes, and no result was accepted without
being verified against the code.

---

## Run it

Prerequisites: Docker with Compose, and Python 3.

**1. Start the database.**

```bash
cp .env.example .env   # preencha DB_PASSWORD
docker compose up -d
```

The Compose file only needs `DB_PASSWORD`. Two other values in `.env.example` are
empty and are required **by the API** (not by the database) — set `JWT_SECRET_KEY`
and `AUTH_PEPPER` too if you intend to run step 4.

The Compose service starts PostgreSQL 16 only. The schema is **not** mounted
into the database — it is applied by you, in order, from `db/*.sql`:

```bash
for f in db/*.sql; do
  docker compose exec -T db psql -U home_shopper -d home_shopper -v ON_ERROR_STOP=1 < "$f"
done
```

`db/*.sql` applied in order is the **single source of truth of the schema**.

Note: `docker-compose.yml` fixes `container_name: home_shopper-db` (it is meant
to be shared with the application checkout). If a container with that name is
already running on your machine, stop it first.

**2. Install the Python dependencies.**

```bash
python -m pip install --require-hashes -r requirements.txt
```

**3. Run the suite.**

The suite needs a database of its own, and the name must start with
`hs_ingest_test_` — the suite refuses to write anywhere else. It also has to
accept the connection **without a password check**: one test connects by keyword
(`host=…`, `dbname=…`) using a password containing spaces and quotes, to prove
the code handles special characters — no server could have that password
configured, so that test only passes against a server in `trust` mode. The
Postgres from `docker-compose.yml` uses `scram-sha-256`, so run a disposable
container for the tests:

```bash
docker run -d --name hs_ingest_test \
  -e POSTGRES_USER=home_shopper -e POSTGRES_DB=hs_ingest_test_dev \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -p 127.0.0.1:5433:5432 postgres:16-alpine

for f in db/*.sql; do
  docker exec -i hs_ingest_test psql -U home_shopper -d hs_ingest_test_dev -v ON_ERROR_STOP=1 < "$f"
done

export HS_INGEST_TEST_DSN="host=127.0.0.1 port=5433 user=home_shopper dbname=hs_ingest_test_dev"
python -m unittest discover -s tests -v
```

`HS_INGEST_TEST_DSN` is required for the integration tests. Without it they are
**skipped**, and a skipped test is not a passing test.

**4. Run the API (optional).**

```bash
python -m uvicorn --app-dir api main:app
```

`--app-dir api` is required: `api/main.py` imports `database` and `auth` as
top-level modules. The API also refuses to start without `JWT_SECRET_KEY` and
`AUTH_PEPPER` set in `.env` (step 1). `--reload` is not used here because
`watchfiles` is not in `requirements.txt`; install `uvicorn[standard]` if you
want auto-reload.

The API exposes:

| Route | Purpose |
|---|---|
| `GET /products` | List the canonical catalogue |
| `GET /products/search?q=` | Search by name |
| `POST /products` | Create a product (admin) |
| `GET /stores` | List stores |
| `GET /categories` | List categories |
| `POST /login` | Get access + refresh tokens |
| `GET /price_refs` | List price references (paginated, per-owner) |
| `GET /staging/receipts` | List receipts in the review queue (per-owner) |
| `GET /staging/receipts/{id}/lines` | List lines of a receipt (per-owner) |

---

## What is NOT ready

- **Consolidating purchases.** The pipeline ingests receipts and matches lines
  to products, but there is no batch job that consolidates multiple purchases of
  the same product into a single price trend.
- **Review screen.** The API exposes the staging queue and its lines, but there
  is no UI for a human to confirm, reject, or skip matches.
- **Dashboard.** No analytics or visualisation layer exists yet.

---

## Documentation

- [`docs/ERD.md`](docs/ERD.md) — Mermaid diagram and the central decisions
- [`docs/adr/`](docs/adr/) — Architecture Decision Records (6 ADRs)
- [`docs/lgpd/`](docs/lgpd/) — LGPD retention terms and data-subject rights
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — Index of ADRs

---

## License

MIT
