# Implementação — DDL das apresentações (internal task)

**Status:** **IMPLEMENTADO** — `ddl_applied: true`
**Execução:** engenharia · **go do Jonas:** registrado em 2026-10-05 (`Pode seguir`) · **commit:** coordenador
**Data:** 2026-10-05
**Card:** `internal task` (`internal task`), board
**Decisões implementadas:**
[segmento 1](2026-10-05-apresentacoes-conteudo-unidade-embalagem.md) (conteúdo, unidade,
embalagem) e [segmento 2](2026-10-05-apresentacoes-forma-mapeamento-gtin.md) (J1–J4).
**Detalhe de colunas/unicidade/FKs:** [revisão](<internal review>).

---

## 1. O que foi aplicado

Um único artefacto novo: **`db/005_presentations_form_model.sql`** (migração). Os arquivos
`db/001`–`db/004` ficam como o bootstrap que produziu o schema implantado; o `005` leva
**os dois** bancos — o vazio (a CI aplica `db/*.sql` em ordem) e o canônico carregado — ao
mesmo estado, por um só caminho de código, sem uma segunda cópia do DDL para divergir.

### 1.1 Enums novos
`content_kind` (`FIXED`/`VARIABLE`/`UNKNOWN`), `container_type` (`cx`/`pc`/`pct`/`sc`/`lt`/`un`)
e `sale_unit_recognized` (vocabulário controlado: `UN`,`KG`,`G`,`ML`,`L`,`PC`,`CX`,`PCT`,`SC`,`LT`,`FD`,`DZ`).

### 1.2 `presentations` passa a ser a forma comercial
Colunas novas: `content_kind` (NOT NULL, `DEFAULT 'UNKNOWN'` — J3), `content_quantity`
(NUMERIC), `content_unit` (enum `base_unit`), `container_type`, `multipack_quantity`,
`sale_unit_recognized`, `updated_at`.
Saem: `store_id`, `description_raw`, `description_norm`, `match_key`, `sale_unit` (vão para o mapeamento).

Constraints finais: `uk_presentations_form` (NULLS NOT DISTINCT, sem `store_id`),
`ck_presentations_content` (quantidade não nula **se e somente se** `FIXED`),
`ck_presentations_multipack` (NULL ou `> 1`); mantidas `pk_presentations`,
`uk_presentations_id_product`, `fk_presentations_product`, `ck_presentations_factor`.
`ck_presentations_sale_unit` (regex legada) e `fk_presentations_store` foram **removidas**.

### 1.3 `presentation_sources` (nova) — o mapeamento de origem (J1)
`id`, `presentation_id` FK CASCADE, `store_id` (NULL = global), `sale_unit` verbatim,
`description_raw` verbatim, `description_search` (a **única** representação de busca,
Ponto C), `match_key` GENERATED STORED a partir dela, `match_source` (enum existente),
`reviewed`, `created_at`, `updated_at`.
Constraint: `uk_presentation_sources_store_key` (NULLS NOT DISTINCT) + `ck_presentation_sources_sale_unit`
(apenas não-vazio). A loja é dona só do mapeamento: a forma sobrevive à exclusão da loja.

### 1.4 `presentation_identifiers` (nova) — o GTIN por item comercial (J2)
`id`, `presentation_id` FK CASCADE, `gtin`, `created_at`; `uk_presentation_identifiers_gtin`
(único **global**) e `ck_presentation_identifiers_gtin` (`^[0-9]{8,14}$`; o DV fica na
carga/revisão). **`products.ean` e `uq_products_ean` removidos.**

### 1.5 Unidade de venda
`sale_unit_recognized` na forma; `sale_unit` verbatim no mapeamento (J4). `ck_presentations_sale_unit`
**e** `ck_staging_lines_sale_unit` compartilhavam o regex `^[A-Za-z]{1,4}$`: as duas foram
afrouxadas **juntas** para apenas não-vazio (a extração conservadora de multipack gera
`CX 10` e `c/N`, que a regex rejeitava antes da revisão).

### 1.6 Correção de fator deixa rastro
`presentations` tinha **0 triggers**. Foi criado `tr_presentations_audit` (AFTER UPDATE):
grava em `audit_log` **somente** quando um campo que define a forma muda
(`factor_base`, `content_*`, `container_type`, `multipack_quantity`, `sale_unit_recognized`).
Mais `tr_presentations_touch` e `tr_presentation_sources_touch` (updated_at).
Nunca se recomputa `base_price` histórico em massa.

## 2. A unidade reconhecida foi populada (não inventada)

`UPDATE ... SET sale_unit_recognized = upper(btrim(sale_unit))::sale_unit_recognized
WHERE upper(btrim(sale_unit)) IN (<vocabulário>)`. Só o caso **sem ambiguidade**:
`UN`/`Un → UN`, `KG`/`Kg → KG`, `PC`/`pc → PC` (ADR-0001 regra 11: a caixa não muda a
unidade). Os rótulos sem significado confirmado (`BJ`, `Gf`, `Am`, `Gl`, `La` — 12 linhas)
ficam **NULL** e vão para o funil de revisão: `BJ` não vira um sentido por grafia.

## 3. Achado que o card não previu: `uk_presentations_form` colide com 393 linhas

**O card exigia, ao mesmo tempo, `uk_presentations_form` e "presentations 393 preservado".
Os dois não coexistem nos dados atuais.** Verificado no canônico, antes de aplicar:

- **8 produtos** tinham **>1 apresentação** (17 linhas: `cenoura kg` com 3; `abacate kg`,
  `cebola kg`, `cr leite italac 200g`, `mamao formosa kg`, `pao frances kg`,
  `pao panco forma 500g`, `sacola verde sp 48x5` com 2 cada).
