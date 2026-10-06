# PRD — home_shopper

> **Versão:** 2.2
> **Data:** 2026-10-01 · **Revisões:** 2.1 e 2.2 em 2026-10-05
> **Status:** **Proposta para validação** — não autoriza implementação, migração nem alteração de schema.
> **Validação realizada em 2026-10-05**, sobre a v2.0 (`sha256 3b64c8f7…`):
> uma validação técnica independente e
> uma validação de UX independente.
> **v2.1** corrige C-1, C-3 e A-4 desses pareceres. **v2.2** corrige a §10.1 (o design system passou a
> existir às 01:56 de 2026-10-05, depois da v2.1). Permanecem abertos: **C-2, C-4, A-1, A-2, A-3** e
> os bloqueios do parecer de UX. Editar invalidou o hash pinado pelos dois pareceres — eles valem
> para a v2.0.
> **Substitui:** PRD.md v1.0 (11 seções), commit `374c9ba`. O original está preservado no git e em
> `<internal>/<internal>`.
> **Compatibilidade de citações:** os âncoras `PRD §x.y` usados por 6 ADRs e 3 specs são preservados
> em blocos rotulados. Crosswalk completo no **Anexo A**.

---

## 1. Visão Geral do Produto

### 1.1 Descrição

O home_shopper é um monitor de preços de supermercado. Ele lê notas fiscais de compras reais,
reconhece **qual produto canônico** cada linha descreve, re-expressa todo preço em uma unidade-base
comparável e mostra ao usuário **onde o mesmo produto está mais barato**.

Três camadas:

1. **Catálogo canônico** — identidade de produto compartilhada entre lojas.
2. **Camada de staging** — dados brutos da nota, isolados por usuário, até a revisão humana.
3. **Camada confiável** — compras consolidadas, preços por unidade-base e comparação entre lojas.

### 1.2 Problema que Resolve

Comparar o preço do mesmo produto entre lojas falha por três motivos. O projeto existe para resolver
os três.

**1. O mesmo produto tem nome diferente em cada loja.**
`CARNE MOIDA COMBO 1kg` (nota 1, R$ 29,90) e `MOIDA COMBO 1KG` (nota 3, R$ 27,90) são o mesmo corte.
Normalização textual não atravessa essa distância — nenhuma regra de string transforma um no outro.
Equivalência é **fato aprendido**, e fato aprendido mora em tabela (`synonyms`), não em código.

**2. O mesmo produto é vendido em unidades diferentes.**
R$ 5,49 por `UN` e R$ 59,88 por `CX` de 12 não estão a 10× de distância — são o mesmo preço. Todo
preço é re-expresso na **unidade-base** do produto (`base_price`) antes de qualquer comparação.

**3. Alimento fresco não tem código de barras.**
Nas notas auditadas, **zero** itens traziam EAN. O código de 7 dígitos impresso no cupom pertence ao
**emissor** e muda entre CNPJs — não é identidade. A identidade real é
`marca + nome normalizado + tamanho`.

### 1.3 Proposta de Valor

- **Para o comprador recorrente:** saber, antes de sair de casa, qual das redes onde ele já compra
  está mais barata para os itens que ele realmente consome — por preço comparável, não por preço de
  embalagem.
- **Para o segundo usuário:** o catálogo canônico é **compartilhado** (ADR-0004). O trabalho de
  identificação de um usuário beneficia os demais, e a comparação entre lojas não depende de cada um
  manter seu próprio cadastro.
- **Para o revisor:** o sistema nunca inventa equivalência. Ele diz "não consegui identificar" e
  entrega a decisão ao humano, com os candidatos e as divergências visíveis.
- **Diferencial técnico:** o projeto não para na detecção — ele **aciona a comunicação** quando o
  preço cai. Detectar uma queda e disparar a mensagem certa, uma única vez, é território onde o autor
  já tem experiência (MarTech/CRM). É o passo que separa este projeto de um rastreador de preços
  genérico.

### 1.4 Diagnóstico do Estado Atual

> ↩ **citação legada: PRD §1** (era a seção 1 da v1.0). Conteúdo preservado.

#### 1.4.1 Schema implementado (código real)

> ↩ **citação legada: PRD §1.1**

- `products`: unicidade por `(name, brand)` — não captura variante (leite integral vs desnatado colidem)
- `presentations`: funde descrição + loja + conversão — não separa conteúdo de forma comercial
- `match_key`: gerado via `lower()` + `regexp_replace('[^a-z0-9]+', ' ')` — normaliza capitalização e
  espaços, mas **não há matcher automático**
- `synonyms`: palavra→palavra, não descrição completa→produto
- `staging_lines.match_source`: registra origem (`BARCODE`, `DESCRIPTION`, `ALIAS`, `MANUAL`, `NONE`)
  mas não há algoritmo
- **Zero** atributos estruturados por categoria
- **Zero** representação de recipiente/tipo de embalagem

**Estado verificado do schema:** 14 tabelas · 5 views · 48 indexes · 14 triggers · 4 enums
(`docs/ERD.md`). Schema PostgreSQL 16 aplicado e coberto por testes de domínio
(`tests/smoke_test.sql`).

#### 1.4.2 Propostas existentes (não implementadas)

> ↩ **citação legada: PRD §1.2** — atualizada: a ADR-0001 passou de `proposed` para `accepted` em
> 2026-10-01, e as ADRs 0003–0006 foram escritas depois da v1.0.

- **ADR-0001** (**aceita**) — separação produto canônico vs apresentação; critérios de equivalência
  por categoria; tratamento de ambiguidade. Aceitação quanto à **direção de domínio**: não autoriza
  alteração de schema, migração ou implementação
- **ADR-0002** (proposta) — reutilização de associações; revisão humana; consolidação parcial
- **ADR-0003** (rascunho, retroativa) — unidades, `base_price` e agregação. **Já implementada no
  código**; o documento existe para revisão
- **ADR-0004** (rascunho) — catálogo compartilhado e isolamento. Parcialmente implementada
- **ADR-0005** (rascunho) — LGPD. Exclusão implementada; **retenção e expurgo não existem**
- **ADR-0006** (rascunho) — ingestão assíncrona, idempotência. Schema existe; **fluxo não**

#### 1.4.3 Gap

> ↩ **citação legada: PRD §1.3**

Não há como decidir se `LEITE UHT HERC CX 12UN` e `LEITE INTEGRAL HERC 1L` são o mesmo produto, nem se
`COXA FRANGO` e `COXA DE FRANGO SWIFT 1 kg` são equivalentes. A comparação entre lojas — o core do
produto — não funciona.

**O que não existe hoje, por camada:**

| Camada | Estado |
|---|---|
| Schema PostgreSQL 16 | **Pronto** — 14 tabelas, 5 views, 48 indexes, 14 triggers |
| API | **Inexistente** — nenhum endpoint HTTP |
| Worker / fila | **Inexistente** — sem Celery, sem Redis |
| Matcher de produtos | **Inexistente** — nenhuma linha de algoritmo |
| Frontend | **Inexistente** — zero `.html`, `.css`, `.js` |
| Alimentação de `price_refs` | **Inexistente** — tabela vazia |

#### 1.4.4 Dados reais disponíveis para teste

Números auditados em `<internal record>` (revisão de 2026-10-05):

| Métrica | Valor verificado |
|---|---|
| Notas com `access_key` no banco | **13** |
| Notas com fonte preservada em área privada | **11** |
| Linhas de item nas 11 notas com fonte | **467** |
| Emissores distintos | **5** |
| Arquivos de origem | 7 |
| Itens com EAN | **0** |

**Lacuna aberta:** 2 notas com `access_key` no banco não têm fonte localizada (2026-04-11 e
2026-06-18). A cobertura é parcial por contrato do piloto PILOT-B, que permanece **bloqueado**.

> ✅ **Reconciliado na v2.1 (achado A-4).** As três fontes mediam coisas diferentes:
>
> | Fonte | O que mede | Valor |
> |---|---|---|
> | Banco consultado (base `home_shopper`) | camada confiável consolidada | **15 notas / 573 linhas / 7 cadastros de loja** |
> | Inventário auditado | **fontes preservadas** em área privada | 11 notas / 467 linhas / 5 emissores |
> | `<internal plan>` (versão antiga) | — | "480 itens / 6 redes" — **errado nos itens** |
>
> 467 ≠ 573 porque 467 é o subconjunto de 11 notas **com fonte preservada**; o banco tem 15 notas.
> `staging_receipts` e `staging_lines` estão **zerados** nessa base: os dados foram carregados
> **direto na camada confiável**, sem passar pelo staging.
>
> ⚠ **Ressalva de procedência — decisão do Jonas (2026-10-05).** Os 15/573/7 vêm da base **`home_shopper`**,
> servida pelo container avulso `postgres` (criado por `docker run`, sem label de Compose). O
> `docker-compose.yml` do **próprio repositório** define o container `home_shopper-db`, base/usuário
> `home_shopper` — credenciais da CI — e essa base está **vazia** (schema aplicado: 14 tabelas e 5
> views; zero linhas).
>
> **O banco canônico é `home_shopper-db`.** Os números desta seção descrevem `home_shopper` até que o
> canônico seja repovoado.
>
> ⚠ **Sem loader para repovoar.** O `README.md` §"Run it" chama de "loader" o laço
> `for f in db/*.sql; do psql ... -f "$f"; done` — que aplica **schema**, não dados. Não existe no
> repositório nenhum script que carregue as notas: `scripts/` contém apenas `guard_dados_sensiveis.py`.
> O inventário registra que a lista `RECEIPTS` do loader não tem arquivo em comum com as fontes
> preservadas. Repovoar `home_shopper-db` exige **escrever ou localizar** esse loader — o caminho de
> origem dos 15 registros de `home_shopper` é desconhecido.

---

## 2. Público-Alvo

### 2.1 Persona primária — o comprador recorrente

| Atributo | Detalhe |
|---|---|
| **Nome fictício** | O usuário principal, 30 e poucos anos |
| **Contexto** | Compra em alguns tipos de loja (mercado de bairro, atacadão, rede regional). Guarda cupom, compara preço, faz mercado semanal e mensal |
| **Dor principal** | Não consegue saber se o arroz que ele compra está mais barato no atacadão ou no sacolão. O preço da embalagem engana: pacote de 500 g parece mais barato que 1 kg |
| **O que busca** | Uma resposta direta: "onde é mais barato comprar X", por preço comparável |
| **Habilidade técnica** | Avançada (é desenvolvedor) — mas aqui é **usuário** do produto, não operador |
| **Ações no sistema** | Envia notas, revisa pendências, consulta comparações |

### 2.2 Persona secundária — o segundo usuário

| Atributo | Detalhe |
|---|---|
| **Nome fictício** | Ana, 40 anos |
| **Contexto** | Outra pessoa usando a mesma instância. O catálogo de produtos é **compartilhado** (ADR-0004 §1) |
| **Dor principal** | Mesma do Jonas, mas ela não vai cadastrar catálogo — ela espera que já exista |
| **O que busca** | Comparação funcionando no primeiro uso, sem trabalho de cadastro |
| **Habilidade técnica** | Básica |
| **Ações no sistema** | Envia notas, revisa as próprias pendências, consulta comparações |

**O que sustenta esta persona:** `products`, `stores`, `presentations` e `categories` **não têm
`user_id`** — são globais por desenho. `staging_receipts`, `purchase_notes`, `line_items`,
`price_refs` e `price_alerts` **têm `user_id` NOT NULL** e são isolados (ADR-0004 §1).

