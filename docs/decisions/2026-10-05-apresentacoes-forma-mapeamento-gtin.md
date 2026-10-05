# Decisão — forma, mapeamento, GTIN, conteúdo e unidade (internal task)

**Status:** **DECIDIDO — não implementado** (`ddl_applied: false`)
**Decisão de:** **Jonas** (dono da decisão) · **revisão técnica:** engenharia · **registro:** coordenador
**Data:** 2026-10-05
**Registrada em:** 2026-10-05 14:46 (-03), resposta do Jonas no Desktop — `A, A, a, A` — transcrita
no card `internal task` (`internal task`), board
**Referência:** `<internal review>` (proposta e
evidência, aprovada em revisão independente), card `internal task` (`internal task`),
`docs/decisions/2026-10-05-apresentacoes-conteudo-unidade-embalagem.md` (segmento 1)

---

## 0. Decisão registrada

| # | Questão | Decisão | Data | Autor |
|---|---|---|---|---|
| **J1** | Separar a forma comercial do mapeamento de origem | **(A) separar** — `presentations` (forma) + `presentation_sources` (mapeamento) | 2026-10-05 | Jonas |
| **J2** | Onde vive o GTIN | **(A) `presentation_identifiers`** (N GTINs por apresentação) + **remover `products.ean`** | 2026-10-05 | Jonas |
| **J3** | `content_kind` NOT NULL sobre 393 linhas populadas | **(a) `DEFAULT 'UNKNOWN'` + NOT NULL de uma vez**, com funil de revisão | 2026-10-05 | Jonas |
| **J4** | Onde vive a unidade reconhecida | **(A) na forma** (`sale_unit_recognized`), com o rótulo verbatim no mapeamento | 2026-10-05 | Jonas |

**Nada foi aplicado.** Este documento registra a decisão, não a implementação: `ddl_applied: false`,
`db/` intocado, nenhuma coluna, constraint ou trigger criada.

## 1. O que cada decisão significa na prática

**J1 — separar forma e mapeamento.** Hoje `presentations` funde a forma comercial canônica
(`product_id`, `factor_base`, unidade) com o texto de origem da loja (`description_raw`,
`description_norm`, `match_key`, `store_id`, `sale_unit` verbatim). A chave atual
(`uk_presentations_product_key_store` = `product_id, match_key, store_id`) ancora a unicidade na
**palavra**: grafia nova de loja cria linha nova com o mesmo fator, contrariando o Ponto A já
aprovado. A separação corrige isso. Consequência de FK: hoje `fk_presentations_store
ON DELETE CASCADE` mata a **forma** junto com a loja; no modelo separado a loja é dona apenas do
mapeamento e a forma sobrevive.

**J2 — GTIN por item comercial.** `products.ean` é índice único parcial (`WHERE ean IS NOT NULL`) e
está **NULL nas 384 linhas** — coluna no nível errado, nunca usada. O caminho aprovado do Open Food
Facts é chaveado por código de barras; sem um lugar por apresentação ele não tem onde gravar o
resultado. Teto verificado de enriquecimento: **43,3%** (202/467); as 106 linhas reconstruídas têm
código **perdido**, não inválido. Formato proposto na revisão: `^[0-9]{8,14}$`, com DV conferido na
carga/revisão, nunca inferido.

**J3 — `UNKNOWN` é valor honesto.** `content_kind` NOT NULL sobre 393 linhas populadas obriga a
decidir o valor das linhas existentes. `DEFAULT 'UNKNOWN'` + NOT NULL de uma vez foi escolhido
porque `UNKNOWN` representa "ainda não interpretado"; backfill por parsing violaria a regra de não
inventar, e a opção de duas etapas equivale a esta com refinamento posterior.

**J4 — uma semântica de venda por forma.** A forma tem **uma** semântica de venda; o rótulo muda por
loja. Por isso `sale_unit_recognized` vive na forma e o `sale_unit` bruto permanece verbatim no
mapeamento.

## 2. O que fica decidido junto, por consequência

- `content_quantity` + `content_unit` são **uma** dupla, definida uma vez — resolve o ponto 2 do
  corpo do card `internal task`. `container_type` e `multipack_quantity` são ortogonais.
- `ck_presentations_sale_unit` e `ck_staging_lines_sale_unit` compartilham a regex legada
  `^[A-Za-z]{1,4}$` (só 1 a 4 letras) e **precisam ser afrouxadas juntas**: a extração conservadora
  de multipack gera rótulos como `CX 10` e `c/N`, que a regex rejeita hoje. `staging_lines` está
  vazia, então o problema ainda não apareceu — mas a revisão precisa alcançá-la.
- `presentations` tem **0 triggers**: hoje uma correção de fator é **invisível**. Como preservar a
  interpretação das compras históricas é requisito, a implementação precisa que correção de fator
  **deixe rastro** — ou o fator se torna imutável, com correção por forma nova. Nunca recomputar
  `base_price` histórico em massa.

## 3. O que este documento NÃO faz

- Não implementa: o DDL é card próprio, com "go" explícito do Jonas.
- Não altera `db/`, não aceita ADR, não migra dado.
- Não decide o que a revisão deixou fora de escopo: material, tampa e selo não entram como colunas.

## 4. Próximo passo

Card de DDL, que precisa de: (i) estas decisões registradas — este documento; (ii) as 4 decisões do
segmento 1; (iii) o "go" explícito do Jonas; (iv) a ordem de migração das 393 linhas em J3.