- Em cada grupo o `factor_base` era **idêntico** e a forma idêntica; a única diferença era
  **a loja e a caixa do texto** — exatamente a duplicação que o **Ponto A** proíbe
  ("não duplicar a forma comercial apenas porque a descrição mudou").
- Com `NULLS NOT DISTINCT`, o tuple da forma `(product_id, NULL, 'UNKNOWN', NULL, NULL, NULL, NULL)`
  é igual dentro do grupo → `uk_presentations_form` **rejeitaria** as 393 linhas.

**Resolução adotada (executa a decisão do Jonas, não a contorna):** colapsar as formas
duplicadas. Um representante por forma sobrevive; **toda** grafia vira uma linha em
`presentation_sources` e as `line_items` são re-apontadas para o sobrevivente.

**Consequência de contagem:** `presentations` **393 → 384**. Nenhum dado de negócio foi
perdido:
- as **393** grafias continuam existindo, agora como **393** linhas de `presentation_sources`;
- as 9 linhas removidas eram formas redundantes (mesmo produto, mesmo fator, mesma semântica
  de venda) — só o `id` substituto e o `created_at` delas se foram;
- `factor_base` é igual dentro do grupo (a migração **aborta** se não for), então
  `line_items.base_price` fica intacto (o md5 do histórico não muda — ver §5).

Se o coordenador preferir preservar literalmente 393, a alternativa é **adiar**
`uk_presentations_form` — mas isso deixa o J1 sem a sua chave central.

## 4. O que NÃO foi implementado

- **`scripts/load_receipts.py` ainda escreve no modelo antigo** (insere em
  `presentations` com `sale_unit`/`description_raw`/`description_norm`/`store_id` e
  `ON CONFLICT (product_id, match_key, store_id)`). É **ETL/código, fora do escopo deste
  card de DDL** (o próprio coordenador separou "ETL/código, não schema"). Um novo load
  precisa: criar a forma pela chave `uk_presentations_form`, criar/reusar a linha em
  `presentation_sources` pela chave `(store_id, match_key)` e derivar `sale_unit_recognized`.
- **Extração conservadora de multipack** (`NxM`, `c/N`, `Nun`) — decisão 4, lógica de loader.
- **Reconhecimento dos rótulos não mapeados** (`BJ`, `Gf`, `Am`, `Gl`, `La`) — ficam NULL
  até interpretação confirmada.
- **`docs/DECISIONS.md`** com o link do `005` — decisão do coordenador (a revisão §8.3 já
  reservava isso a ele).
- Material, tampa e selo — fora de escopo (não viram colunas).

## 5. Verificação (evidência real)

**a) Caminho da CI — banco vazio** (`db/*.sql` em ordem + `tests/smoke_test.sql`):
0 `ERROR`, 0 `| FAIL`, **6** blocos `RESULT: PASS` (≥5), **26** ocorrências `PASS` (≥20),
**nenhuma** constraint fora de `pk_/uk_/ck_/fk_`. O `tests/smoke_test.sql` foi adaptado ao
modelo separado (fixtures de forma + mapeamento; `R1` lê o `match_key` de
`presentation_sources`) e ganhou o bloco **N1** (forma/mapeamento/GTIN + regex afrouxada).

**b) Ensaio no banco canônico, antes de tocar nele:** cópia integral de `home_shopper`
(esquema antigo + dados) em banco temporário, `005` aplicado, verificado:

| Métrica | Antes | Depois |
|---|---|---|
| `presentations` | 393 | **384** |
| `presentation_sources` | — | **393** |
| `products` | 384 | 384 |
| `line_items` | 573 | 573 |
| md5 de `line_items(id,base_price)` | `88b21f4f…f7c8` | `88b21f4f…f7c8` (**inalterado**) |
| md5 de `line_items(id,unit_price,quantity,line_total)` | `69865d3f…d89a` | `69865d3f…d89a` (**inalterado**) |

**c) Aplicado ao canônico `home_shopper-db`:** mesmas contagens; `base_price` md5 inalterado.
Colunas e nomes de constraints do canônico **idênticos** aos de um banco vazio com
`db/*.sql`. `presentation_sources` preserva as 393 grafias; os 8 produtos antes duplicados
têm 1 forma cada e 2–3 fontes cada.

**d) `presentations` agora tem auditoria:** teste em transação revertida — um UPDATE que só
toca `updated_at` **não** gera entrada; um UPDATE de `container_type` gera exatamente 1
entrada em `audit_log`.

**e) `scripts/guard_dados_sensiveis.py`:** `OK -- 59 arquivo(s)`, nenhum dado pessoal.

Cópia de segurança da tabela **catálogo** `presentations` (sem dado pessoal) antes da
migração: `<evidence>/<private>` (0600).
Bancos temporários de ensaio criados dentro do container canônico (`hs_mig_b`, `hs_ci_c`),
sem subir banco concorrente, sem alterar `docker-compose.yml`, sem parar nem remover o
container.

## 6. Pendências para o coordenador

1. **Rever a contagem 393 → 384** (§3) — é a única divergência de um critério literal de
   aceite, e é forçada por `uk_presentations_form`.
2. Commit do `db/005`, do `tests/smoke_test.sql` e deste documento (o card reserva o commit
   ao coordenador, com verificação). **Não varrer o checkout**: há mudança de outro card na
   árvore (ex.: `<internal record>`).
3. Abrir card de ETL para `scripts/load_receipts.py` no modelo separado (§4).
4. Atualizar `docs/DECISIONS.md` com o link deste documento e do `db/005`.
