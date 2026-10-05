# Decisão — qual banco é canônico (internal task)

**Status:** **ACEITA** — 2026-10-05
**Decisão de:** **Jonas** (dono da decisão) · **execução:** engenharia
**Registrada em:** 2026-10-05 02:25 (-03), comentário do Jonas no card `internal task`
**Referência:** histórico do card `internal task` (`internal task`), template PILOT-B,
`<internal record>`, `PRD.md` §1.4.4

---

## 0. Decisão registrada (o que ficou decidido)

| # | Questão | Decisão | Data | Autor |
|---|---|---|---|---|
| **D1** | Qual banco é canônico | **(A) `home_shopper-db`** (Compose, `home_shopper`/`home_shopper`, volume nomeado) | 2026-10-05 | Jonas |
| **D2** | As 4 notas sem fonte preservada (106 linhas) | **(c) reconstruir os 4 inputs a partir de `home_shopper`** | 2026-10-05 | Jonas |

Verbatim do Jonas no card: *"Confirmado! após terminar, avise a coordenação e peça para ele
fazer commit para não perdermos esses dados depois"* — resposta a *"Confirma (A)+(c) —
`home_shopper-db` canônico e eu carrego os 15/573 a partir de `home_shopper`?"*

**Consequências aceitas:**
- `postgres`/`home_shopper` vira **descartável** (não é apagado neste card; segue como rede de
  segurança).
- O critério do Sprint 1 continua sendo **15 notas / 573 linhas** — não foi reescrito
  para 11/467.
- O dado passa a ser produzido pelo **caminho documentado** (`compose up` + schema +
  loader), que agora entrega 15/573.

## 1. O que foi executado (2026-10-05, mesmo dia)

Executado pela engenharia, autorizado pela decisão acima — que é o "go" explícito que
faltava (o corpo do card não autoriza migração de dados; o dono da decisão autorizou).

1. `scripts/recover_missing_inputs.py` (novo, versionado) reconstruiu **os 4 inputs que
   faltavam** a partir de `home_shopper`, no formato que o loader lê, gravando em
   `.../<private>` (0600, fora do repositório — o JSON
   carrega `access_key`, dado pessoal). São exatamente as 4 notas nomeadas no §2.3:
   `Supermarket E <date>` (18 linhas), `Supermarket B <date>` (6), `Supermarket A <date>`
   (37), `Supermarket A <date>` (45) = **106 linhas**.
2. `scripts/load_receipts.py` rodou sobre os **11 inputs preservados + 4 reconstruídos**
   e aplicou no `home_shopper-db` pelo cliente que o README documenta
   (`psql` no container).

O caminho **dump → restore** do §6 foi ensaiado e medido, mas **não** foi o executado: a
reconstrução de inputs (§0/D2(c)) entrega o mesmo conteúdo e mantém o loader versionado
como único caminho de carga — um caminho, duas provas.

### 1.1 Duas divergências encontradas durante a implementação (e corrigidas)

O ensaio nota-a-nota do §3 conferia `amount_paid`, contagem de linhas e soma — não a
apresentação. Ao comparar **conteúdo por chave natural** (loja + data + valor + linha +
unidade + descrição + `base_price`), apareceram duas divergências do loader contra
`home_shopper`, ambas corrigidas em `scripts/load_receipts.py`:

| Divergência | Efeito | Correção |
|---|---|---|
| Nota **sem** `access_key` não tinha guarda de idempotência (o `ON CONFLICT` só vale para chave não nula) | 2ª execução inseria as 2 notas keyless de novo → 17/636 | guarda explícita em `(user_id, store_id, purchase_date, amount_paid)` |
| `sale_unit` era gravado em maiúsculas (`pc` → `PC`) | `presentations.sale_unit` e a linha diferiam de `home_shopper` | preserva a grafia impressa; só a inferência de base unit é case-insensitive |

Nenhuma das duas estava coberta pelo ensaio anterior. Sem a comparação de conteúdo, a
base canônica teria ficado sutilmente diferente de `home_shopper`.

### 1.2 Verificação (medida, não afirmada)

Antes de aplicar, tudo foi ensaiado em `BEGIN … ROLLBACK` (sem efeito). Depois de
aplicado, medido na base real:

```
home_shopper-db (real, pós-migração)
  users=1  stores=7  products=384  presentations=393
  purchase_notes=15  line_items=573  audit_log=588  sum(line_total)=<sum>
```