> ⚠ **Dependência aberta:** a persona existe no schema, mas a **autorização de escrita no catálogo
> global** não está decidida (ADR-0004 §"O que este documento não decide"). Enquanto isso, Ana se
> beneficia do catálogo do Jonas, mas não pode contribuir para ele. Ver §13.9.

### 2.3 Papel operacional — o revisor

Não é uma persona de produto: é o papel que **resolve pendências de identificação**. Hoje é a mesma
pessoa do comprador (o próprio Jonas revisando as próprias notas). O sistema precisa suportar esse
papel sem presumir que ele seja outro humano — mas a **tela de revisão** (spec
`2026-10-01-review-screen-ux.md`) já existe nesse desenho.

---

## 3. Arquitetura do Sistema

### 3.0 Regra de Versionamento de Dependências

**Não se aplica.** O home_shopper **não usa LLM, embeddings, vector store nem framework de IA
generativa**. As categorias de comparação são regras determinísticas por categoria (§6.2.2), não
inferência de modelo. Não há versões mínimas de `langchain`/`langgraph`/`openai` a declarar.

Esta seção fica registrada como explicitamente vazia, e não como esquecimento — se um dia houver
classificação assistida por IA, ela entra como decisão nova com trade-off próprio (§13).

### 3.1 Diagrama de Arquitetura Geral

```
graph TB
    subgraph "Frontend (SPA)"
        DASH[Dashboard]
        CMP[Product Comparison]
        STORE[Store Detail]
        REVIEW[Review Queue]
    end
    subgraph "API"
        FAST[FastAPI]
        R_IN[POST /receipts/upload]
        R_READ[GET /products, /stores, /categories]
        R_PRICE[GET /products/id/prices]
    end
    subgraph "Async (fila)"
        BROKER[Redis broker]
        WORKER[Celery worker]
        BEAT[Celery beat - job de agregacao]
    end
    subgraph "Dominio"
        PARSER[Parser NFC-e]
        MATCHER[Matcher por categoria]
        AGG[Agregador price_refs]
    end
    subgraph "Data Layer"
        PG[(PostgreSQL 16)]
        DISK[Disco - imagem de cupom]
    end
    DASH --> FAST
    CMP --> FAST
    STORE --> FAST
    REVIEW --> FAST
    R_IN --> FAST
    R_READ --> FAST
    R_PRICE --> FAST
    FAST --> PG
    FAST --> BROKER
    FAST --> DISK
    BROKER --> WORKER
    BEAT --> BROKER
    WORKER --> PARSER
    WORKER --> MATCHER
    WORKER --> PG
    AGG --> PG
    BEAT --> AGG
```

