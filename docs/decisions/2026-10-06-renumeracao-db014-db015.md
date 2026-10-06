# Decisão — o conserto de órfão passa a `db/015` (segunda renumeração do mesmo arquivo)

**Status:** **DECIDIDO pelo coordenador e EXECUTADO** na branch do <internal PR>; provado em base
descartável; **nada aplicado no canônico**
**Decisão de:** coordenação, comentário no card `internal task` em 2026-10-06 04:45Z ·
**execução e prova:** engenharia (dono do domínio)
**Data:** 2026-10-06
**Card:** `internal task`, board
**Branch:** <internal> (<internal PR>),
commit de fechamento sobre `4c5476c` — o SHA está no card
**Substitui:** a decisão congelada no corpo do card ("`014` fica com o <internal PR>, o arquivo do PR
#8 passa a `015`"), que ficou **inviável** e está superada

---

## 1. O que mudou de fato

A decisão congelada no card era a inversa desta. Ela partia de "os dois PRs estão abertos ao
mesmo tempo"; o merge do #8 destruiu essa premissa:

| Hora (UTC) | Fato |
|---|---|
| 2026-10-06 03:26 | <internal PR> mergeado: `main` chega em `db/001`…`013` |
| 2026-10-06 04:44:44 | **<internal PR> mergeado** como `661e9ba` (`feat: two honest variation columns on price_refs (internal task, decision D9) (an earlier PR)`): `main` passa a ter `db/014_price_variation_columns.sql` |
| 2026-10-06 04:45 | <internal PR> continua aberto publicando `db/014_staging_presentation_requires_product.sql` |

Os dois branches pegaram o mesmo "próximo número livre" `014` de forma independente e sem se
referenciar; o `git merge` não acusa conflito, então a colisão entraria na `main` em silêncio
com dois `014` no ledger (ordem de glob decidindo qual aplica primeiro).

## 2. Decisão

- **`014` fica como está na `main`** — `db/014_price_variation_columns.sql`, já mergeado e
  publicado. Não se toca nesse arquivo.
- **O conserto de órfão passa a `db/015_staging_presentation_requires_product.sql`**, na
  branch do próprio <internal PR>, **agora**, sem esperar nenhuma outra ordem de merge.

Por que nesta direção: renumerar o que **já está na `main`** exigiria um arquivo novo (o
`014` publicado não pode ser renomeado sem divergir de quem já aplicou) e invalidaria o SHA
auditado do <internal PR>; renumerar o conserto de órfão é **um arquivo que ainda não existe em
nenhum banco** — muda o número e mais nada. O conserto também é **posterior na ordem
lógica**: ele depende de `staging_lines.review_state` (`db/008`) e das constraints do #4,
enquanto a variação de preço não depende de nada disso.

## 3. O que o branch do <internal PR> carrega agora

| # | Arquivo | O que mudou |
|---|---|---|
| 1 | `db/015_staging_presentation_requires_product.sql` (era `db/014_staging_…`) | só rótulos: cabeçalho `part 14` → `part 15`, o parágrafo que justifica a numeração e as duas mensagens de runtime (`RAISE EXCEPTION` da guarda e `RAISE NOTICE` da limpeza: `'db/014: …'` → `'db/015: …'`) |
| 2 | `tests/smoke_test.sql` | comentário do bloco `N7` (`db/014` → `db/015`) |
| 3 | `docs/decisions/2026-10-05-renumeracao-migracoes-db.md` | nota de renumeração no hotspot `db/009`; o registro histórico anterior fica |
| 4 | `<internal record>` | ledger (§6, linha do 8º PR) e hotspot (§7) apontando para esta decisão |
| 5 | `<internal record>` | nota de renumeração no topo + a linha da tabela do §1; o corpo do relatório é **histórico** e ficou intacto |
| 6 | `docs/decisions/2026-10-06-renumeracao-db014-db015.md` | este documento |

O DDL **não** mudou: comparadas as duas versões do arquivo, o corpo é idêntico linha a linha
fora dos comentários e dos dois rótulos de runtime (81 linhas não-comentário comparadas,
normalizando `db/0NN:`).

## 4. Provas (container descartável `hs-t01201486b`, `postgres:16-alpine`, 16.15)

Cadeia **final** (o que a `main` vira depois do merge do <internal PR>): `db/001`…`013` (branch) +
`db/014` (da `main`, `661e9ba`) + `db/015` (branch).

| Prova | Resultado |
|---|---|
| Aplicação em base **vazia**, `ON_ERROR_STOP=1` | 15 arquivos, todos `OK`, **0 erro**; estrutura `20 tabelas / 8 views / 67 índices / 23 triggers / 120 constraints` |
| `tests/smoke_test.sql` | `exit=0`; **12 blocos `RESULT: PASS`**, **84 `PASS`**, **0 `FAIL`**, **0 `psql: ERROR`** — inclusive `N7 RESULT: PASS` |
| Sem regressão, contra o estado CI-aprovado | rodado o mesmo smoke sobre o estado do <internal PR> antes desta renumeração (head `4c5476c`, `db/001`…`013` + `db/014` do conserto): mesmos `12 / 84 / 0 / 0`, e o log é **idêntico** ao da cadeia final depois de ordenar as linhas (o `psql` intercala stdout/stderr; nenhuma linha de conteúdo difere) |
| Controle negativo — **sem** o arquivo | `db/001`…`014` sem o `db/015`: o bloco `N7` **reprova** (`N7 RESULT: FAIL`; 3 asserções `FAIL` depois de a coluna `review_state` ser dropada) — a cadeia exercita mesmo o arquivo renumerado |
| Sobre os **480 dados reais** (clone do canônico) | `db/014` (main) reporta `variation backfill: 480 rows, 35 window, 35 spread, 87 pairs, 45 change` — os mesmos contadores medidos pelo coordenador; `db/015` aplica limpo e **não emite `NOTICE` de limpeza** (o canônico tem 0 `staging_lines`, logo 0 órfão a reparar); contagens de linha inalteradas (`products 384 / line_items 573 / purchase_notes 15 / price_refs 480 / users 1`); estrutura `120 / 23` = a da cadeia fresca |
| `scripts/guard_dados_sensiveis.py` | `OK — 88 arquivos verificados, nenhum dado pessoal` |
| `ls db/` na branch, com o número travado | `001`…`013` + `015` (o `014` vem da `main`; no merge a cadeia fica `001`…`015` contígua, sem duplicata) |

## 5. O canônico

**Nada foi escrito no canônico por este card.** As interações foram `SELECT` (contagens e
catálogo de colunas) e `pg_dump` (clone para a prova).

Atenção a um ruído de medição: o canônico **mudou durante a execução, por outro ator** — às
04:49Z ele ainda tinha `117 constraints` e `price_refs` sem as colunas de variação; às 04:52Z
tinha `119 constraints`, `price_spread_pct`/`price_change_pct` e os dois `ck` novos. O delta é
exatamente o DDL do `db/014` da `main` (2 colunas + 2 constraints), há um backup
`pre-db014-20261006-014951.dump` (01:49:51 local) no diretório de backups e o log do container
mostra a sonda `column "price_spread_pct" does not exist` às 04:50:57Z. É o write do
`internal task` (card `internal task`), não deste card.

Consequência: o canônico está em `db/001`…`014` (`119 constraints / 22 triggers`) e **falta o
`db/015`**, que é o que este PR publica; somando o `db/015` a estrutura vai a `120 / 23`,
igual à cadeia fresca provada aqui. O `db/014` do canônico é intocado por este PR.

## 6. O que não muda

- O conteúdo e o número do `db/014` da `main` (variação de preço).
- O DDL do conserto de órfão: byte a byte o de `wt/internal task` `c391e9c`, fora dos rótulos.
- O canônico: continua sem o conserto até o <internal PR> mergear.

## 7. Pendência

- CI do <internal PR> depois do push deste commit (jobs `Guard -- no personal data` e
  `Schema and domain tests`). O merge é do coordenador.