> **Nota de 2026-10-05 (posterior ao DDL do internal task).** O bloco acima é o snapshot da
> migração do banco e vale para aquela data. Depois do DDL, `presentations` = **384 formas** +
> **393 mapeamentos** em `presentation_sources` — as 393 grafias continuam todas existindo. Ver
> [`2026-10-05-ddl-apresentacoes-implementacao.md`](./2026-10-05-ddl-apresentacoes-implementacao.md) §3.

Hash de **conteúdo por chave natural** (independente de UUID/`created_at`), `home_shopper` vs
`home_shopper-db`:

```
stores=6b506e60… products=6590a2d3… presentations=2f4a0011…
notes=<hash> lines=<hash> sum=<sum> users=1 audit=588
→ IDÊNTICO
```

Reexecução do loader na base real: 15 notas "skip duplicate", contagens inalteradas
(15/573/588) — **idempotente**.

Rede de segurança: `.../private/<private data>` (553.089 B, dump
`--data-only` de `home_shopper`, sha256 `<sha256>…`), fora do scratch. `postgres` **não** foi
alterado nem apagado.

## 2. Fato verificado (consulta direta aos dois containers, 2026-10-05 02:16 -03)

| | `home_shopper-db` (Compose) | `postgres` (ad-hoc) |
|---|---|---|
| Origem | `docker-compose.yml` do repo (labels `com.docker.compose.*`) | `docker run` — `Config.Labels == {}` |
| User / base | `home_shopper` / `home_shopper` (mesmas da CI) | `home_shopper` / `home_shopper` |
| Senha | `ci` (a da CI; `.env` não existe no worktree) | `dev` |
| Porta publicada | `0.0.0.0:5432` | **nenhuma** (`PortBindings` vazio) |
| Volume | nomeado `home_shopper_pgdata` | **anônimo** `<volume>` |
| `users` | 0 | 1 |
| `stores` | 0 | 7 |
| `products` | 0 | 384 |
| `presentations` | 0 | 393 *(→ 384 formas + 393 mapeamentos após o DDL de 05/10)* |
| `purchase_notes` | 0 | **15** |
| `line_items` | 0 | **573** |
| `staging_receipts` / `staging_lines` | 0 / 0 | 0 / 0 |
| Schema | 14 tabelas, 5 views | idem |

No `home_shopper`: **13 das 15 notas têm `access_key`**; 2 não têm. Os dados foram
carregados **direto na camada confiável** — `staging_*` está zerado nas duas
bases. As demais tabelas (`categories`, `synonyms`, `price_refs`, `price_alerts`,
`data_erasure_requests`) estão **vazias** nas duas.

## 3. O loader existe — e foi recuperado em 2026-10-05

O parecer de produto dizia "o loader não existe". **Não procede.** <removed>
Achado da, reconferido aqui:

| Arquivo | Linhas | sha256 (conferido nas duas cópias) |
|---|---|---|
| `populate_db.py` | 213 | `<sha256>` |
| `generate_sql.py` | 155 | `<sha256>` |

- Recuperados do histórico de sessão (<internal store>), não do filesystem.
- Cópia durável: `<evidence>/<private>` (0700/0600).
- Cópia versionada no repo: [`scripts/legacy/`](../../scripts/legacy/) — byte a byte.

**Causa raiz (sistêmica):** o loader era a **única cópia** e vivia em scratch
volátil, que o protocolo proíbe. O mesmo destino teve o `populate.sql`
(≈492 KB) e o **input** dos 15 arquivos.

### 3.1 A ressalva material: o código voltou, o dado não

`PROBE_DIR = .../cache/scratch/home_shopper_private_receipt_probe` **não existe**.
O loader esperava 15 JSONs. O que sobreviveu:

| | Notas | Linhas |
|---|---|---|
| Input preservado (`<private>`, 7 arquivos) | 11 | 467 |
| Reconstruído de `home_shopper` (§1, D2(c)) | 4 | 106 |
| Total que o loader carrega hoje | **15** | **573** |

As 4 notas antes "sem fonte" (identificadas por loja/data): `Supermarket E <date>`,
`Supermarket B <date>`, `Supermarket A <date>`, `Supermarket A <date>`.

## 4. O caminho documentado, passo a passo, hoje

