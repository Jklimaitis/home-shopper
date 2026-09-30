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
14 tables · 5 views · 48 indexes · 14 triggers · 4 enums
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

```bash
docker compose up -d
for f in db/*.sql; do
  psql -h localhost -U home_shopper -d home_shopper -v ON_ERROR_STOP=1 -f "$f"
done
```

Tests:

```bash
psql -h localhost -U home_shopper -d home_shopper \
     -v ON_ERROR_STOP=1 -f tests/smoke_test.sql
```

---

## Personal data

An **NFC-e access key is personal data**, not an internal id: anyone holding it
can query the receipt at the tax authority without authenticating and obtain
the buyer's CPF, address and purchase history.

This repository therefore contains **anonymised fixtures only**, plus a guard
that blocks the leak:

```bash
python scripts/guard_dados_sensiveis.py          # scan everything
python scripts/guard_dados_sensiveis.py --staged # only what will be committed
```

It runs on pre-commit and in CI. Anonymising preserves the *format* (44 digits
become 44 zeros), so the assertions still test the logic rather than the data.

Real secrets live in `.env` (see `.env.example`), never in code.

---

## Documentation

- [`docs/ERD.md`](docs/ERD.md) — Mermaid diagram and the central decisions
- `docs/DECISIONS.md` — ADRs (planned)

---

## Planned pipeline

```
FastAPI → PostgreSQL → Celery (queue) → PostgreSQL → dashboard
```

The project's own edge over a generic price tracker is the last step: detect
a price drop and **trigger the communication** — territory where the author
already has MarTech/CRM experience.
