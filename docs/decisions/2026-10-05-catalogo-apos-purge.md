# Catálogo após o expurgo LGPD — aceitar o órfão (internal task, decisão D8)

**Status:** **IMPLEMENTADO** — `db/011_orphan_visibility.sql` + teste de prova
**Data:** 2026-10-05
**Decisão de:** **Jonas** (dono da decisão, 2026-10-05) · **execução:** engenharia
**Card:** `internal task` (`internal task`), board
**Branch:** <internal>
**Fontes:** ADR-0004 (catálogo compartilhado), ADR-0005 (minimização e exclusão),
`PRD.md` §13.8 / F11, card `internal task` (onde a decisão foi registrada).

---

## 0. Decisão registrada

| # | Questão | Decisão | Data | Autor |
|---|---|---|---|---|
| **D8** | O que acontece com a entrada de catálogo cujo único titular pediu exclusão (LGPD) | **Aceitar o órfão.** O produto continua visível e utilizável; a UI declara **"sem histórico de preço"** em vez de esconder o produto | 2026-10-05 | Jonas |

O órfão é a entrada de `products` (e suas `presentations`) que **perdeu toda a
observação de preço** porque o único usuário que a sustentava foi apagado. O produto
não é dado pessoal e não é apagado (ADR-0004 §1, ADR-0005 §3); ele fica **sem preço e
sem histórico**. Isso é ausência de dado, e ausência de dado é honesta.

---

## 1. O que sobrevive e o que some — fato verificado no schema

O `DELETE FROM users` propaga por FK. O mapa abaixo foi lido direto de
`db/001`–`db/006`:

| Tabela | `user_id`? | FK para `users` | Depois do expurgo |
|---|---|---|---|
| `products`, `presentations`, `stores`, `categories`, `synonyms` | **não** | — | **sobrevivem** (catálogo, ADR-0004) |
| `presentation_sources`, `presentation_identifiers` | **não** | — | **sobrevivem** (catalogue/mapping/GTIN) |
| `staging_receipts` | sim | `ON DELETE CASCADE` | somem |
| `staging_lines` | (via receipt) | `receipt_id` CASCADE | somem |
| `purchase_notes` | sim | `ON DELETE CASCADE` | somem |
| `line_items` | (via note) | `note_id` CASCADE | somem |
| `price_refs` | sim | `ON DELETE CASCADE` | somem |
| `price_alerts` | sim | `ON DELETE CASCADE` | somem |
| `data_erasure_requests`, `audit_log` | sim, **sem FK** | — | **sobrevivem** (a prova e o rastro) |

Consequência direta: o **único** vínculo entre uma observação de preço e uma pessoa
é `user_id`. Quando ele desaparece, o preço e o histórico desaparecem com ele — e
`products` fica sem nada que o sustente. **É exatamente esse o órfão.**

Ponto que o card mandou verificar antes de propor qualquer coisa: **não há FK de
`users` para `products`**. `products` não tem `user_id`; `line_items.product_id` e
`price_refs.product_id` apontam para `products`, não para `users`. Logo não existe
"vínculo de autoria" a marcar nem a anonimizar.

---

## 2. Por que aceitar o órfão é a saída certa

1. **O catálogo é global por desenho.** `products` sem `user_id` é uma decisão
   registrada (ADR-0004 §1): apagá-lo junto com o usuário destruiria a identidade
   compartilhada que **outras** pessoas construíram.
2. **O produto continua útil.** Outro usuário que comprar o mesmo item faz o match
   contra a entrada existente e ganha a comparação. A prova C5
   (`tests/orphan_visibility_test.sql`) mostra isso: um comprador novo ressuscita o
   histórico do órfão **sem escrever nada em `products`**.