| Passo | Comando | Estado |
|---|---|---|
| 1 | `cp .env.example .env` + `DB_PASSWORD` real | **passo do operador** — não existe `.env` versionado (segredo nunca entra no git); sem ele `docker compose up/exec` falha |
| 2 | `docker compose up -d` | funciona |
| 3 | aplicar schema (`for f in db/*.sql`) | funciona |
| 4 | carregar dados (`scripts/load_receipts.py`) | funciona — **entrega 15/573** com os inputs de hoje |

O passo 4 foi exercitado nesta data pelo cliente do README (`psql` no container, via
`docker exec -i`; `docker compose exec -T db psql` é equivalente uma vez que o `.env`
exista).

## 5. As três opções e o custo real (histórico da proposta)

### (A) `home_shopper-db` é canônico — **ESCOLHIDA**

Alinhado com o que o PRD §1.4.4 já declara e com `docker-compose.yml`, CI,
`.env.example` e README — todos apontam para `home_shopper`/`home_shopper`.

Custo restante, **em dois passos** (o parecer antigo dizia "escrever o loader";
o loader existe):

1. **Localizar ou reconstruir o input das 4 notas.** Resolvido por D2(c): reconstruídas
   de `home_shopper`.
2. **Apontar/rodar o loader no canônico** (`home_shopper`): feito (loader parametrizado).

Efeitos: `postgres` vira descartável (não apagar sem ordem).

### (B) `postgres`/`home_shopper` é canônico — não escolhida

Custo: reescrever `docker-compose.yml` (`container_name`, user/base), `README.md`,
`.env.example` e PRD §1.4.4 para `home_shopper`. Nenhum loader é necessário.

Contra: `postgres` é um container **sem label de Compose**, com volume
**anônimo** e senha `dev`; nada no repo o reproduz. Trocar o canônico por ele é
adotar como fonte de verdade um artefato que nenhum script versionado recria —
o inverso da causa raiz que este card está consertando.

### (C) nenhum dos dois — não escolhida

Definir do zero o caminho canônico e marcar os dois como descartáveis.
Custo: o maior — perde-se a única base com dados.

## 6. Opção (A)+(c) pelo caminho dump → restore (ensaio alternativo)

Pergunta do Jonas: *"Não é possível pegar os dados da `postgres` e inserir na
`home_shopper-db`?"* — sim. Este caminho foi ensaiado e medido (transação revertida),
e **serviu de prova de compatibilidade**; o caminho efetivamente executado foi o loader
(§1), por manter um único caminho de carga versionado.

Ensaio: `pg_dump --data-only` de `home_shopper` → restore revertido em `home_shopper-db`
(11 tabelas da camada confiável):

- Schema **idêntico coluna a coluna e trigger a trigger** entre as duas bases.
- Dump: 552.212 B, 11 blocos `COPY`.
- Restauração **direta não funciona**: o `pg_dump` emite
  `set_config('search_path','')`, que quebra o `INSERT INTO audit_log`
  **não qualificado** do trigger `write_audit_entry`. Correção: restaurar com
  `SET session_replication_role = replica` (o usuário `home_shopper` é
  superuser) — carrega o dado cru, sem disparar `audit`/`base_price`. (Nota: por isso
  o dump→restore **não** regenera o `audit_log`; o loader regenera — 588 linhas.)
- **Resultado medido** (transação revertida):
  `users=1 stores=7 products=384 presentations=393 purchase_notes=15 line_items=573`,
  `sum_line_total=<sum>`, `notes_with_key=13` — **idênticos a `home_shopper`**.

Comandos do caminho (registro, não o executado):

```
docker exec postgres pg_dump -U home_shopper -d home_shopper --data-only --no-owner --no-privileges \
  -t users -t stores -t categories -t synonyms -t products -t presentations \
  -t purchase_notes -t line_items -t price_refs -t price_alerts -t audit_log \
  > <private data>
# restaurar com session_replication_role=replica dentro de uma transação
```

## 7. O que este documento NÃO faz

- Não apaga nenhum dos dois containers.
- Não altera `db/` (schema) — a migração é de **dados**, no banco canônico.
- Não faz commit/push: o commit dos artefatos deste card foi pedido à coordenação pelo
  Jonas (o dado em si não é versionável — carrega `access_key`).
- Não reescreve `PRD.md` §1.4.4 nem `<internal plan>` — a decisão (A) confirma o que o
  PRD já declara, e o critério do Sprint 1 permanece "15/573", agora alcançável pelo
  caminho documentado.
