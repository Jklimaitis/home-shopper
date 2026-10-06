# Decisão — 6 ou 8 categorias no escopo: Limpeza e Higiene entram (internal task)

**Status:** **ACEITA** — 2026-10-05
**Decisão de:** **Jonas** (dono da decisão) · **registro:** engenharia
**Registrada em:** 2026-10-05 22:30 (-03), comentário do desktop no card `internal task`
**Referência:** `PRD.md` §4.2/§4.3/§6.2.2 · `docs/adr/0001-product-identity-and-presentations.md`
("Escopo ratificado") · `docs/superpowers/specs/2026-10-01-product-equivalence-by-category.md` ·
`<internal review>` (§ categories) ·
`<internal review>` (L3) · cards `internal task` (`internal task`) e
`internal task` (`internal task`)

---

## 0. Decisão registrada

| # | Questão | Decisão | Data | Autor |
|---|---|---|---|---|
| **D7** | Quantas categorias no escopo | **8** — as 6 do PRD §6.2.2 **+ Limpeza + Higiene** | 2026-10-05 | Jonas |
| **D7a** | Quais as duas categorias novas | **Limpeza** e **Higiene**, ambas de topo (`parent_id NULL`) | 2026-10-05 | Jonas |
| **D7b** | Atributos das categorias novas | `product_type` + `variant` em cada uma (2 declarações por categoria) | 2026-10-05 | especificado neste registro, a pedido do card ("quais atributos entram") — ver §3 |
| **D7c** | Pet | permanece **fora** do ciclo — a decisão nomeia apenas Limpeza e Higiene | 2026-10-05 | decorre de D7 |

Verbatim do Jonas no card: *"Seriam 8 incluindo Limpeza e Higiene."*

**Consequências aceitas:**
- A contradição entre `PRD.md` §6.2.2 / ADR-0001 (6) e o review de domínio de 2026-10-03 (8, aprovado
  por Jonas) fica **encerrada**, com o review sendo o texto aprovado que a decisão ratifica.
- O seed de categorias passa de 6 para 8 linhas e de 10 para 14 declarações de atributo.
- Nenhuma migração, nenhum DDL novo: acrescentar categoria é **dado** (ADR-0001 registra isso desde
  2026-10-01; `categories.parent_id` e `category_attributes` já existem em `db/007`).
- A partir de agora, linha de nota com descrição de limpeza/higiene deixa de ser órfã de categoria.

## 1. Por que este card existiu

Três artefatos diziam coisas diferentes:

1. `PRD.md` §6.2.2: *"Escopo ratificado: as 6 categorias abaixo. Limpeza, higiene e pet ficam **fora**
   deste ciclo."* — e `PRD.md` §4.2: *"As 6 do escopo estão em §6.2.2"*.
2. `ADR-0001` §"Escopo ratificado" item 1: as 6, com limpeza/higiene/pet fora.
3. `<internal review>` (§ categories, **regras de domínio aprovadas por Jonas**):
   *"Categorias principais: Laticínios, Carnes, Mercearia, Bebidas, Hortifruti, Padaria, **Limpeza e
   Higiene**. Limpeza e Higiene ampliam o escopo alimentar anterior."*

O seed entregue pelo `internal task` seguiu as 6 (era o escopo do card) e a revisão de artefato de
2026-10-05 19:45 registrou o conflito como **questão de produto**, não de implementação. O card
`internal task` existe para isso; a resposta do Jonas é a decisão D7.

## 2. As duas categorias novas e a fronteira de classificação

Fonte da fronteira: `<internal review>` § categories (aprovado por Jonas).

| Categoria | Cobre | Fronteira declarada no review aprovado |
|---|---|---|
| **Limpeza** | limpeza e cuidado doméstico | repelente de ambiente (inclusive de tomada) → Limpeza; odorizador de ambiente → Limpeza |
| **Higiene** | higiene pessoal e cuidados corporais | repelente corporal → Higiene |

Ambas entram como **top-level** (`parent_id NULL`), com grafia e acentuação do português preservadas.
A unicidade do schema ignora caixa e espaços nas pontas (`uq_categories_name_norm`, `db/007`) — a
grafia canônica é `Limpeza` e `Higiene`, e é assim que o seed as insere (UUIDs fixos
`9f1c0000-…-0007` e `…-0008`).

## 3. Atributos declarados (o que o card pede)

| Categoria | Atributos declarados | `value_kind` |
|---|---|---|
| Limpeza | `product_type`, `variant` | TEXT |
| Higiene | `product_type`, `variant` | TEXT |