3. **Mostrar é melhor que esconder.** Se a UI esconder o órfão, o usuário não
   entende por que o preço sumiu — e some justamente porque **ele** pediu a exclusão.
   Declarar "sem histórico de preço" é a informação correta; o PRD §13.8 / F11 já
   manda a interface declarar cobertura incompleta ("a interface precisa dizer, senão
   o ganho vira mentira").

---

## 3. As alternativas rejeitadas

### 3.1 "CNPJ laranja + nota laranja" — **rejeitada** (3 razões)

A ideia era fabricar uma loja/nota fictícia para o preço não se perder. Testada e
rejeitada por três razões, todas verificáveis no schema:

1. **Não existe titular sem fabricar um `users` novo — o oposto do que a LGPD pede.**
   `purchase_notes.user_id` é `NOT NULL` com FK `ON DELETE CASCADE`. Sem titular, a
   nota exige criar uma linha em `users`, isto é, **inventar uma pessoa** para guardar
   o dado que a exclusão deveria eliminar. E mesmo assim o art. 12 da LGPD exige
   **perda da possibilidade de associação a um indivíduo**; uma nota com CNPJ, data e
   valores **não perde** essa associação, e o estudo da ANPD registra que, em dados
   compartilhados, o dado original pode ser reconstruído.
2. **A nota laranja não poderia ser corrigida.** `tr_purchase_notes_immutable`
   (db/003) recusa qualquer `UPDATE` em `purchase_notes` fora do vínculo de staging.
   Data ou valor errados na nota fictícia ficariam congelados para sempre — e uma nota
   que não se corrige é uma fonte de verdade que ninguém pode consertar.
3. **Contaminação mensurável do painel.** `v_price_aggregation` (db/002) alimenta
   `price_refs` → `v_current_prices` → `v_best_price`. Uma nota laranja injetaria um
   preço **sintético** no caminho de comparação. Pior: a base tem só **8 produtos em
   2+ lojas**, então a nota laranja seria a "segunda loja" de vários produtos —
   transformando um dado fabricado em base de decisão de compra.

### 3.2 "Anonimizar" — **não é expressável hoje**

`products` não tem `user_id`: **não existe vínculo de autoria para anonimizar**. Não
há coluna a zerar, porque nunca houve autoria no catálogo. A anonimização não é uma
opção mais fraca — ela não é uma operação que o schema permita sequer descrever.

### 3.3 Esconder o produto — **pior que mostrar**

Ver §2.3. Ocultar o órfão mente por omissão: o preço sumiu porque o titular exerceu um
direito, e a interface precisa dizer isso.

---

## 4. A implementação: uma **view**, não uma migration

`db/011_orphan_visibility.sql` adiciona **apenas** `v_catalog_coverage`. Não há
`ALTER TABLE`, não há coluna nova, não há trigger novo. O card pedia provar *por que*
uma migration seria (ou não) necessária; a resposta é **não é necessária**, e as três
razões abaixo são a prova.

### 4.1 Por que um marcador de coluna não serve

- **Não há autor a marcar.** `products` não tem `user_id` (§1). Um `orphan_since` não
  teria dono nem vínculo com quem saiu.
- **Não há evento que o escreva corretamente.** O único evento candidato é o `DELETE`
  em cascata. Um `AFTER DELETE ON line_items` **não distingue** "o último titular foi
  apagado" de "uma linha foi corrigida enquanto outro titular permanece", e não
  consegue **limpar** a marca quando outro usuário volta a comprar o produto.
- **A coluna derivaria.** `has_history` é computável **exatamente** a partir de linhas
  que já existem. Guardar uma cópia só adiciona uma forma de estar errado: uma cache
  sem invalidação.

A prova C5 do teste fecha o argumento: depois de o órfão existir, um comprador novo
torna `has_history = true` **sem nenhuma escrita em `products`**. Uma coluna
`orphan_since` continuaria dizendo "órfão" ali, porque nada dispara para limpá-la.

### 4.2 `v_catalog_coverage`

```sql
CREATE OR REPLACE VIEW v_catalog_coverage AS
WITH observed AS (
    SELECT li.product_id, n.store_id, n.purchase_date AS observed_on
      FROM line_items li JOIN purchase_notes n ON n.id = li.note_id
    UNION ALL
    SELECT pr.product_id, pr.store_id, pr.ref_date AS observed_on
      FROM price_refs pr
)
SELECT p.id AS product_id, p.name AS product_name, p.base_unit,
       count(o.product_id) > 0     AS has_history,
       max(o.observed_on)          AS last_seen_date,
       count(DISTINCT o.store_id)  AS stores_count
FROM products p
LEFT JOIN observed o ON o.product_id = p.id
GROUP BY p.id, p.name, p.base_unit;
```

| Coluna | Significado |
|---|---|
| `product_id` / `product_name` / `base_unit` | identidade do produto |
| `has_history` | `true` sse sobrevive **ao menos uma** observação confiável (`line_items` **ou** `price_refs`). **`false` é o marcador de órfão** |
| `last_seen_date` | data da observação mais recente; `NULL` quando não há nenhuma |
| `stores_count` | nº de lojas **distintas** onde o produto foi visto. É o número que o painel usa para dizer "comparável" (≥ 2) ou não |

"História" = observação **confiável** de preço. `staging_lines.product_id` **não** é
contado: staging é não confiável e também cascateia com o usuário — não é histórico nem
sobrevivente. Nenhum preço é sintetizado: quando não há observação, as três colunas
saem `false` / `NULL` / `0`, e nunca um preço inventado.

### 4.3 Escopo — a ressalva do ADR-0004 (registrada, não escondida)

Diferente de `v_current_prices`/`v_best_price`, esta view **não** é escopada por
`user_id`, de propósito: a pergunta que ela responde é **ao nível do catálogo** —
"existe *qualquer* histórico que sustente este produto?" — e é isso que separa um
órfão de uma entrada saudável. Uma view por usuário não identificaria o órfão, porque
não há usuário.

O ADR-0004 alerta que "uma view nova sem `user_id` reintroduz o vazamento". Por isso
o escopo está declarado aqui: a view expõe **apenas agregados de cobertura** — nenhum
preço, nenhuma identidade de usuário, nenhuma chave de acesso. O sinal residual é
`last_seen_date` (a data da compra mais recente) e `stores_count`. É um sinal fraco —
não mapeia para uma pessoa e não revela valor — mas é um fato de *compra*, que o
ADR-0004 trata como pessoal. Fica **registrado como escolha revisada**, para o auditor
decidir se o painel precisa de uma versão escopada por usuário além desta.

---

## 5. Contrato de UI — "sem histórico de preço"

O painel de comparação (PRD §2, Product Comparison Page) recebe:

| Estado de `v_catalog_coverage` | O que a UI mostra |
|---|---|
| `has_history = true` e `stores_count >= 2` | comparação normal (melhor preço, spread) |
| `has_history = true` e `stores_count = 1` | preço de uma loja; **"comparável" = não** (falta a segunda loja) |
| `has_history = false` (**órfão**) | o produto **continua listado e utilizável**, e o bloco de preço renderiza literalmente **"sem histórico de preço"** |

Regras do contrato:

- **Nunca esconder o produto** por falta de histórico.
- **Nunca inventar preço** — nem `0`, nem "—" que pareça um valor. Ausência é
  declarada como ausência.
- O produto permanece **casável**: um comprador novo que registre o mesmo item
  ressuscita o histórico (`has_history` volta a `true`) e a comparação reaparece.
- Isto é a aplicação de PRD §13.8 / F11: *"Comparações usam apenas as linhas elegíveis
  e indicam cobertura incompleta"*.

---

## 6. Prova (execução, não afirmação)

`tests/orphan_visibility_test.sql` roda em base **descartável** (`hs-t021`,
`postgres:16-alpine`, banco `hs021`), aplicando `db/001`–`db/006` + `db/011`. É uma
única transação que termina em `ROLLBACK`. **27/27 verificações PASS**, incluindo:

- **C1** — o produto, sua `presentation` e sua `presentation_sources` **sobrevivem** ao
  `DELETE FROM users` (contagem antes/depois: `products` 2 → 2; `line_items` 1 → 0;
  `purchase_notes` 1 → 0);
- **C3** — o órfão sai de `v_catalog_coverage` com `has_history = false`,
  `stores_count = 0`, `last_seen_date IS NULL`;
- **C4** — o órfão **não aparece** em `v_best_price` nem em `v_current_prices` (0
  linhas, sem erro, sem preço inventado), enquanto o produto de 2 lojas segue
  comparável;
- **C5** — o órfão é reutilizável: um comprador novo volta `has_history` para `true`
  sem escrita em `products`;
- **C6** — `products` **não** ganhou coluna nem trigger; `v_catalog_coverage` é uma
  view.

Reproduzir:

```
docker run -d --name hs-t021 -e POSTGRES_PASSWORD=t021 -e POSTGRES_USER=hs \
    -e POSTGRES_DB=hs021 postgres:16-alpine
docker cp db hs-t021:/db ; docker cp tests hs-t021:/tests
docker exec hs-t021 psql -v ON_ERROR_STOP=1 -U hs -d hs021 -q \
  -f /db/001_schema.sql -f /db/002_schema.sql -f /db/003_triggers.sql \
  -f /db/004_indexes_views.sql -f /db/005_presentations_form_model.sql \
  -f /db/006_presentation_identifier_review_provenance.sql \
  -f /db/011_orphan_visibility.sql -f /tests/orphan_visibility_test.sql
```

**Canônico intocado.** Nenhum `ALTER`/`INSERT`/`DELETE` foi aplicado a
`home_shopper-db`. Conferido depois do teste: `v_catalog_coverage` **não existe** no
canônico (0 views com esse nome) e suas contagens seguem as do documento de banco
canônico (`users=1`, `products=384`, `line_items=573`). Aplicar `db/011` no canônico é
trabalho do PR/da integração, depois da auditoria — este card **não** aplica.

---

## 7. Consequência aceita e o que este documento não decide

**Aceito:** o órfão fica sem preço e sem histórico. É ausência de dado, e ausência de
dado é honesta. A UI declara "sem histórico de preço".

**O que este documento não decide:**

- Se `v_catalog_coverage` deve ganhar uma versão escopada por `user_id` além da
  global, por causa do sinal residual de `last_seen_date` (§4.3).
- Quem pode pedir a exclusão e como a identidade do titular é verificada (herdado do
  ADR-0005).
- Política de retenção/expurgo do e-mail em `data_erasure_requests` e do payload de
  `audit_log` (herdado do ADR-0005).
- Se o catálogo (e, portanto, os órfãos) será exposto publicamente para consulta.
