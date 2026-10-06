# Decisão — renumeração das migrações e ordem de integração (internal task)

**Status:** **DECIDIDO — PENDENTE DE AUDITORIA** (integração provada em base descartável;
nada aplicado no canônico)
**Decisão de:** engenharia (dono do domínio) · **autoriza o push/PR:** coordenação (coordenação)
**Data:** 2026-10-05
**Card:** `internal task` (`internal task`), board
**Contexto:** sete migrações revisadas e aprovadas (`db/007`…`db/012` nos branches de
origem), nenhuma mergeada. `main` está em `97eb926` e só tem `db/001`…`db/006`.

---

## 1. O conflito

Dois branches de origem publicam um arquivo `db/007`:

| Branch de origem | Arquivo |
|---|---|
| `internal task-internal task` | `db/007_category_attributes_and_category_rules.sql` |
| `internal task-internal task_items---price_ref` | `db/007_price_refs_sample_count.sql` |

A CI e o README aplicam `db/*.sql` em **ordem alfabética** (`for f in db/*.sql`). Dois
`007` não têm ordem definida entre si: qualquer um pode vir primeiro, e o resultado
depende do `LC_COLLATE` do shell. Precisa haver um vencedor por número.

## 2. Decisão

**Renumerar `price_refs_sample_count` de `007` para `013`.** Os outros seis nomes ficam
como estão (`007`…`012`). Não se edita o conteúdo de DDL — só o nome do arquivo e as
referências de caminho em docs/scripts.

Ordem final de aplicação (alfabética = ordem de dependência):

| Ordem | Arquivo | Card | Toca | Depende de |
|---|---|---|---|---|
| 1 | `db/007_category_attributes_and_category_rules.sql` | internal task/014 | `CREATE TABLE category_attributes`, `product_attributes`; `ALTER TABLE categories`, `products` | `db/001`–`006` |
| 2 | `db/008_review_state.sql` | internal task | `CREATE TYPE review_state`; `ALTER TABLE staging_lines`; `CREATE OR REPLACE VIEW v_review_queue` | `db/002`, `db/004` |
| 3 | `db/009_catalog_write_requests.sql` | internal task | `CREATE TABLE catalog_write_requests` + 3 índices + `CREATE VIEW v_catalog_write_queue` | `db/001` (`users`) |
| 4 | `db/010_retention_policy.sql` | internal task | `CREATE TABLE retention_policy` + trigger + `CREATE VIEW v_retention_due` + seed + `ALTER TABLE data_erasure_requests` | `db/002`, `db/003` |
| 5 | `db/011_orphan_visibility.sql` | internal task | `CREATE OR REPLACE VIEW v_catalog_coverage` | `db/002` (`line_items`, `price_refs`) |
| 6 | `db/012_users_email_constraints.sql` | internal task | `ALTER TABLE users` (2 CHECK + índice único `lower(email)`) | `db/001` |
| 7 | `db/013_price_refs_sample_count.sql` | internal task | `ALTER TABLE price_refs` (coluna `samples_30d` + CHECK) | `db/002` |

## 3. Por que `013` e não renumerar tudo

A alternativa era reescrever a cadeia inteira (`007`→`008`, `008`→`009`, …, `012`→`013`)
e deixar o `price_refs` no `007`. Rejeitada:

- **Custo de auditoria.** Renumerar seis arquivos já revisados invalida o SHA e o caminho
  citados nos seis laudos de revisão aprovados; sobra **uma** renomeação para auditar com
  a proposta adotada.
- **Sem ganho de ordem.** O `db/013` só faz `ALTER TABLE price_refs ADD COLUMN samples_30d`.
  Nenhum arquivo posterior depende dessa coluna: `db/011` (a view `v_catalog_coverage`)
  **não** a referencia — foi conferido por leitura do DDL, não por suposição. Rodá-lo por
  último é inofensivo.
- **Sem colisão futura.** O próximo número livre é `013`. O `db/009` do card `internal task`
  (`009_staging_presentation_requires_product.sql`, fora do escopo destes sete) fica
  registrado como hotspot: quando ele for integrado, colide com `db/009_catalog_write_requests`.

## 4. O que não muda

- O canônico (`home_shopper`) não recebeu nenhuma migração — contagens antes/depois no
  comentário do card `internal task`.
- O conteúdo de `db/013_price_refs_sample_count.sql` é byte a byte o do branch de origem;
  a única alteração é o nome do arquivo e as referências de caminho em
  `<internal record>`, `scripts/load_price_refs.py` e
  `tests/test_load_price_refs.py`.
- Popular `price_refs` no canônico continua passo separado (`internal task`, exige go do Jonas).