**Fonte da stack:** `README.md` ("Planned pipeline: FastAPI → PostgreSQL → Celery (queue) →
PostgreSQL → dashboard") e `<internal plan>` (FastAPI + Celery + Redis + SPA).

> ⚠ **A stack não está ratificada em ADR nem no PRD v1.0.** Ela aparece em `README.md` e num
> documento de **cadência** (`<internal plan>`), que não é o lugar de uma decisão estrutural. Está
> registrada aqui como decisão técnica em §13.1 e §13.2, **pendente do aval técnico**.

### 3.2 Modelo de Isolamento

**Não é multi-tenant.** A estratégia é **catálogo global + isolamento de compra por `user_id`**
(ADR-0004):

| Natureza | Tabelas | `user_id`? |
|---|---|---|
| Catálogo (compartilhado) | `products`, `categories`, `stores`, `presentations` | **Não** — globais por desenho |
| Compra (isolada) | `staging_receipts`, `purchase_notes`, `line_items`, `price_refs`, `price_alerts` | **Sim** — `NOT NULL` |
| Auditoria / LGPD | `audit_log`, `data_erasure_requests` | `user_id` **sem FK** — precisa sobreviver ao `DELETE` |

**Regra de isolamento:** toda consulta de negócio filtra por `user_id`. Não é opcional, é a condição
de acesso.

> ⚠ **Risco real desta arquitetura:** o isolamento é **disciplina de aplicação, não restrição de
> banco**. Nada impede uma view nova de omitir o filtro. A ADR-0004 nomeia isto como o primeiro item
> a resolver na próxima revisão — e a spec de UX da tela de revisão já tropeça nisso (a consulta nova
> de linhas por nota precisa do filtro que `v_review_queue` não impõe). Ver §13.4.

### 3.3 Pipeline de Dados

```
Upload → staging_receipts (PENDING)
       → staging_lines (linhas brutas)
       → [matcher] → sugestões / pendências
       → [revisão humana] → vínculo por linha
       → [consolidação parcial] → purchase_notes + line_items (base_price por trigger)
       → [job de agregação] → price_refs
       → [painel] → comparação entre lojas
```

**Regra que atravessa o pipeline:** *upload concluído significa documento recebido, não nota
aprovada.* Nada entra em `purchase_notes` ou `price_refs` antes da revisão (ADR-0006 §1).

---

## 4. Modelo de Dados

### 4.1 Diagrama ER

Fonte canônica: **`docs/ERD.md`** — gerado a partir do schema aplicado em PostgreSQL 16.
**14 tabelas, 5 views, 48 indexes, 14 triggers, 4 enums.** Toda constraint é nomeada
(`pk_`, `fk_`, `uk_`, `ck_`).

```
erDiagram
    users {
        uuid id PK
        text name
        text email UK
    }
    stores {
        uuid id PK
        text name
        char14 cnpj UK
        char7 ibge_code
    }
    categories {
        uuid id PK
        text name UK
        uuid parent_id FK
    }
    products {
        uuid id PK
        text name
        uuid category_id FK
        text brand "nullable: fresh produce"
        text ean UK "partial index"
        enum base_unit "UN, G, ML"
    }
    synonyms {
        uuid id PK
        text term
        text expands_to
        text scope "nullable = global"
    }
    presentations {
        uuid id PK
        uuid product_id FK
        text sale_unit "UN, CX, KG, PC as printed"
        numeric factor_base
        text description_raw
        text description_norm
        text match_key "generated"
        uuid store_id FK "null = global wording"
    }
    staging_receipts {
        uuid id PK
        uuid user_id FK
        enum source "MANUAL, QRCODE, SEFAZ, OCR, IMPORT"
        text source_ref
        text source_ref_norm
        enum status "PENDING, IN_REVIEW, DONE, DISCARDED"
        text file_path "path only, never a BLOB"
        numeric total_gross
        integer divergence_cents
        integer attempts
    }
    staging_lines {
        uuid id PK
        uuid receipt_id FK
        smallint line_no
        text description_raw
        text store_code
        text sale_unit
        numeric quantity
        numeric unit_price
        numeric line_total
        uuid product_id FK "null = unmatched"
        uuid presentation_id FK
        enum match_source "BARCODE, DESCRIPTION, ALIAS, MANUAL, NONE"
        boolean reviewed
        boolean discarded
    }
    purchase_notes {
        uuid id PK
        uuid user_id FK
        uuid store_id FK
        uuid staging_receipt_id FK
        char44 access_key "partial unique: idempotency"
        date purchase_date
        numeric amount_paid
    }
    line_items {
        uuid id PK
        uuid note_id FK
        uuid product_id FK
        uuid presentation_id FK "NOT NULL"
        numeric quantity
        numeric unit_price
        numeric base_price "per base_unit, by trigger"
        enum base_unit "derived by trigger"
    }
    price_refs {
        uuid id PK
        uuid user_id FK
        uuid product_id FK
        uuid store_id FK
        date ref_date
        numeric base_price
        numeric min_30d
        numeric max_30d
        numeric var_pct_30d
    }
    price_alerts {
        uuid id PK
        uuid user_id FK
        uuid product_id FK
        uuid price_ref_id FK "ON DELETE SET NULL"
        text alert_type "PRICE_DROP, PRICE_RISE, BEST_PRICE"
        numeric var_pct
        boolean read
    }
    data_erasure_requests {
        uuid id PK
        uuid user_id "no FK: must outlive the DELETE"
        text email
        integer notes_removed
        integer items_removed
    }
    audit_log {
        bigserial id PK
        uuid user_id "no FK: actor metadata"
        text table_name
        text operation
        uuid record_id
        jsonb before_data
        jsonb after_data
    }
    users ||--o{ purchase_notes : "makes"
    users ||--o{ staging_receipts : "submits"
    users ||--o{ price_refs : "observes"
    users ||--o{ price_alerts : "receives"
    users ||--o{ audit_log : "acts"
    users ||--o{ data_erasure_requests : "requests erasure"
    stores ||--o{ purchase_notes : "issues"
    stores ||--o{ staging_receipts : "identified in"
    stores ||--o{ presentations : "has own wording for"
    categories ||--o{ categories : "contains"
    categories ||--o{ products : "classifies"
    products ||--o{ presentations : "sold as"
    products ||--o{ line_items : "bought"
    products ||--o{ staging_lines : "matched in"
    products ||--o{ price_refs : "monitored"
    presentations ||--o{ line_items : "unit charged"
    presentations ||--o{ staging_lines : "unit observed"
    staging_receipts ||--o{ staging_lines : "raw lines"
    staging_receipts |o--o| purchase_notes : "becomes a reviewed note"
    purchase_notes ||--|{ line_items : "contains"
    purchase_notes }o--|| price_refs : "feeds"
    price_refs ||--o{ price_alerts : "triggers"
```

### 4.2 Descrição das Entidades

| Entidade | Descrição |
|---|---|
| **users** | Usuário da plataforma. `DELETE` em cascata remove compras; catálogo sobrevive (ADR-0004 §5) |
| **stores** | Estabelecimento emissor. CNPJ identifica **pessoa jurídica** — dado público, não sensível |
| **categories** | Categoria do produto, com hierarquia (`parent_id`). As 8 do escopo estão em §6.2.2 |
| **products** | Produto canônico — identidade do **conteúdo**. Sem `user_id`: é global |
| **synonyms** | Abreviação/sinônimo com escopo. **No schema, `scope NULL = global`** — o default do banco é **global**, não local (corrigido na v2.1, achado C-3) |
| **presentations** | Forma comercial: quantidade, unidade, embalagem e `factor_base`. Funde alias e conversão **de propósito** |
| **staging_receipts** | Nota recebida, ainda **não confiável**. Isolada por `user_id` |
| **staging_lines** | Linha bruta da nota. `description_raw` é a fonte de verdade da revisão |
| **purchase_notes** | Compra **consolidada** — camada confiável. `access_key` garante idempotência |
| **line_items** | Item consolidado, com `base_price` **derivado por trigger** |
| **price_refs** | Preço de referência por usuário × produto × loja × dia. Populado por **job**, não por trigger |
| **price_alerts** | Alerta entregue. `price_ref_id` é `ON DELETE SET NULL`: recomputar preço não apaga o histórico de comunicação |
| **data_erasure_requests** | Prova da exclusão LGPD, escrita **antes** do `DELETE`. Sem FK para `users` |
| **audit_log** | Rastro de auditoria em JSONB. `user_id` sem FK — metadado de autor |

### 4.3 Atributos por Categoria

> ↩ **citação legada: PRD §4.2**

Cada categoria define quais atributos são relevantes para equivalência:

- **Laticínios:** `fat_content`, `lactose_free`, `flavor`
- **Carnes:** `species`, `cut`, `seasoning`, `brand`
- **Mercearia:** `product_type`, `flavor`, `variant`
- **Bebidas:** `type`, `flavor`
- **Hortifruti:** `variety`
- **Padaria:** `type`, `flavor`
- **Limpeza:** `product_type`, `variant`
- **Higiene:** `product_type`, `variant`

Fonte ratificada dos critérios e exemplos por categoria:
`docs/superpowers/specs/2026-10-01-product-equivalence-by-category.md` (status `accepted`).

### 4.4 Entidades de Produto

> ↩ **citação legada: PRD §4.1**

- **Product**: produto canônico (identidade do conteúdo)
- **Presentation**: forma comercial (quantidade, unidade, embalagem)
- **Category**: categoria do produto (com hierarquia)
- **Synonym**: abreviação/sinônimo (palavra→palavra, com escopo)
- **ProductAttribute**: atributo estruturado por categoria — **proposto, não implementado**
  (internal task-A)

### 4.5 Representação de Recipiente e Quantidade

> ↩ **citação legada: PRD §4.3**

- `container_type`: tipo de embalagem (cx, pc, pct, sc, lt, un) — **proposto**
- `content_quantity`: quantidade de conteúdo (ex: 1000, 500, 340) — **proposto**
- `content_unit`: unidade de conteúdo (g, ml, un) — **proposto**
- `multipack_quantity`: quantidade de unidades no pacote (ex: 12 para `CX 12UN`) — **proposto**

> ⚠ Hoje o schema implementa isto **parcialmente**: `presentations.sale_unit` + `factor_base` cobrem
> a conversão, mas não há atributo estruturado para tipo de embalagem (ADR-0001 §"Relação com o
> banco atual"). A representação completa depende de internal task-A.

### 4.6 As Três Decisões que o ER Torna Visíveis

**(1) `presentations` funde a tabela de lookup com a conversão de unidade.** A descrição truncada do
cupom (`LEITE UHT HERC CX 12UN`) já carrega quantas unidades-base o pacote contém. Separar "alias" de
"fator de conversão" em duas tabelas duplicaria o dado e deixaria os dois divergirem.

**(2) Não existe código de produto interno à loja.** O código de 7 dígitos no cupom pertence ao
**emissor**: o mesmo corte de carne tem código diferente em cada CNPJ, e este projeto existe para
comparar **entre** lojas. Uma chave que muda entre as lojas que se quer comparar não é chave — é
ruído confiante. O código vive em `staging_lines`, onde acelera a captura, e nunca é propagado.

**(3) `base_price` é derivado, nunca digitado.** O trigger `tr_line_items_base_price` calcula
`unit_price / factor_base` e **recusa a linha** quando a apresentação está por resolver. É o que
impede um pacote de 250 g e um de 1 kg de serem comparados como se fossem a mesma coisa.

---

## 5. Módulos do Sistema

**Nenhum módulo existia na data desta proposta.** A estrutura abaixo é `PROPOSTA` — depende de decisão técnica
(§13.1). Não há código de aplicação no repositório: o que existe é `db/*.sql`,
`scripts/guard_dados_sensiveis.py`, `tests/smoke_test.sql` e `fixtures/`.

```
home_shopper/
├── db/                  # schema, triggers, indexes, views (EXISTE)
├── scripts/             # guard de dados sensíveis (EXISTE)
├── tests/               # smoke_test.sql (EXISTE)
├── fixtures/            # dados anonimizados (EXISTE)
├── api/                 # PROPOSTA - FastAPI: routers, schemas, deps, auth
├── ingest/              # PROPOSTA - parser NFC-e, staging, idempotência
├── matcher/             # PROPOSTA - normalização, extração, candidatos, decisão
├── catalogue/           # PROPOSTA - products, presentations, categories, synonyms
├── review/              # PROPOSTA - fila de revisão, decisão por linha
├── analytics/           # PROPOSTA - agregação, price_refs, comparação
├── worker/              # PROPOSTA - tasks Celery, beat, retry
└── web/                 # PROPOSTA - SPA consumindo a API
```

| Módulo | Responsabilidade | Fonte |
|---|---|---|
| **api** | Endpoints HTTP, contrato, validação de entrada, isolamento por `user_id` | §11 |
| **ingest** | Receber nota, parsear, popular staging, garantir idempotência, conferir checksum | ADR-0006 |
| **matcher** | Normalizar, extrair atributos por categoria, buscar candidatos, decidir MATCH / NÃO-MATCH / PENDENTE | §6.2, spec de equivalência |
| **catalogue** | Identidade canônica e apresentações. **Escrita no catálogo global está sem autorização definida** | ADR-0004 |
| **review** | Fila de pendências, decisão por linha, registro do motivo | spec de UX |
| **analytics** | Agregação ponderada, `price_refs`, melhor preço, comparação | ADR-0003 |
| **worker** | Processamento assíncrono, retry, job de agregação | ADR-0006 |
| **web** | Painel: Dashboard, Comparação, Loja, Revisão | §10 |

---

## 6. Funcionalidades Detalhadas

### 6.1 Ingestão

#### F01 — Upload de nota fiscal

- **Descrição:** O usuário envia uma NFC-e (XML, QR code, ou upload de arquivo) e recebe confirmação
  de recebimento com um identificador de job.
- **Regras de Negócio:**
  - Resposta é `202 Accepted` com `job_id`
  - Upload concluído **não** significa nota aprovada
  - `staging_receipts.status` nasce `PENDING`
  - Nada entra em `purchase_notes` ou `price_refs` antes da revisão
- **Critérios de Aceite:**
  - [ ] Upload de uma nota real retorna `202 Accepted` com `job_id`
  - [ ] `staging_receipts` recebe a nota com `status = 'PENDING'`
  - [ ] Nenhum registro é criado em `purchase_notes` antes da revisão
- **Fonte:** ADR-0006 §1

#### F02 — Parser de NFC-e

- **Descrição:** Extrair cabeçalho e linhas da nota, populando `staging_receipts` e `staging_lines`.
- **Regras de Negócio:**
  - Preservar `description_raw` exatamente como impresso
  - Preservar valores originais da fonte (`sale_unit` incluído, mesmo rótulo opaco)
  - Campos não legíveis permanecem `null` — nunca inferidos
  - `store_code` é auxílio de leitura, nunca chave de match
- **Critérios de Aceite:**
  - [ ] Nota com 56 linhas tem as 56 linhas em `staging_lines`
  - [ ] `description_raw` é byte a byte igual à fonte
  - [ ] Rótulos opacos de unidade (`UND9`, `KG9`, `GFA9`, `PCT8`) são preservados como texto
- **Fonte:** ADR-0006, ADR-0001 r.11

#### F03 — Idempotência

- **Descrição:** Reprocessar a mesma nota não cria duplicata, na extração nem na consolidação.
- **Regras de Negócio:**
  - Camada 1: `uq_staging_receipts_source` em `(user_id, source, source_ref_norm)` com filtro
    `source_ref_norm <> ''`
  - Camada 2: `uq_purchase_notes_access_key` em `(user_id, access_key)`
  - `user_id` está nas duas porque o índice é **por pessoa**
- **Critérios de Aceite:**
  - [ ] Reprocessar a mesma nota não cria segunda linha em `staging_receipts`
  - [ ] Reprocessar uma nota consolidada não cria segunda `purchase_notes`
  - [ ] Duas notas manuais do mesmo usuário **não** colidem (filtro parcial funciona)
- **Fonte:** ADR-0006 §2

#### F04 — Conferência por checksum

- **Descrição:** A soma das linhas extraídas é comparada com o total declarado no cupom.
- **Regras de Negócio:**
  - Fórmula é `SUM(line_total)`, não a soma dos produtos brutos — a autoridade fiscal arredonda a
    linha, não o produto
  - Comparação usa **tolerância**, nunca igualdade exata
  - Desconto vive nos totais, não nas linhas: comparar a soma das linhas com o valor **pago**
    reportaria divergência em toda nota com desconto
  - Divergência **não descarta** a nota — ela vai para revisão humana com o valor visível
  - Linhas `discarded` são excluídas da soma
- **Critérios de Aceite:**
  - [ ] `1,446 kg × 39,90 = 57,6954 → 57,70` não reporta divergência falsa
  - [ ] Nota A32 (`550,93 − 6,00 = 544,93`) fecha com divergência 0
  - [ ] Nota com divergência real fica `IN_REVIEW`, com `divergence_cents` preenchido
  - [ ] Linha `discarded` não entra no `total_computed`
- **Fonte:** ADR-0003 §6, ADR-0006 §5

#### F05 — Ciclo de vida do staging

- **Descrição:** A nota percorre `PENDING → IN_REVIEW → DONE` (ou `DISCARDED`) sem que o documento
  original seja perdido.
- **Regras de Negócio:**
  - `purchase_notes.staging_receipt_id` é `ON DELETE SET NULL` — o registro original sobrevive
  - `attempts` conta tentativas, `error_message` guarda o diagnóstico
- **Critérios de Aceite:**
  - [ ] Falha no processamento incrementa `attempts` e popula `error_message`
  - [ ] Apagar a compra consolidada não apaga o staging original
- **Fonte:** ADR-0006 §3 e §4

### 6.2 Catálogo e Matching

> ↩ Esta subseção contém os âncoras **mais citados** do PRD v1.0. Os blocos 6.2.1 a 6.2.5 preservam
> o conteúdo e a numeração interna da v1.0.

#### 6.2.1 Regras de Identidade

> ↩ **citação legada: PRD §3.1** (as regras 1–8 preservam a numeração original)

**Produto canônico**: identidade do conteúdo comprado e das características relevantes à sua
equivalência, segundo a categoria.

**Apresentação**: forma comercial em que um produto é vendido (quantidade, unidade, tipo de
embalagem, configuração do pacote).

Regras:

1. Produtos com diferenças relevantes de conteúdo permanecem separados
2. Características independentes devem ser consideradas em conjunto (ex: teor de gordura + condição
   de lactose no leite)
3. Tamanhos e tipos de embalagem podem ser apresentações de um mesmo produto
4. A embalagem continua disponível como critério de escolha
5. Havendo informação insuficiente, contradição ou ambiguidade, o vínculo fica pendente de revisão
6. Código interno de loja e descrição do cupom são evidências, não identificadores globais
7. A comparação do mesmo produto exige identidade confirmada e unidade-base compatível
8. EAN é opcional e serve como identificador auxiliar

**Fonte:** ADR-0001 (aceita). A r.5 da ADR-0001 é a norma operativa:

> "A ausência de um atributo aplicável **nos dois lados da comparação**, sem informação que os
> distinga, não gera pendência. PENDENTE fica reservado ao caso em que um lado informa o atributo e o
> outro não, ou em que os valores conflitam."

#### 6.2.2 Critérios de Equivalência por Categoria

> ↩ **citação legada: PRD §3.2**

**Escopo ratificado:** as **8** categorias abaixo. Limpeza e Higiene entraram no escopo por decisão
do Jonas em 2026-10-05 (decisão D7, card `internal task`, que encerra o conflito com o review de
2026-10-03); **pet** e demais categorias ficam **fora** deste ciclo.

##### Laticínios (leite, iogurte, queijo)
- Atributos relevantes: marca, tipo (integral/desnatado/semidesnatado), condição de lactose, sabor
- `LEITE UHT INTEGRAL` ≠ `LEITE UHT DESNATADO` ≠ `LEITE UHT INTEGRAL ZERO LACTOSE`
- `LEITE UHT INTEGRAL 1L` = `LEITE UHT INTEGRAL CX 12UN` (mesmo conteúdo, apresentações diferentes)

##### Carnes
- Atributos relevantes: espécie, corte, preparo (com/sem tempero), marca
- Estado de conservação (refrigerado/congelado) **não** distingue
- `COXA DE FRANGO` = `COXA FRANGO` (se mesma espécie/corte)
- `CUPIM COMBO` ≠ `CUPIM` (combo é produto diferente)
- `CARNE MOIDA` ≠ `CARNE MOIDA COMBO`

##### Mercearia (enlatados, massas, etc.)
- Atributos relevantes: marca, tipo de produto, sabor/variante
- `EXTRATO DE TOMATE` ≠ `MOLHO DE TOMATE` ≠ `TOMATE PELADO`
- `EXTRATO DE TOMATE 340G` = `EXTRATO DE TOMATE SACHÊ 340G` (se mesma marca e formulação)

##### Bebidas
- Atributos relevantes: marca, tipo, sabor
- `COCA COLA 2L` = `COCA-COLA 2L`
- `COCA COLA 2L` ≠ `COCA COLA ZERO 2L`

##### Hortifruti
- Atributos relevantes: variedade, marca (quando aplicável)
- Marca ausente é **"não se aplica"**, não informação insuficiente
- `BANANA PRATA` ≠ `BANANA NANICA`

##### Padaria
- Atributos relevantes: tipo, sabor
- `PÃO FRANCÊS` = `PÃO FRANCÊS` (se mesmo tipo)

##### Limpeza (limpeza e cuidado doméstico)
- Atributos relevantes: marca, tipo de produto (`product_type`), variante (`variant`)
- Repelente de ambiente, inclusive de tomada, e odorizador de ambiente são **Limpeza**
- `DET LIMPOL 500ML COCO` ≠ `DET LIMPOL 500ML CRISTAL` (variante)
- `DET LIMPOL 500ML` = `DETERGENTE LIMPOL 500ML` (mesmo tipo e marca)
- Amaciante de marcas diferentes não se agrupa (marca)

##### Higiene (higiene pessoal e cuidados corporais)
- Atributos relevantes: marca, tipo de produto (`product_type`), variante (`variant`)
- Repelente corporal é **Higiene**
- `SAB NIVEA CACAU` ≠ `SAB NIVEA KARITÉ` (variante)
- `PAPEL HIG.MILI NEUTRO F.D.30m 12un` = `PAPEL HIGIÊNICO MILI NEUTRO FOLHA DUPLA 30M` (multipack é apresentação)
- Tipo ausente na fonte → PENDENTE

**Fonte canônica com os casos de teste completos:**
`docs/superpowers/specs/2026-10-01-product-equivalence-by-category.md` — tabelas MATCH / NÃO-MATCH /
PENDENTE por categoria, critérios de aceite 1–14, e a semântica de três estados por atributo
(conhecido / desconhecido / não se aplica).

#### 6.2.3 Algoritmo de Matching

> ↩ **citação legada: PRD §3.3** (as camadas 1–5 preservam a numeração original)

##### Camada 1 — Normalização textual
- Lowercase, remover acentos, normalizar espaços
- Expandir abreviações via `synonyms` (com escopo)
- Separar palavras concatenadas quando reconhecido com segurança

##### Camada 2 — Extração de atributos
- Extrair quantidade + unidade (`1 kg`, `500 ml`, `12 un`)
- Extrair tipo de embalagem (`cx`, `pc`, `pct`, `sc`, `lt`)
- Extrair marca (lista de marcas conhecidas ou padrão)
- Extrair características da categoria (regras por categoria)

##### Camada 3 — Busca de candidatos
- Buscar por `match_key` exato
- Se não encontrar, buscar por similaridade (`pg_trgm`)
- Filtrar por categoria

##### Camada 4 — Verificação de atributos
- Para cada candidato, verificar atributos relevantes da categoria
- Se todos coincidirem → match
- Se algum divergir → não match
- Se falta informação → pendente

##### Camada 5 — Decisão
- Match único com todos os atributos coincidindo → **automático**
- Múltiplos candidatos com atributos coincidindo → **pendente** (ambiguidade)
- Nenhum candidato → **pendente** (não encontrado)
- Candidato com atributo divergente → **não match**

#### 6.2.4 Fluxo de Tratamento de Ambiguidade

> ↩ **citação legada: PRD §3.4**

1. Sistema identifica ambiguidade (múltiplos candidatos ou informação insuficiente)
2. Apresenta candidatos ao usuário com diferenças destacadas
3. Usuário escolhe o candidato correto ou confirma que não é nenhum
4. Decisão é registrada. A promoção dessa decisão a associação reutilizável **não é comportamento
   vigente** — ver o aviso abaixo.
5. Se usuário não resolver, item fica pendente de revisão
6. Pendência não bloqueia outras linhas da mesma nota

> ⚠ **C-1 — divergência corrigida na v2.1.** A v1.0 (e a v2.0, que a preservou verbatim) afirmava no
> passo 4: *"pode virar associação reutilizável (com escopo)"*, como se fosse fluxo vigente. A
> ADR-0002 §"Pontos pendentes" e a ADR-0004 §"O que este documento não decide" dizem que essa
> promoção **não está autorizada**. Enquanto §13.9 não for decidida, a tela grava **apenas no nível
> da linha**.
>
> O mesmo erro existe fora deste documento: `<internal plan>` (Sprint 3, entregável 4) traz
> "Associações confirmadas viram apresentações reutilizáveis" como entregável. **Corrigir lá também.**

#### 6.2.5 Reutilização de Associações

> ↩ **citação legada: PRD §3.5**

- Associações confirmadas podem ser reutilizadas automaticamente dentro do escopo em que são válidas
- Requisitos: atributos relevantes continuam compatíveis e não há candidatos conflitantes
- Semelhança textual isolada serve para sugerir candidatos, não para confirmar equivalência
- Escopo pode ser: global, por loja, por emissor

> ⚠ **Bloqueio:** transformar uma revisão em associação reutilizável é **escrever no catálogo
> global**, e isso não está autorizado por nenhuma decisão vigente (ADR-0002 §"Pontos pendentes";
> ADR-0004 §"O que este documento não decide"). Ver §13.9.

#### F06 — Matcher mínimo (camadas 1–4)

- **Descrição:** Implementar normalização, extração de atributos, busca de candidatos e verificação
  por categoria.
- **Regras de Negócio:** as camadas de §6.2.3. Semelhança textual sugere, não confirma.
- **Critérios de Aceite:** os 10 itens do **Anexo B**.
- **Fonte:** §6.2.3, spec de equivalência

#### F07 — Atributos estruturados por categoria

- **Descrição:** Representar os atributos de §4.3 de forma consultável, com os três estados
  (conhecido / desconhecido / não se aplica).
- **Regras de Negócio:**
  - **Desconhecido é ausência de linha, não linha vazia** — a linha existe só quando há valor
  - `brand` fica em `products.brand` (global), **fora** do EAV de atributos
  - `is_required` foi **removido** por ruling: aplicabilidade vem de o atributo existir na lista da
    categoria
  - `category_attributes` é **obrigatório** para interpretar a ausência: sem a lista da categoria,
    *desconhecido* e *não se aplica* são indistinguíveis
- **Critérios de Aceite:**
  - [ ] `products.brand` existe e não é duplicado em `product_attributes`
  - [ ] Ausência de valor não cria linha vazia
  - [ ] Atributo declarado na categoria e ausente em um lado da comparação produz PENDENTE
  - [ ] Ausência bilateral de atributo declarado **não** derruba MATCH
- **Fonte:** spec de equivalência §"Semântica de três estados", critérios #12–#14; internal task-A
- **Estado:** modelagem aberta, não migrada

### 6.3 Revisão de Pendências

> ↩ Esta subseção contém os âncoras `PRD §6.1`, `§6.2` e `§6.3` citados pela spec de UX da tela de
> revisão. Conteúdo preservado.

#### 6.3.1 Tela de Revisão

> ↩ **citação legada: PRD §6.1**

- Lista de itens pendentes com candidatos sugeridos
- Destaque de diferenças entre candidatos
- Ação: selecionar candidato, confirmar que não é nenhum, ou pular
- Explicação do motivo da pendência

**Especificação completa:** `docs/superpowers/specs/2026-10-01-review-screen-ux.md` (rodada 3) —
entrada por `v_review_queue` (por nota, ordenada por `|divergence_cents| DESC`), dois níveis de tela,
decisão gravada por linha.

#### 6.3.2 Tela de Confirmação

> ↩ **citação legada: PRD §6.2**

- Resumo da nota com valores originais
- Itens resolvidos vs pendentes
- Confirmação final da nota

#### 6.3.3 Feedback

> ↩ **citação legada: PRD §6.3**

- Mensagem clara quando não há match
- Indicação de cobertura incompleta nos relatórios

#### F08 — Fila de revisão

- **Descrição:** Apresentar as pendências por nota, priorizando divergência de total sobre nome
  faltando.
- **Regras de Negócio:** `v_review_queue` filtra `status IN ('PENDING','IN_REVIEW')` e usa `LEFT JOIN`
  de propósito — nota sem linhas precisa aparecer. `user_id` é coluna exposta, mas o **filtro é
  responsabilidade de quem consulta**.
- **Critérios de Aceite:**
  - [ ] Nota com `divergence_cents ≠ 0` aparece antes de nota com nome faltando
  - [ ] Nota sem nenhuma linha aparece na fila
  - [ ] A consulta nova de linhas por nota filtra por `user_id`
- **Fonte:** spec de UX §1–§2, ADR-0004 §1

#### F09 — Decisão por linha

- **Descrição:** Registrar a decisão do usuário sobre uma linha pendente.
- **Regras de Negócio:**
  - Confirmar → `product_id`, `presentation_id`, `match_source='MANUAL'`, `reviewed=TRUE`
  - Não é nenhum → `reviewed=TRUE`, sem vínculo, motivo em `match_note`
  - Pular → **nada gravado**; a linha volta à fila (adiamento, não decisão)
  - Resolver uma linha **nunca** bloqueia as demais da mesma nota
  - `match_source` **deve ser coluna**, não rótulo de exibição
  - A FK composta `(presentation_id, product_id)` impede par incoerente
- **Critérios de Aceite:**
  - [ ] Confirmar grava vínculo e a linha sai da fila
  - [ ] "Não é nenhum" grava `reviewed=TRUE` sem vínculo, com motivo legível
  - [ ] Pular não grava nada e a linha reaparece na reabertura
  - [ ] Uma linha pendente não impede resolver as outras
- **Fonte:** spec de UX §5

#### F10 — Registro de "não é nenhum" e "pulada"

- **Descrição:** Dar representação própria aos dois estados que hoje não têm.
- **Regras de Negócio:** `product_id IS NULL, match_source='NONE'` é hoje **tanto** "nunca revisada"
  quanto "revisado sem correspondência". `discarded` **não serve** — o trigger
  `compute_receipt_divergence()` a exclui da soma e usá-la mudaria o total da nota.
- **Critérios de Aceite:**
  - [ ] "Nunca revisada" e "revisada sem correspondência" são distinguíveis ao reabrir a nota
  - [ ] "Adiada" (pulada) é distinguível de "nunca vista"
  - [ ] Nenhum dos dois estados altera `total_computed`
- **Fonte:** spec de UX §6 — **encaminhado a internal task-A** (modelagem, não interface)
- **Estado:** bloqueio aberto, 3 saídas propostas, nenhuma escolhida. Ver §13.7

### 6.4 Consolidação

#### F11 — Consolidação parcial

- **Descrição:** Itens resolvidos entram; pendentes ficam para depois. A nota não fica bloqueada por
  uma linha ambígua.
- **Regras de Negócio:**
  - Uma linha elegível precisa de identidade, apresentação, unidade e conversão suficientes
  - Dúvidas locais não bloqueiam linhas independentes já resolvidas
  - O total pago é registrado **uma única vez**, no cabeçalho
  - Comparações usam apenas as linhas elegíveis e **indicam cobertura incompleta**
  - Não se compara o total fiscal com a soma do subconjunto consolidado
- **Critérios de Aceite:**
  - [ ] Nota com 56 linhas e 14 pendentes consolida as 42 resolvidas
  - [ ] As 14 pendentes permanecem em `staging_lines`
  - [ ] O total pago não é contado duas vezes ao resolver as pendentes depois
  - [ ] Relatório parcial indica cobertura incompleta
- **Fonte:** ADR-0002 §"Consolidação parcial recomendada", ADR-0006 §4 e §6

#### F12 — Consolidação em transação por lote

- **Descrição:** Uma falha reverte o lote, sem afetar lotes anteriores.
- **Regras de Negócio:** parcialidade intencional **não** pode ser confundida com gravação incompleta
  por erro — a diferença precisa ser visível.
- **Critérios de Aceite:**
  - [ ] Falha no lote reverte integralmente e não afeta lote anterior
  - [ ] Reprocessar uma confirmação não duplica nota nem linha
- **Fonte:** ADR-0006 §4

#### F13 — Unidade-base e base price

- **Descrição:** Todo preço é re-expresso na unidade-base antes de qualquer comparação.
- **Regras de Negócio:**
  - `base_unit` é enum com **exatamente três valores**: `UN`, `G`, `ML`
  - `KG` e `L` **não existem** no enum — evita o erro de mil vezes sem erro de tipo
  - `base_price = round(unit_price / factor_base, 8)`, derivado, **nunca digitado**
  - O trigger **recusa a linha** quando `presentation_id` está ausente ou a apresentação não pertence
    ao produto declarado
  - `1.000 g = 1 kg` e `1.000 mL = 1 L` são válidos. **`1 kg = 1 L` não é** — massa e volume são
    grandezas diferentes
  - Venda por peso: `factor_base` é a referência (1 kg = 1000 g), o peso comprado vai em `quantity`
- **Critérios de Aceite:**
  - [ ] `ck_base_unit` não aceita `KG` nem `L`
  - [ ] Linha sem apresentação é recusada pelo trigger, não gravada com preço nulo
  - [ ] Surimi 250 g e contrafilé 1 kg comparam por `R$/g`, não por preço de embalagem
  - [ ] Item em massa e item em volume **não** entram na mesma comparação
- **Fonte:** ADR-0003 §1–§4

#### F14 — Agregação de preços

- **Descrição:** Transformar vários preços do mesmo item em um preço de referência.
- **Regras de Negócio:** média **ponderada pela quantidade**, nunca `min()`.
  → `v_price_aggregation = sum(base_price * quantity) / sum(quantity)`
  - Agrupamento: `GROUP BY (user_id, product_id, store_id, purchase_date, base_unit)`
  - `price_refs` é populado por **job**, não por trigger
- **Critérios de Aceite:**
  - [ ] Duas compras no mesmo dia (R$ 39,90 e R$ 44,90) produzem a média ponderada, não o mínimo
  - [ ] Compras de usuários diferentes **não** colapsam na mesma chave
  - [ ] `base_unit` faz parte da chave
- **Fonte:** ADR-0003 §5
- ⚠ **Lacuna:** `min_30d`/`max_30d` **não têm mínimo de amostras**. Alertar sobre uma única compra é
  ficção. Ver §13.12.

### 6.5 Comparação de Preços (Painel)

#### F15 — Comparação entre lojas

- **Descrição:** Para um produto canônico, mostrar o preço em cada loja por unidade-base.
- **Regras de Negócio:**
  - Preços **sempre** por unidade-base (g, ml, un). Nunca por embalagem
  - Lojas sem o produto não aparecem
  - Apresentações diferentes (500 g vs 1 kg) são normalizadas para unidade-base
  - O painel **não faz matching** — ele exibe o resultado. Produto não identificado não aparece
- **Critérios de Aceite:**
  - [ ] Produto com preço em 3 lojas mostra os 3 lado a lado por unidade-base
  - [ ] Produto com 1 loja mostra apenas essa loja
  - [ ] Produto sem preço mostra "Nenhum preço encontrado"
  - [ ] Nenhum preço é exibido sem unidade
  - [ ] Produto pendente de matching não aparece no painel
- **Fonte:** spec `2026-10-04-price-comparison-dashboard-prd.md`

#### F16 — Melhor preço

- **Descrição:** Destacar a loja com menor `base_price`.
- **Regras de Negócio:** empate destaca ambas as lojas.
- **Critérios de Aceite:**
  - [ ] Loja mais barata recebe `store-row-best` + `badge-best-price`
  - [ ] Empate destaca as duas
- **Fonte:** spec do painel §4.3, DESIGN.md

#### F17 — Filtros essenciais

- **Descrição:** Produto (busca textual), loja e categoria.
- **Regras de Negócio:** filtros adicionais (marca, período, faixa) são refinamento, não necessidade.
- **Critérios de Aceite:**
  - [ ] Busca por nome canônico filtra a comparação
  - [ ] Filtro de loja mostra apenas lojas selecionadas
  - [ ] Filtro de categoria mostra apenas produtos da categoria
- **Fonte:** spec do painel §4.4

### 6.6 Privacidade e LGPD

#### F18 — Exclusão de dados do titular

- **Descrição:** Apagar os dados de uma pessoa a pedido, preservando a prova de que a eliminação
  aconteceu.
- **Regras de Negócio:**
  - Ordem deliberada: `INSERT INTO data_erasure_requests` **antes** do `DELETE FROM users`
  - A cascata remove notas, linhas, staging, price_refs e alertas
  - **Sobrevivem:** catálogo (`products`, `stores`, `presentations`, `categories`),
    `data_erasure_requests`, `audit_log`
  - `audit_log` e `data_erasure_requests` **não têm FK para `users`** — com FK, o `DELETE` aborta
- **Critérios de Aceite:**
  - [ ] Exclusão remove os dados de negócio do titular
  - [ ] O rastro de auditoria é preservado
  - [ ] O catálogo compartilhado **não** é apagado
  - [ ] `DELETE FROM users` executa sem violar FK
- **Fonte:** ADR-0005 §3–§4

#### F19 — Guard de dados sensíveis

- **Descrição:** Bloquear chave de acesso e CPF no repositório, no pre-commit e na CI.
- **Regras de Negócio:**
  - Bloqueia chave de acesso nas **duas formas** (44 dígitos e formato com hífens)
  - Bloqueia CPF (11 dígitos, com e sem formatação)
  - **Não** bloqueia CNPJ de pessoa jurídica — dado público; a ressalva é CNPJ de MEI cujo titular é a
    própria pessoa
  - Sequências de zeros (fixture anônimo) passam
- **Critérios de Aceite:**
  - [ ] `python3 scripts/guard_dados_sensiveis.py` passa no repo limpo
  - [ ] Chave formatada com hífens é detectada
  - [ ] CNPJ de rede real passa
- **Fonte:** ADR-0005 §5, `README.md` §"Personal data"
- **Estado:** implementado, 14 casos verificados

#### F20 — Expurgo de imagem de cupom

- **Descrição:** Apagar o arquivo de cupom no disco quando o titular pede exclusão.
- **Regras de Negócio:** hoje o banco **não sabe** que o arquivo existe — o cascade não o apaga.
  Enquanto não houver expurgo, uma exclusão LGPD **deixa resíduo**.
- **Critérios de Aceite:**
  - [ ] `DELETE FROM users` remove o arquivo referenciado em `staging_receipts.file_path`
  - [ ] O registro em `data_erasure_requests` reflete o arquivo removido
  - [ ] Arquivo ausente e registro órfão são tratados explicitamente
- **Fonte:** ADR-0005 §2 e pendência 1
- **Estado:** **não implementado** — pendência de prioridade máxima da ADR-0005

---

## 7. Fluxos de Usuário

### 7.1 Ingestão → Revisão → Consolidação

```
flowchart TD
    A[Usuario envia NFC-e] --> B{Upload aceito?}
    B -->|Nao| B1[Erro visivel ao usuario]
    B -->|Sim| C[202 Accepted + job_id]
    C --> D[Worker: parse da nota]
    D --> E[staging_receipts PENDING]
    E --> F[staging_lines populadas]
    F --> G[Checksum: soma vs total]
    G --> H{Fecha com tolerancia?}
    H -->|Nao| I[IN_REVIEW - divergencia visivel]
    H -->|Sim| J[Matcher camadas 1-4]
    I --> J
    J --> K{Decisao por linha}
    K -->|Match unico| L[Vinculo automatico sugerido]
    K -->|Ambiguo| M[PENDENTE - fila de revisao]
    K -->|Divergente| N[NAO-MATCH]
    M --> O[Usuario revisa]
    O --> P{Decisao}
    P -->|Confirma| Q[Grava vinculo na linha]
    P -->|Nao e nenhum| R[reviewed TRUE sem vinculo]
    P -->|Pula| M
    Q --> S[Consolidacao parcial]
    R --> S
    S --> T[purchase_notes + line_items]
    T --> U[Trigger calcula base_price]
    U --> V[Job de agregacao]
    V --> W[price_refs]
    W --> X[Painel de comparacao]
```

### 7.2 Consulta de Preços

```
flowchart TD
    A[Usuario abre o painel] --> B[Busca produto por nome]
    B --> C{Produto identificado?}
    C -->|Nao| D[Vazio: nenhum preco encontrado]
    C -->|Sim| E[Carrega price_refs por loja]
    E --> F[Normaliza para unidade-base]
    F --> G[Ordena por preco]
    G --> H[Destaca melhor preco]
    H --> I{Usuario filtra?}
    I -->|Loja| J[Restringe lojas visiveis]
    I -->|Categoria| K[Restringe produtos]
    J --> G
    K --> B
    I -->|Nao| L[Usuario decide onde comprar]
```

### 7.3 Exclusão LGPD

```
flowchart TD
    A[Titular pede exclusao] --> B[INSERT data_erasure_requests]
    B --> C[DELETE FROM users]
    C --> D[Cascata: notas, linhas, staging, price_refs, alerts]
    D --> E{Catalogo preservado?}
    E -->|Sim| F[products, stores, presentations intactos]
    E -->|Nao| G[ERRO - catalogo compartilhado destruido]
    D --> H[audit_log preservado]
    F --> I{Expurgo da imagem?}
    I -->|Hoje: nao existe| J[RESIDUO EM DISCO - lacuna aberta]
    I -->|Implementado| K[Arquivo removido e registrado]
```

---

## 8. Sistema de Agentes de IA

**Não se aplica.** O home_shopper **não usa IA generativa, RAG, embeddings, vector store nem LLM**.

A classificação de produtos é feita por **regras determinísticas por categoria** (§6.2.2), com
decisão explícita de três valores (MATCH / NÃO-MATCH / PENDENTE). Não há inferência de modelo, custo
de token, janela de contexto ou índice vetorial a gerenciar.

**Decisão registrada:** introduzir classificação assistida por IA seria **decisão nova** com
trade-off próprio (§13), não uma evolução implícita. O produto ganha credibilidade justamente porque
ele **não** adivinha: ele diz "não consegui identificar" e entrega a decisão ao humano.

> ↩ Nota de compatibilidade: no PRD v1.0, `§8` era a lista de critérios de aceite. Ela está
> preservada numericamente no **Anexo B**.

---

## 9. Sistema de Planos e Billing

**Não se aplica.** O home_shopper não é SaaS pago. Não há plano, assinatura, crédito, limite de uso
ou integração de pagamento no escopo.

O usuário do produto é o próprio autor (persona 2.1). A existência da persona secundária (§2.2) vem
do **catálogo compartilhado** (ADR-0004), não de um modelo de cobrança.

**Decisão registrada:** se o produto virar SaaS, isso entra como decisão nova — e provavelmente
exigiria revisitar a autorização de escrita no catálogo global (§13.9).

> ↩ Nota de compatibilidade: no PRD v1.0, `§9` era "Decisões registradas" com `§9.1`–`§9.5`. As
> decisões de **produto** estão preservadas numericamente no **Anexo C**; as decisões **técnicas**
> estão em §13.

---

## 10. Design e UI/UX

### 10.1 Camada Visual — spec e deliverable

A camada visual são **duas coisas relacionadas**, não uma:

| Artefato | Papel | Estado |
|---|---|---|
| **`DESIGN.md`** (779 linhas) | **Spec de tokens** — a fonte. Adaptação do sistema Meta para o contexto de supermercado, validável com `npx @google/design.md lint DESIGN.md` | existente |
| **`design_system/`** | **Deliverable derivado** da spec | criado em **2026-10-05** |
| ├─ `tokens.css` (4.937 B) | Tokens. Cabeçalho declara: *"Fonte: DESIGN.md"* | — |
| ├─ `design-system.css` (22.980 B) | Camada de componentes e estados | — |
| ├─ `design-system.html` (32.042 B) | Guia visual: 7 seções, **zero `style=""` inline** | — |
| └─ `EXTRACTION.md` (4.776 B) | **Evidência**: o que foi medido em `meta.com` ao vivo, e o que **não** foi obtido | — |

Wireframes de baixa fidelidade em **`WIREFRAMES.md`** (283 linhas, 4 telas).

> ⚠ **Correção de fato (v2.2).** A v2.1 afirmava que `design_system/design-system.html` **não existia**
> e que todo prompt que o citasse falharia em silêncio. Era verdade quando verifiquei (01:30–01:45) e
> **deixou de ser às 01:56 de 2026-10-05**, quando a camada foi extraída. O caminho existe, está
> populado e é o deliverable oficial. As três correlações que eu havia propagado a partir dessa
> verificação — no PRD, no parecer da coordenação e na minha memória — estão todas desatualizadas.
>
> A regra de processo que manda verificar `@design_system/design-system.html` quando a feature toca UI
> **volta a valer**.

### 10.2 Tokens-Chave (`DESIGN.md`)

| Grupo | Tokens |
|---|---|
| **Cor — marca** | `primary` `#0064e0` (só melhor preço), `primary-deep` `#0457cb`, `fb-blue` `#1876f2` (foco) |
| **Cor — preço** | `price-drop` `#31a24c`, `price-rise` `#e41e3f`, `price-stable` `#5d6c7b`, `best-price` `#0064e0` |
| **Cor — loja** | `store-a` azul, `store-b` âmbar, `store-c` verde, `store-d` roxo (legenda de gráfico, nunca preenchimento) |
| **Cor — superfície** | `canvas` `#ffffff`, `surface-soft` `#f1f4f7`, `hairline` `#ced0d4`, `hairline-soft` `#dee3e9` |
| **Tipografia** | `Optimistic VF`; `price-display` 32px/700, `subtitle-lg` 18px/700, `body-md` 16px/400, `price-unit` 14px/400 |
| **Espaçamento** | base 4px, passo dominante 8px; `spacing.xxl` 32px (card), `spacing.section` 64px (seção) |
| **Raio** | `rounded.full` botões/badges/pills; `rounded.xxxl` 32px cards de produto; `rounded.xl` 16px cards de stat |
| **Grid** | max-width 1280px, gutters 32px; dashboard 12 colunas, gap 24px; cards 4-up desktop |

### 10.3 Componentes-Chave (`DESIGN.md`)

`nav-top` · `search-pill` · `filter-chip` / `filter-chip-active` · `card-price-comparison` ·
`card-product` · `card-stat` · `card-chart` · `card-promo-strip` · `store-row` / `store-row-best` ·
`badge-best-price` · `badge-price-drop` / `badge-price-rise` / `badge-price-stable` ·
`price-tag` / `price-tag-unit` · `button-primary` · `button-buy-cta` · `button-pill-tab` ·
`table-header` / `table-row` / `table-row-alt` · `chart-line` / `chart-grid` · `tooltip` ·
`empty-state` · `skeleton`

### 10.4 Regras de Interface (não negociáveis)

- **Preço é o maior elemento da tela.** `price-display` 32px/700.
- **Nunca exibir preço sem unidade** — sempre `/kg`, `/un`, `/L`.
- **`primary` (cobalto) é escasso:** só onde uma loja está destacada como mais barata.
- **Cor é semântica, nunca decoração:** verde só para queda, vermelho só para alta.
- **Variação sempre com seta** (↓ queda, ↑ alta) e rótulo textual — nunca só cor.
- **Pill em todo botão, badge e chip.** Canto reto sinaliza "widget de terceiro".
- **Nome de loja nunca é truncado** — é o eixo da comparação.
- **Sem sombra em card de dashboard.** Elevação é reservada a elementos sticky e tooltips.
- **Não esconder o badge de variação** — "estável" é informação útil.

### 10.5 Telas (wireframes em `WIREFRAMES.md`)

1. **Dashboard (Homepage)** — stat cards, variação de preços 30 dias, alertas, comparações recentes
2. **Product Comparison Page** — card de comparação + histórico de preços + produtos similares
3. **Store Detail Page** — produtos da loja com posição vs média
4. **Review Queue (Staging)** — fila de revisão por nota com pendências e divergência

**Wireframe conceitual — comparação de preços:**

```
┌─────────────────────────────────────────────────────────────┐
│  [LOGO]  home_shopper    [🔍 Buscar produto...]  [👤] [⚙️]  │
├─────────────────────────────────────────────────────────────┤
│  [Todos] [Laticínios] [Carnes] [Mercearia] [Bebidas] ...   │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────┐  Leite Integral 1L                           │
│  │  [IMG]   │  Categoria: Laticínios                        │
│  └──────────┘  Unidade base: L                              │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ ★ Supermarket A                    MELHOR     │   │
│  │    R$ 4,49/L                            ↓ 10%       │   │
│  │    Atualizado: 15/06/2026            [Comprar →]    │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Mercado Sul                                                │   │
│  │    R$ 4,99/L                            estável     │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Supermarket G                                             │   │
│  │    R$ 5,29/L                            ↑ 5%        │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 10.6 Lacunas Conhecidas da Camada Visual

- **`Optimistic VF` não é distribuída.** É fonte proprietária da Meta: nenhum webfont foi baixado nem
  embutido. O layout é nativo onde a licença estiver instalada e **degrada** para
  Montserrat/Helvetica/Arial onde não estiver. `EXTRACTION.md` registra isto como *"diferença real de
  renderização, não uma equivalência"* — vale para qualquer verificação visual futura.
- **Dark mode não definido** — sistema é light-only
- **Timings de animação não especificados** — recomendado 150–250 ms ease-out
- **Tokens de biblioteca de gráfico não formalizados**
- **Navegação mobile não decidida** — recomendado bottom nav para dashboard, drawer para filtros
- **Contraste WCAG: deixou de ser "não verificável".** A spec de UX §7 condicionava a medição à
  existência de tokens; `tokens.css` e `design-system.css` agora existem, então os pares de contraste
  passam a ser **mensuráveis**. Continua **não afirmada** conformidade AA — medir é trabalho novo, e
  o parecer de UX foi escrito quando os tokens ainda não existiam.

---

## 11. API Endpoints

**Nenhum endpoint existe.** A tabela abaixo é `PROPOSTA` — o contrato definitivo é decisão do
engenharia (§13.1). Fonte: `<internal plan>` (upload), spec do painel §6.1 (leitura) e a necessidade da
tela de revisão (spec de UX §2).

### 11.1 Ingestão

| Método | URL | Descrição |
|---|---|---|
| POST | `/receipts/upload` | Recebe NFC-e (XML/imagem/QR), devolve `202 Accepted` + `job_id` |
| GET | `/receipts/{job_id}` | Estado do processamento: `PENDING` / `IN_REVIEW` / `DONE` / erro |

### 11.2 Catálogo

| Método | URL | Descrição |
|---|---|---|
| GET | `/products` | Lista produtos canônicos (busca textual) |
| GET | `/stores` | Lista lojas |
| GET | `/categories` | Lista categorias |

### 11.3 Comparação

| Método | URL | Descrição |
|---|---|---|
| GET | `/products/{id}/prices` | Preços do produto por loja, em unidade-base |

### 11.4 Revisão

| Método | URL | Descrição |
|---|---|---|
| GET | `/review/queue` | Notas com pendências — **filtra por `user_id`** |
| GET | `/review/receipts/{id}/lines` | Linhas de uma nota — **consulta nova, não existe em view** |
| PATCH | `/review/lines/{id}` | Grava decisão da linha (`match_source='MANUAL'`, `reviewed`) |

**Contrato de erro (proposto):** `404` para produto/nota inexistente; `400` para parâmetros
inválidos.

> ⚠ **Toda rota de §11.4 depende do filtro por `user_id`.** A ADR-0004 nomeia isto como o risco real
> do projeto: *"Uma view nova sem essa coluna reintroduz o vazamento."*

---

## 12. Roadmap de Sprints

**Fonte canônica: `<internal plan>`** (scrum master) — 5 sprints. Decisão do Jonas em 2026-10-01: a
numeração do `<internal plan>` prevalece; o roadmap de 4 sprints do PRD v1.0 (`§7`) fica como registro
histórico.

### Sprint 1 — Fundação de Ingestão

**Objetivo:** uma nota fiscal pode ser enviada, parseada e armazenada, com todos os itens extraíveis.

- [ ] API com endpoint `POST /receipts/upload`
- [ ] Parser de NFC-e (XML) — cabeçalho + itens
- [ ] Worker assíncrono processando fora do ciclo da requisição
- [ ] Banco populado com as notas em `staging_receipts` + `staging_lines`
- [ ] Checksum fecha (`divergence_cents = 0`) para notas sem desconto
- [ ] Nota com desconto não reporta divergência falsa
- [ ] Reprocessamento da mesma nota não duplica
- [ ] `/receipts/upload` retorna `202 Accepted` com `job_id`

**Entrega:** nota real enviada, parseada e disponível em staging, com idempotência verificada.

> ✅ **Alinhado na v2.1 (A-4):** o alvo é o banco canônico — **15 notas / 573 linhas / 7 cadastros de
> loja**. O `<internal plan>` já foi reconciliado no working tree (uncommitted). Atenção: os 15/573/7
> descrevem hoje a base **`home_shopper`**; o canônico é `home_shopper-db`, que está vazio e **não tem
> loader** para repovoar (ver §1.4.4).

### Sprint 2 — Matching de Produtos

**Objetivo:** reconhecer quando duas descrições são o mesmo produto canônico, e distinguir quando não
são.

- [ ] Normalização textual (lowercase, acentos, espaços)
- [ ] Extração de quantidade + unidade
- [ ] Extração de marca e tipo de embalagem
- [ ] Busca de candidatos por `match_key` exato
- [ ] Busca por similaridade (`pg_trgm`)
- [ ] Verificação de atributos por categoria (as 6 de §6.2.2)
- [ ] Decisão: automático (match único) vs pendente (ambiguidade / não encontrado)
- [ ] Casos de teste da spec de equivalência versionados em `tests/`

**Critérios de aceite:** os 10 itens do **Anexo B** (numeração preservada do PRD v1.0 `§8`).

**Entrega:** algoritmo classifica descrições em MATCH / NÃO-MATCH / PENDENTE conforme os critérios por
categoria.

### Sprint 3 — Revisão e Consolidação

**Objetivo:** o usuário revisa pendências, confirma associações e consolida parcialmente.

- [ ] Fila de revisão por nota (`v_review_queue`)
- [ ] Consulta nova de linhas por nota, **com filtro por `user_id`**
- [ ] Tela de linha: descrição de origem, motivo da pendência, candidatos com diferenças destacadas
- [ ] Ação confirmar (grava `match_source='MANUAL'` + `reviewed`)
- [ ] Ação "não é nenhum" (com representação própria — ver F10)
- [ ] Ação pular (adiamento, sem gravação)
- [ ] Consolidação parcial em transação por lote
- [ ] Progresso: resolvidos / consolidados / pendentes
- [ ] Nota com pendências **não** é chamada de concluída

**Entrega:** usuário resolve pendências e consolida as linhas elegíveis; pendentes ficam em staging.

> ⚠ **Bloqueio:** a promoção a associação reutilizável **não** está autorizada (§13.9). A tela grava
> apenas no nível da linha.

### Sprint 4 — Comparação de Preços (Painel)

**Objetivo:** mostrar preços comparados entre lojas por unidade-base.

- [ ] Job de agregação que alimenta `price_refs` a partir de `line_items`
- [ ] Índice em `price_refs (product_id, store_id, ref_date)`
- [ ] `GET /products`, `/stores`, `/categories`
- [ ] `GET /products/{id}/prices`
- [ ] Tela de comparação com os 3 filtros essenciais
- [ ] Destaque de melhor preço
- [ ] Estados: vazio, carregando (skeleton), erro
- [ ] Indicação de cobertura incompleta quando há pendências

**Entrega:** painel mostra o preço do mesmo produto por loja e onde é mais barato.

### Sprint 5 — Refinamento e Produção

**Objetivo:** preparar para uso real — performance, testes de integração, ADRs pendentes, LGPD.

- [ ] Cache de associações confirmadas
- [ ] Índices otimizados e revisão de plano de query
- [ ] Testes de integração do fluxo completo (upload → matching → revisão → consolidação → painel)
- [ ] Revisar e aceitar ADRs 0002, 0003, 0004, 0005, 0006 (ou adiar explicitamente)
- [ ] **Expurgo de imagem de cupom implementado** (F20)
- [ ] Expurgo de payload de `audit_log`
- [ ] Prazo de retenção do e-mail em `data_erasure_requests`
- [ ] README atualizado com instruções de deploy
- [ ] `docker-compose.yml` criado — o README referencia um arquivo que **não existe**

**Entrega:** sistema estável, com LGPD exequível e ADRs fechados.

---

## 13. Decisões Técnicas e Trade-offs

### 13.1 Stack da aplicação

| Aspecto | Decisão |
|---|---|
| **Escolha** | **FastAPI** (Python) como framework da API |
| **Justificativa** | Assíncrono por natureza, adequado a upload + delegação a worker; tipagem com Pydantic para o contrato de entrada |
| **Trade-off** | Não traz ORM/batteries incluídas como o Django. Mais decisões manuais (sessão, migração, admin). O projeto já escreveu SQL à mão, então a ausência de ORM-autoridade não é perda |
| **Status** | ⚠ `PROPOSTA` — aparece em `README.md` e `<internal plan>`, mas **não foi ratificada em ADR nem no PRD v1.0**. Pendente do aval da engenharia |

### 13.2 Processamento assíncrono e fila

| Aspecto | Decisão |
|---|---|
| **Escolha** | **Celery + Redis** como broker, com Celery Beat para o job de agregação |
| **Justificativa** | Uma nota tem 43–59 linhas e extração imperfeita — não termina dentro de um timeout razoável. O trabalho é perdido se a conexão cair (ADR-0006) |
| **Trade-off** | Mais um serviço para operar. Redis-as-broker tem dead-letter menos robusto que RabbitMQ. Compensa no volume atual, e a ADR-0006 **deixou a tecnologia explicitamente em aberto** — trocar de broker não muda o schema |
| **Status** | ⚠ `PROPOSTA` — `<internal plan>`. A ADR-0006 §"O que este documento não decide" lista a tecnologia como pendente |

### 13.3 Banco de dados

| Aspecto | Decisão |
|---|---|
| **Escolha** | **PostgreSQL 16** — schema aplicado, testado, com CI |
| **Justificativa** | `NUMERIC` exato (float erra por `5,5e-17`, NUMERIC erra por 0); enum nativo; triggers; constraints nomeadas; `pg_trgm` disponível para a camada 3 do matcher |
| **Trade-off** | Mais pesado que SQLite para desenvolvimento local; exige container. Aceito porque o schema **é** o produto nesta fase |

### 13.4 Isolamento de dados de compra

| Aspecto | Decisão |
|---|---|
| **Escolha** | Catálogo **global** (sem `user_id`) + compras **isoladas** por `user_id NOT NULL`. Toda consulta de negócio filtra |
| **Justificativa** | Duplicar `products` por usuário criaria N identidades para o mesmo fato e quebraria a comparação entre lojas — que é o projeto inteiro |
| **Trade-off** | **O isolamento é disciplina de aplicação, não restrição de banco.** Nada impede uma view nova de omitir o filtro. Mitigação proposta: teste que falhe quando uma view nova não recebe `user_id` (ADR-0004, primeiro item a resolver) |
| **Fonte** | ADR-0004 |

### 13.5 Unidade-base e preço derivado

| Aspecto | Decisão |
|---|---|
| **Escolha** | Enum `base_unit` com **exatamente três valores** (`UN`, `G`, `ML`); `base_price` derivado por trigger, nunca digitado; trigger **recusa** linha sem apresentação resolvida |
| **Justificativa** | `KG` e `L` no enum permitiriam `MIN()` entre `0,0299 in G` e `29,9 in KG` — erro de mil vezes **sem erro de tipo**. A restrição é do tipo, não do comentário |
| **Trade-off** | `KG` e `L` continuam existindo em `presentations.sale_unit` como rótulo do emissor, gerando duas representações da mesma grandeza. Aceito: o valor original da fonte precisa ser preservado |
| **Fonte** | ADR-0003 §1–§3 |

### 13.6 Agregação de preços

| Aspecto | Decisão |
|---|---|
| **Escolha** | Média **ponderada pela quantidade**: `sum(base_price * quantity) / sum(quantity)`. Nunca `min()` |
| **Justificativa** | `min()` infla a queda e dispara alerta falso. Um alerta errado é pior que nenhum: o usuário perde confiança e para de ler |
| **Trade-off** | Agregar em job deixa `price_refs` levemente atrasado em relação a uma compra recém-consolidada. Defasagem pequena e conhecida, mas **sem janela definida** |
| **Lacuna** | `min_30d`/`max_30d` **não têm número mínimo de amostras**. Ver §13.12 |
| **Fonte** | ADR-0003 §5 |

### 13.7 Representação de estados de revisão

| Aspecto | Decisão |
|---|---|
| **Escolha** | **Pendente.** Três saídas propostas, nenhuma escolhida |
| **Justificativa** | "Nunca revisada" e "revisada sem correspondência" colapsam hoje em `product_id IS NULL, match_source='NONE'`. "Adiada" não é representável. `discarded` não serve: o trigger a exclui da soma e usá-la mudaria o total da nota |
| **Trade-off** | Um valor novo no enum `match_source` resolve o primeiro caso sem coluna nova, mas não resolve "adiada". Uma coluna dedicada resolve os dois, ao custo de migração |
| **Fonte** | spec de UX §6, internal task-A |

### 13.8 Consolidação parcial

| Aspecto | Decisão |
|---|---|
| **Escolha** | Consolidar os itens aprovados e manter os demais pendentes. Transação por lote |
| **Justificativa** | Uma única linha ambígua de 56 não deve impedir o uso de 42 já resolvidas |
| **Trade-off** | Exige controle de progresso, proteção contra duplicidade e **indicação de cobertura incompleta** nos relatórios — a interface precisa dizer, senão o ganho vira mentira |
| **Fonte** | ADR-0002 §"Consolidação parcial recomendada" |

### 13.9 Escrita no catálogo global

| Aspecto | Decisão |
|---|---|
| **Escolha** | **Não decidida — bloqueio aberto** |
| **Justificativa** | `presentations` é compartilhada. Transformar uma confirmação manual em apresentação reutilizável é escrever no catálogo de todos os usuários, e afeta a comparação alheia |
| **Trade-off** | Sem essa decisão, cada usuário revisa a mesma linha repetidamente (custo recorrente) e o catálogo cresce devagar. Com ela, um erro de um usuário contamina a comparação dos outros |
| **Fonte** | ADR-0002 §"Pontos pendentes"; ADR-0004 §"O que este documento não decide" |

### 13.10 Imagem de cupom no disco, nunca no banco

| Aspecto | Decisão |
|---|---|
| **Escolha** | `staging_receipts.file_path` é `TEXT`. **Zero bytes de imagem no banco** |
| **Justificativa** | (1) Postgres não é armazenamento de objetos. (2) A imagem é o dado mais perigoso do projeto — mostra CPF, endereço, itens. (3) A exclusão fica **auditável**: apagar o arquivo é verificável; provar que bytes dentro de um `BYTEA` foram apagados, não |
| **Trade-off** | O banco não sabe que o arquivo existe. `DELETE FROM users` **não** o apaga — a exclusão LGPD deixa resíduo enquanto não houver expurgo |
| **Fonte** | ADR-0004 §4, ADR-0005 §2 |

### 13.11 Dados pessoais, guard e o que não é bloqueado

| Aspecto | Decisão |
|---|---|
| **Escolha** | Chave de acesso e CPF **bloqueados** (guard no pre-commit e na CI). CNPJ de pessoa jurídica **liberado** |
| **Justificativa** | A chave é porta de entrada: quem a possui consulta a nota na SEFAZ sem autenticar e obtém CPF, endereço e histórico. O CNPJ de empresa é público e recuperável em segundos — sanitizá-lo não protege ninguém e criou falsa sensação de proteção |
| **Trade-off** | CPF visível em **imagem** de cupom não é detectado; o `.gitignore` cobre por nome de arquivo, o que é frágil. Ressalva registrada: CNPJ de MEI cujo titular é a própria pessoa funciona como identificador individual |
| **Fonte** | ADR-0005 §1 e §5 |

### 13.12 Pendências de verificação e lacunas abertas

| # | Lacuna | Impacto | Fonte |
|---|---|---|---|
| 1 | ~~Contagem de notas divergente~~ — **RESOLVIDO na v2.1 (A-4)**, reconciliado para **15 notas / 573 linhas / 7 cadastros de loja**. Ver ressalva de procedência de banco em §1.4.4 | — | §1.4.4 |
| 2 | ~~`docker-compose.yml` não existe~~ — **RESOLVIDO (A-4)**: `docker-compose.yml` foi criado no working tree (uncommitted) | — | README §"Run it" |
| 3 | `min_30d`/`max_30d` **sem mínimo de amostras** | Alerta sobre uma única compra é ficção | ADR-0003 |
| 4 | **Expurgo de imagem de cupom** não implementado | Exclusão LGPD deixa resíduo em disco | ADR-0005 |
| 5 | `audit_log` retém JSONB **sem política de expurgo** | Pode reter dado que a LGPD mandaria apagar | ADR-0005 |
| 6 | Prazo de retenção do e-mail em `data_erasure_requests` | Dado pessoal sobrevivente sem prazo | ADR-0005 |
| 7 | **Mapeamentos de unidade não se propagam entre emissores** | Filial nova do mesmo Supermarket G exige revisão separada | ADR-0003 |
| 8 | Política de arredondamento por categoria (peso líquido, drenado) | Sem ela, conserva com peso diferente fica ambígua | ADR-0003 |
| 9 | Quantidade fracionada de item contável (`0,15 un` de sacola) | Comparação em `UN` fica imprecisa | ADR-0003 |
| 10 | Migração de `presentations.factor_base` quando a embalagem muda sem mudar o produto | Toddy 390 g → 397 g sem novo produto | ADR-0003 |
| 11 | **Escrita no catálogo global** sem autorização | Bloqueia promoção a alias reutilizável | §13.9 |
| 12 | **Representação de "não é nenhum" e "pulada"** | Bloqueia a tela de revisão completa | §13.7 |
| 13 | Peso drenado é **caso nomeado**, não classe | `ERVILHA 1KG` ≠ `ERVILHA 800G` e nada mais. Como representar sem criar classe artificial segue aberto | ADR-0001 |
| 14 | Autorização de escrita e procedimento para item global **errado** | Um erro de um usuário contamina a comparação dos outros | ADR-0004 |
| 15 | Camada de comunicação: queda de preço → mensagem, com deduplicação e janela de silêncio | O diferencial técnico (§1.3) não tem especificação | `DECISIONS.md` |

---

## 14. Glossário

| Termo | Definição |
|---|---|
| **ADR** | Architecture Decision Record — registro de decisão arquitetural com contexto, alternativas e consequências |
| **Apresentação** | Forma comercial em que um produto é vendido: quantidade de conteúdo, unidade, tipo de embalagem e configuração do pacote |
| **base_price** | Preço re-expresso na unidade-base do produto, derivado por trigger. É o único preço comparável entre apresentações |
| **base_unit** | Unidade-base de comparação. Enum com exatamente três valores: `UN`, `G`, `ML` |
| **CF-e-SAT** | Modelo fiscal 59. Adaptador de entrada próprio, distinto da NFC-e (modelo 65). Desenho aprovado, implementação diferida |
| **Chave de acesso** | 44 dígitos que identificam a NFC-e. **Dado pessoal**: permite consultar a nota na SEFAZ sem autenticação |
| **Consolidação** | Passagem do staging (não confiável) para a camada confiável (`purchase_notes` + `line_items`) |
| **EAN** | Identificador do item comercial (código de barras). **Opcional** e auxiliar; nas notas auditadas, zero itens o possuíam |
| **Equivalência confirmada** | Conclusão sustentada por informação suficiente de que duas identificações são o mesmo produto canônico |
| **Gap analysis** | Comparação entre o estado atual e o estado exigido, para localizar o que falta |
| **LGPD** | Lei Geral de Proteção de Dados. Rege minimização, retenção e exclusão de dados pessoais |
| **MATCH / NÃO-MATCH / PENDENTE** | Os três resultados possíveis da comparação de duas descrições. PENDENTE nunca é promovido a MATCH por omissão |
| **match_key** | Chave textual normalizada, gerada por `lower()` + remoção de não-alfanuméricos. Serve à busca, não à equivalência |
| **Matcher** | Conjunto das camadas 1–5 que decide se duas descrições descrevem o mesmo produto |
| **NFC-e** | Nota Fiscal de Consumidor Eletrônica, modelo 65. É a entrada principal do projeto |
| **Peso drenado** | Peso do conteúdo após escorrer o líquido. Caso nomeado no projeto: `ERVILHA 1KG` ≠ `ERVILHA 800G` |
| **price_refs** | Tabela de preços de referência por usuário × produto × loja × dia. Populada por job |
| **Produto canônico** | Identidade do conteúdo comprado e das características relevantes à sua equivalência, segundo a categoria |
| **SDD** | Spec-Driven Development — escrever a especificação antes do código |
| **Staging** | Camada de dados brutos, isolada por usuário, que precede a revisão humana |
| **Três estados do atributo** | **Conhecido** (a fonte informou) · **Desconhecido** (aplica-se, mas não foi informado → PENDENTE se o outro lado informar) · **Não se aplica** (a categoria não o usa → ignorado) |
| **Unidade de venda** | Unidade em que o emissor expressa quantidade e preço unitário, como `UN` ou `KG` |

---

## Anexo A — Mapa de Migração de Citações

O PRD v1.0 usava 11 seções; esta v2.0 usa as 14 do padrão Imersão. Os âncoras `PRD §x.y` são citados
por **6 ADRs e 3 specs** (~62 pontos). Este anexo é a tabela de tradução.

### A.1 Crosswalk

| Âncora legada | Onde está na v2.0 | Natureza |
|---|---|---|
| `PRD §1` | §1.4 Diagnóstico do Estado Atual | movida |
| `PRD §1.1` | §1.4.1 Schema implementado | movida |
| `PRD §1.2` (propostas) | §1.4.2 | movida |
| `PRD §1.3` (gap) | §1.4.3 | movida |
| `PRD §2` (objetivo) | §1.1 Descrição + §1.2 Problema | dissolvida |
| `PRD §3.1` (regras 1–8) | **§6.2.1** | preservada verbatim, numeração das regras intacta |
| `PRD §3.2` (categorias) | **§6.2.2** | preservada verbatim |
| `PRD §3.3` (camadas 1–5) | **§6.2.3** | preservada verbatim, camadas intactas |
| `PRD §3.4` (ambiguidade) | **§6.2.4** | preservada verbatim |
| `PRD §3.5` (reutilização) | **§6.2.5** | preservada verbatim |
| `PRD §4.1` (entidades) | §4.4 | movida |
| `PRD §4.2` (atributos) | **§4.3** | preservada verbatim |
| `PRD §4.3` (recipiente) | §4.5 | movida |
| `PRD §5` (impactos) | §3.1 + §5 + §11 | dissolvida em 3 |
| `PRD §6.1` | **§6.3.1** | preservada verbatim |
| `PRD §6.2` | **§6.3.2** | preservada verbatim |
| `PRD §6.3` | **§6.3.3** | preservada verbatim |
| `PRD §7` (roadmap) | §12 (fonte agora `<internal plan>`) | substituída |
| `PRD §8` (critérios de aceite) | **Anexo B** | preservada, numeração 1–10 intacta |
| `PRD §9.1`–`§9.5` (decisões de produto) | **Anexo C** | preservadas, numeração intacta |
| `PRD §10` (riscos) | §13.12 | substituída por tabela de lacunas |
| `PRD §11` (referências) | inline em cada seção | dissolvida |

### A.2 Arquivos que precisam de atualização de citação

| Arquivo | Pontos a atualizar | Âncoras usados |
|---|---|---|
| `docs/superpowers/specs/2026-10-01-product-equivalence-by-category.md` | **48** | §3.1 (r.3, r.5), §3.2, §3.3, §4.2, §9.1, §9.2, §9.3, §9.4, §1.1 |
| `docs/superpowers/specs/2026-10-01-review-screen-ux.md` | **7** | §6.1, §6.2, §6.3, §3.3, §3.4, §8 (an earlier PR) |
| `docs/superpowers/specs/2026-10-04-price-comparison-dashboard-prd.md` | **4** | §3.2, §3.3, §4.2, §9 |
| `docs/adr/0001-product-identity-and-presentations.md` | **3** | §3.2, §9.4 (×2) |
| **Total** | **62** | — |

> As atualizações são **mecânicas** — a tabela A.1 dá o destino de cada âncora. Prioridade: o arquivo
> de equivalência concentra 77% das citações.

---

## Anexo B — Critérios de Aceite Consolidados

> ↩ **Preserva a numeração de `PRD §8` da v1.0.** A spec de UX cita "PRD §8 #10" — o critério 10
> abaixo. Critérios por feature também aparecem em §6 com checkboxes.

1. Dado `LEITE UHT HERC CX 12UN` e `LEITE INTEGRAL HERC 1L`, o sistema reconhece como mesmo produto
   canônico com apresentações diferentes
2. Dado `LEITE UHT INTEGRAL` e `LEITE UHT DESNATADO`, o sistema reconhece como produtos distintos
3. Dado `COXA FRANGO` e `COXA DE FRANGO SWIFT 1 kg`, o sistema reconhece como equivalentes (se mesma
   espécie/corte)
4. Dado `CUPIM COMBO` e `CUPIM`, o sistema reconhece como produtos distintos
5. Dado `EXTRATO DE TOMATE` e `MOLHO DE TOMATE`, o sistema reconhece como produtos distintos
6. Dado `COXA FRG` com contexto desconhecido, o sistema mantém pendente de revisão
7. Dado `LEITE UHT HERC CX 12UN` sem informação de tipo (integral/desnatado), o sistema mantém pendente
8. O sistema nunca força uma associação apenas para produzir uma comparação
9. Associações confirmadas são reutilizadas automaticamente dentro do escopo válido
10. Pendências não bloqueiam outras linhas da mesma nota

---

## Anexo C — Decisões de Produto Ratificadas

> ↩ **Preserva a numeração de `PRD §9` da v1.0.** As decisões **técnicas** estão em §13.

### C.1 Marca como atributo obrigatório? *(legado §9.1)*

**Decisão:** Marca é atributo relevante quando aplicável. Para hortifruti, ausência de marca é "não se
aplica", não "informação insuficiente".
**Justificativa:** Hortifruti geralmente não tem marca, mas variedade é suficiente para equivalência.
**Alternativas descartadas:** Exigir marca para todos (bloquearia hortifruti); ignorar marca
(misturaria produtos de marcas diferentes).

### C.2 Sinônimos globais vs. locais *(legado §9.2)*

**Decisão:** Sinônimos têm escopo (global, por loja, por emissor).
**Justificativa:** `CX FRG` pode significar coisas diferentes em emissores diferentes.
**Alternativas descartadas:** Sinônimos globais (geraria conflitos); sem escopo (impossibilitaria
reutilização).

> ⚠ **C-3 — corrigido na v2.1.** A v1.0 dizia "**Padrão é local**". O schema diz o **oposto**:
> `synonyms.scope` é nulável **sem default** (`db/001_schema.sql`), e o comentário da tabela define
> `scope NULL = global`. Quem grava sem informar escopo cria sinônimo **global**, não local — dois
> defaults incompatíveis para o mesmo campo, e o default vencedor é o do banco. Alinhar schema e
> documento é decisão técnica; aqui o documento passa a declarar o comportamento real do banco.

### C.3 Multipacks *(legado §9.3)*

**Decisão:** A quantidade de conteúdo é extraída do nome quando possível (ex: `CX 12UN` → 12
unidades).
**Justificativa:** A informação está disponível na descrição do cupom.
**Alternativas descartadas:** Exigir informação separada (aumentaria fricção); ignorar multipacks
(compararia preços incorretamente).

### C.4 Peso drenado *(legado §9.4)*

**Decisão:** `ERVILHA 1KG` (peso bruto) e `ERVILHA 800G` (peso drenado) são produtos distintos.
**Justificativa:** A diferença de peso é relevante para o consumidor.
**Alternativas descartadas:** Tratar como mesmo produto (ignoraria diferença relevante); exigir peso
drenado para todos (bloquearia produtos sem essa informação).
**Alcance ratificado (2026-10-01):** a regra **não se generaliza** para conserva como classe. Milho,
atum, sardinha, azeitona e palmito com peso declarado diferente caem na regra 3 de §6.2.1 (peso é
apresentação → MATCH).

### C.5 Reclassificação *(legado §9.5)*

**Decisão:** Se um item é reclassificado, o histórico de comparações é invalidado e recalculado.
**Justificativa:** Comparações antigas podem estar incorretas.
**Alternativas descartadas:** Manter histórico (poderia mostrar comparações erradas); excluir
histórico (perderia dados válidos).

---

*Documento gerado em 2026-10-01. Versão 2.0 — proposta para validação técnica
e de UX. Nenhuma linha deste documento autoriza implementação, migração ou alteração
de schema.*