- **`product_type`** é *o que o produto é*: detergente, sabão em pó/líquido, amaciante, água sanitária,
  desinfetante, limpador multiuso/de pisos, lustra-móveis, destacador, esponja, lã de aço, inseticida,
  repelente de ambiente, odorizador/difusor de ambiente; papel higiênico, haste flexível, sabonete,
  sabonete líquido, shampoo, condicionador, creme dental, antitranspirante, lenço umedecido.
- **`variant`** é a variante **do mesmo tipo e mesma marca**: `DET LIMPOL 500ML COC` × `DET LIMPOL
  500ML CRI`; `SAB NIVEA CACAU E JA` × `SAB NIVEA KARIT E L.` × `SAB NIVEA OLEO DE AB`.
- **`brand` não entra** na lista: vive em `products.brand` (spec R5, sem segunda fonte de verdade). A
  marca é **aplicável** às duas categorias (as descrições observadas trazem marca em praticamente
  todas as linhas), então marca ausente é *desconhecido* → PENDENTE quando o outro lado informar
  (critério de aceite #12 da spec).
- **Por que 2 atributos e não 1:** o corpus já contém pares do mesmo tipo e mesma marca que só diferem
  por variante (exemplos acima). Uma lista com apenas `product_type` produziria **MATCH falso** nesses
  pares. O mínimo que o dado observado exige é o par.
- **Limite com a decisão D2 (2026-10-05):** D2 removeu o atributo de *sabor* das quatro categorias
  alimentares no MVP ("não hiper-especificar; ampliar em sprints futuros"). Nenhum atributo
  equivalente (fragrância/sabor) foi declarado aqui — `variant` cobre a diferença estrutural, que é a
  observada. Se Jonas preferir o mínimo estrito, **remover `variant` das duas categorias é mudança de
  DADO** (4 linhas no seed), não migração.
- `value_kind` é metadado de renderização; a garantia de exatamente um valor por linha é do XOR do
  banco (`ck_product_attributes_exactly_one_value`).

## 4. Evidência no corpus canônico (a ampliação não é hipótese)

Medido em 2026-10-05 no `home_shopper-db` (573 `line_items`, 393 descrições de origem, 7 lojas), por
classificação de palavra-chave declarada nos scripts de verificação (§7):

| Balde | `line_items` | descrições |
|---|---|---|
| Alimentar — as 6 categorias do ciclo anterior | 496 | 331 |
| **Limpeza** | **48** | **34** |
| **Higiene** | **15** | **14** |
| Fora **até das 8** (sacola, carvão, filtro de café, guardanapo, papel-manteiga, papel-toalha, bicarbonato) | 14 | 11 |
| **Total** | **573** | **393** |

Ou seja: **63 linhas compradas (11,0% do total) não tinham onde viver no escopo de 6 categorias** e
passam a ter nas 8; **14 linhas (2,4%) continuam sem categoria mesmo com as 8**. Exemplos reais
observados (descrições de produto; nenhum dado pessoal): `AGUA SAN CANDIDA 2L`,
`DET LIMPOL 500ML COC`, `DESINF PINHO B 500ML`, `LIMPADOR VEJA M.USO GOLD EMB.ECON.750ml`,
`REPELENTE SBP ELET.45 N.AP+RF.OF.ESP.`, `ODOR GLADE 70G FLORA`, `ESP LIMPPANO RAY 1UN`,
`PAPEL HIG.MILI NEUTRO F.D.30m 12un`, `HASTES FLEX.APONETE 75un`, `SAB NIVEA CACAU E JA`,
`CR DEN COLG 90G`, `SH PANT 400ML BAMBU`.

**Casos-limite observados, não resolvidos por esta decisão** — ficam para a fila de revisão/ingestão:

- `ALCOOL COOPER 1L CLA` — limpeza ou higiene? A embalagem de 1 L sugere doméstico, mas não está
  declarado.
- `TOALHA HIP SNOB C/3R` × `TOALHA PAP SNOB C/2` × `PAP TOAL SNOB CLA 2U` — papel higiênico ×
  papel-toalha, que caem em categorias diferentes (Higiene × fora das 8).
- `SACOLA BIOPL.REUT.CZA.`, `SACOLA BIOPL.REUT.VDE.`, `SACOLA RET B4U 35X40`, `SACOLA VERDE SP 48X5`
  — sacola/embalagem, hoje sem categoria nas 8.

## 5. Alinhamento executado (change set)

O card pede "seed e PRD 6.2.2 alinhados"; o change set abaixo foi preparado **em um único conjunto**,
empilhado sobre `f92d60c` (`internal task`), para revisão e commit pelo card de continuação (§7 nota).

| Artefato | Antes | Depois |
|---|---|---|
| `PRD.md` §6.2.2 | "as **6** categorias abaixo. Limpeza, higiene e pet ficam **fora** deste ciclo." | "as **8** categorias abaixo. Pet fica fora deste ciclo." + seções **Limpeza** e **Higiene** (atributos + exemplos) |
| `PRD.md` §4.2 | "As **6** do escopo estão em §6.2.2" | "As **8** do escopo estão em §6.2.2" |
| `PRD.md` §4.3 | 6 linhas de atributos | + **Limpeza:** `product_type`, `variant`; **Higiene:** `product_type`, `variant` |
| `docs/adr/0001-…` §"Escopo ratificado" item 1 | 6 categorias; limpeza/higiene fora | 8 categorias, com **emenda datada** apontando esta decisão (o registro aceito é preservado, não reescrito) |
| `docs/superpowers/specs/2026-10-01-…` §Escopo, §Categorias, §"Decisões ratificadas" | "Fora: limpeza, higiene, pet" | Limpeza e Higiene **dentro**, com atributos, regras de ambiguidade e casos de teste |
| `seeds/2026-10-05-categories-and-attributes.sql` | 6 categorias, 10 declarações | **8 categorias, 14 declarações** (cabeçalho, autocheck e comentários atualizados) |
| `<internal review>` §4 e §9 | 6 / 10 | 8 / 14 |
| `<internal review>` §5.5 e §7 | conflito 6×8 aberto | nota de resolução apontando esta decisão |
| `WIREFRAMES.md` §1 (chips de categoria) | 6 chips | **pendente — designer** (interface; este registro não é de UI) |

## 6. O que esta decisão NÃO decide

- **Pet** e "demais categorias" seguem fora (a spec §Escopo continua listando-as como fora).
- **Subcategorias / hierarquia**: as 8 permanecem de topo; `parent_id` continua disponível e sem uso.
- **Exemplos validados por ingestão real**: os casos de teste das duas categorias novas são
  `corpus` (par observado no canônico) ou regra transversal já ratificada (R4/R5/R9/R11); nenhum par
  foi validado com nota nova ingerida. A exigência da spec (≥3 MATCH / ≥3 NÃO-MATCH / ≥1 PENDENTE por
  categoria) é atendida pelo conjunto inicial, mas a validação contra ingestão nova é trabalho de
  ingestão, não de decisão.
- **Curadoria de `synonyms`** para as abreviações observadas (`DET`, `AMAC`, `DESINF`, `M.USO`, `F.D.`,
  `ESP`, `SH`, `CR DEN`) — ADR-0002 §4 veda promover um mapeamento de emissor a regra global
  automaticamente.
- **Classificação das 14 linhas sem categoria** e dos casos-limite do §4.
- **Contagem de atributos por categoria como contrato**: ampliar a lista é `INSERT` em
  `category_attributes` (dado), não migração.

## 7. Verificação executada (2026-10-05)

Container descartável `hs-d7v` (`postgres:16-alpine`), canônico só lido:

- `db/001`…`db/007` → rc=0 em cada arquivo; estrutura 18 tabelas / 59 índices.
- Seed **run 1**: `INSERT 0 8` + `INSERT 0 14`; **run 2**: `INSERT 0 0` + `INSERT 0 0` → **idempotente**.
- Contagem final: **8 categorias**, **14 declarações** — Laticínios 2, Carnes 3, Mercearia 2,
  Bebidas 1, Hortifruti 1, Padaria 1, **Limpeza 2, Higiene 2**.
- Ordem da CI (banco `hs_ci`: `db/*.sql` → `tests/smoke_test.sql`, **sem** seed): rc=0, **0 FAIL**,
  39 PASS, 8 blocos `RESULT: PASS` (CI exige ≥20 PASS e ≥5 blocos). A única linha que o filtro
  `grep -i error` capturou é um `NOTICE` que contém a palavra ("float8 error: … | numeric error: 0.0"),
  não um erro.
- Contrafactual que justifica manter o seed fora de `db/`: com o seed aplicado antes do smoke
  (banco `hs_ci_seed`) → rc=3, `more than one row returned by a subquery used as an expression`
  (linha 30).
- Canônico `home_shopper-db` intocado: 16 tabelas / 53 índices / `categories` 0 linhas /
  `category_attributes` ausente.
- Logs e scripts: `<internal>/internal task/` (`validation.log`, `smoke.log`,
  `validate_seed.sh`, `validate_ci_order.sh`).

**Nota de rastreio (por que este registro não está commitado por este card):** o artefato do seed
nasceu no branch do `internal task` (`b096824`) e foi revisado no `internal task` (`f92d60c`); **nenhum
dos dois está na `main`**. O roteamento do coordenador em 2026-10-05 22:35 manda a implementação para
a continuação do `internal task` — então este card entrega a decisão e o change set pronto (patch), e a
continuação faz commit, PR e merge. Nada foi aplicado no canônico e nada foi mergeado.
