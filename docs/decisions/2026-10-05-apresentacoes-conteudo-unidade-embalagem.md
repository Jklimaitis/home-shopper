# Decisão — conteúdo, unidade e embalagem da apresentação (internal task)

**Status:** **DECIDIDO — não implementado** (`ddl_applied: false`)
**Decisão de:** **Jonas** (dono da decisão) · **execução:** engenharia
**Data:** 2026-10-05
**Registrada em:** 2026-10-05 13:25 (-03), comentário `[DECISAO FINAL JONAS 2026-10-05]`
no card `internal task` (`internal task`), board
**Fonte:** comentários do card `internal task` — `[DECISAO JONAS 2026-10-05 - parcial]`
(13:24) e `[DECISAO FINAL JONAS 2026-10-05]` (13:25)
**Referência:** `<internal review>` (Pontos B e C e o "Próximo ponto
da revisão"), `db/001_schema.sql` (`presentations`), card de execução `internal task`
(`internal task`)

---

## 0. Decisão registrada (o que ficou decidido)

O segmento 1 do `internal task` foi encerrado com **4 decisões, todas na opção A** recomendada
tecnicamente. Nenhuma foi aplicada ao schema: este documento registra as decisões, não a
implementação.

| # | Questão | Decisão (opção A) | Data | Autor |
|---|---|---|---|---|
| **1** | Conteúdo (`FIXED` / `VARIABLE` / `UNKNOWN`) | `content_kind` enum `FIXED`/`VARIABLE`/`UNKNOWN` **NOT NULL** + `content_quantity` NUMERIC NULL, só quando `FIXED` | 2026-10-05 | Jonas |
| **2** | Unidade de venda | `sale_unit` **verbatim** + camada `sale_unit_recognized` (enum controlado); `ck_presentations_sale_unit` afrouxada para apenas não-vazio | 2026-10-05 | Jonas |
| **3** | Embalagem individual | `container_type` enum (`cx`/`pc`/`pct`/`sc`/`lt`/`un`) + `content_quantity` + `content_unit` reusando o enum `base_unit` | 2026-10-05 | Jonas |
| **4** | Multipack | `multipack_quantity` INT NULL + extração **conservadora** | 2026-10-05 | Jonas |

**Adicional aprovado:** Open Food Facts como candidato a **pré-preencher**
`content_quantity`/`content_unit` **somente onde houver GTIN válido**, sempre com
**revisão humana**.

**Consequências aceitas:**

- A decisão **não** aplica DDL, não altera `db/`, não migra dado e não aceita ADR.
- Colunas finais, unicidade e FKs de `presentations`/`products` **não** são decididos
  neste segmento — são o escopo de `internal task` (`internal task`).

## 1. As 4 decisões, transcritas do card

Transcrição literal do comentário `[DECISAO FINAL JONAS 2026-10-05]`; nada reconstruído.

### 1.1 CONTEÚDO

`content_kind` enum `FIXED`/`VARIABLE`/`UNKNOWN` **NOT NULL** + `content_quantity` NUMERIC
NULL, preenchido **só** quando `FIXED`. `ck_presentations_content` exige quantidade não nula
**se e somente se** `content_kind = FIXED`.

**Justificativa ratificada (verbatim):** *"o ruling `desconhecido=ausencia de linha` foi
arbitrado para `product_attributes`, nao para o conteudo da apresentacao; `VARIABLE` (carne a
peso) e estado positivo e nao pode ser ausencia; a regra aprovada proibe zero para ausente."*

### 1.2 UNIDADE

Manter `sale_unit` **verbatim** + criar a camada `sale_unit_recognized` (enum controlado) +
afrouxar `ck_presentations_sale_unit` para apenas **não-vazio**, movendo a validação para a
camada reconhecida.

### 1.3 EMBALAGEM INDIVIDUAL

`container_type` enum (`cx`/`pc`/`pct`/`sc`/`lt`/`un`) + `content_quantity` + `content_unit`
reusando o enum `base_unit`.

### 1.4 MULTIPACK

`multipack_quantity` INT NULL + extração **conservadora**: `NxM` só é pacote se o segundo
fator carregar unidade de consumo; `c/N` e `Nun` vão para revisão; sem confirmação, a linha
fica pendente.

### 1.5 ADICIONAL — enriquecimento externo

Open Food Facts aprovado como candidato a **pré-preencher** `content_quantity`/`content_unit`
**somente onde houver GTIN válido**, sempre com **revisão humana**. **Não** é fonte dos demais
campos e **não** é importação automática.

## 2. Evidência que sustentou a decisão

A direção foi tomada sobre evidência real: **573 linhas** de compra e o recorte brasileiro do
Open Food Facts com **36.567 registros** (síntese em
[`docs/research/2026-10-03-openfoodfacts-brazil.md`](../research/2026-10-03-openfoodfacts-brazil.md)).
A decisão em si está transcrita no §1; a evidência é o lastro, não o contrato.

### 2.1 Correção ao teto de enriquecimento por GTIN (verificada)

O card `internal task` registrava o teto de enriquecimento por Open Food Facts como
`202/573 = 35,3%`. **O denominador estava poluído.** Correção da coordenação, verificada:

- Os **4 arquivos reconstruídos** (106 linhas, `sources/recovered/`) **não** têm o campo
  `observed_code`: a reconstrução lê de `home_shopper`, e o schema só guarda `products.ean`, que
  está NULL nas 573 linhas. O código de barras **nunca existiu no banco** — só nos 7 arquivos
  preservados.
- Sobre as **467 linhas que carregam código**: `202/467 = 43,3%`.
- Das **106 reconstruídas** o código é **desconhecido (perdido)**, nunca "sem código".
- `count(ean) = 0` em `products.ean` nas 15 notas.
- A conclusão qualitativa se mantém: só o Supermarket A contribui GTIN (202/283 linhas
  dela); os outros 5 emissores contribuem zero.

**Consequência para a decisão 1.5:** qualquer regra futura que dependa de GTIN deve usar
**43,3%** como teto entre linhas com código, e tratar as 106 linhas reconstruídas como
"código perdido", nunca como "sem código".

## 3. `ddl_applied: false` — o que NÃO foi feito

- **Nada foi aplicado no schema.** `db/` permanece como em `628601f`; não há coluna nova,
  enum novo nem constraint nova.
- O corpo atual de `presentations` (`db/001_schema.sql`) ainda tem:
  `ck_presentations_sale_unit CHECK (sale_unit ~ '^[A-Za-z]{1,4}$')` — a versão **antiga**
  que a decisão 2 manda afrouxar — e **não** tem `content_kind`, `content_quantity`,
  `sale_unit_recognized`, `container_type` nem `multipack_quantity`. `ck_presentations_content`
  **não existe** hoje; é constraint a criar na implementação.
- Não houve migração de dado, nem matcher, nem aceitação de ADR.

## 4. Fora deste segmento (escopo de `internal task`)

Não decidido aqui:

- **colunas finais** de `presentations`/`products`;
- **unicidade** (ex.: a chave `uk_presentations_product_key_store` e a definição de "global"
  via `store_id` NULL);
- **FKs** e coerência referencial;
- preservação da interpretação histórica das compras.

## 5. Convenções que a implementação terá de respeitar

- `snake_case` minúsculo, identificadores em inglês; tabelas no plural.
- **Toda constraint nomeada**: `pk_` `fk_` `uk_` `ck_` (a CI falha se alguma não seguir).
- Dinheiro é `NUMERIC`, nunca float.
- `base_unit` é só `UN`/`G`/`ML` (sem `KG`/`L`); `content_unit` (decisão 3) **reusa** esse
  mesmo enum.
- Nome de loja em ASCII, como o emissor declara; descrição de produto fica verbatim da fonte.
- 3NF; `user_id` em toda tabela de negócio, ausente do catálogo.

## 6. Limites deste registro

- **Só documentação.** Não executa DDL, não altera `db/`, não migra dado, não aceita ADR,
  não altera o schema.
- Não faz commit nem push — o commit deste arquivo é do coordenador, com autorização do
  Jonas.
- Nenhum dado de compra real, chave de acesso ou CPF é transcrito aqui.
