---
title: PRD — Painel de Comparação de Preços
project: home_shopper
status: proposed
created: 2026-10-04
task: internal task
---

# PRD — Painel de Comparação de Preços

## Estado do documento

Proposta de PRD para o painel de comparação de preços do home_shopper. **Não autoriza
implementação, migração nem alteração de schema.** Depende de matcher funcional (PRD.md §3.3)
e de `price_refs` populada (hoje vazia).

Substitui a seção genérica de "Analytics e Dashboard" do <internal plan> (Sprint 4). Onde houver
divergência entre este documento e o <internal plan>, este prevalece para o painel.

## Fontes canônicas, em ordem

1. `db/001_schema.sql`, `db/002_schema.sql`, `db/004_indexes_views.sql` — o que existe hoje.
2. `PRD.md` — critérios de equivalência (§3.2, §4.2, §9), algoritmo de matching (§3.3).
3. `docs/superpowers/specs/2026-10-01-product-equivalence-by-category.md` — atributos por categoria.
4. `docs/adr/0003-units-base-price-and-aggregation.md` — unidades, base_price e agregação.
5. `DESIGN.md` — design system (tokens, componentes, páginas).
6. `WIREFRAMES.md` — wireframes de baixa fidelidade das 4 telas.
7. `CONTEXT.md` — glossário de domínio.

Toda regra abaixo cita a fonte. Sem fonte, está marcado `PROPOSTA`.

---

## 1. Diagnóstico do estado atual

### 1.1 O que existe

- **Schema completo**: 14 tabelas, 5 views, 48 índices, 14 triggers (ERD.md).
- **`price_refs`**: tabela de preços por produto × loja × data. **Vazia** — 0 registros.
- **`line_items`**: 573 linhas de 15 notas, com `base_price` calculado por trigger.
- **`v_current_prices`**: view que expõe preços atuais por produto × loja.
- **`v_best_price`**: view que expõe melhor preço por produto.
- **Design system**: DESIGN.md completo com tokens, componentes e 4 páginas.
- **Wireframes**: 4 telas (Dashboard, Product Comparison, Store Detail, Review Queue).

### 1.2 O que não existe

- **API**: nenhum endpoint HTTP.
- **Frontend**: zero arquivos `.html`, `.css`, `.js`.
- **Matcher**: algoritmo de matching não implementado (PRD.md §3.3).
- **Processo de alimentação de `price_refs`**: não existe. A tabela está vazia.

### 1.3 Gap

O painel de comparação é o core do produto — o motivo de existir do home_shopper. Sem ele,
o usuário tem dados de compras mas não consegue ver preços lado a lado entre lojas. O gap é:
**não há como visualizar preços comparados entre lojas de forma útil e verificável.**

---

## 2. Objetivo

Permitir que o usuário veja, para cada produto canônico, o preço atual em cada loja onde
ele já comprou, e identifique qual loja oferece o melhor preço.

**Por que**: o valor do home_shopper está na comparação. Sem o painel, o sistema é um
repositório de notas fiscais. Com o painel, o usuário decide onde comprar.

---

## 3. Escopo

### 3.1 MVP (este PRD)

- **Comparação de preços entre lojas** para um produto canônico.
- **Melhor preço** por produto (loja mais barata).
- **Filtros essenciais**: produto (busca), loja, categoria.
- **Granularidade**: produto canônico (ex: "Leite Integral 1L"). Marca é atributo exibido,
  não eixo de comparação.

### 3.2 Fora do MVP (próximos ciclos)

- Alerta de queda de preço (requer atualização em tempo real — inviável no MVP).
- Cesta básica equivalente (reflexão para próximo ciclo).
- Filtros avançados (marca, período, faixa de preço).
- Produto + marca por mercado como eixo de comparação.
- Exportação de dados.
- Gráficos de histórico de preços.

### 3.3 Decisão de escopo

**Decisão**: MVP apenas com comparação de preços entre lojas, sem alertas nem cesta.
**Justificativa**: O usuário não faz compras diariamente. Alertas em tempo real não são
valiosos no contexto de compras semanais/mensais. A comparação estática já entrega o valor
central.
**Alternativas descartadas**: Incluir alertas (complexidade sem valor proporcional);
Incluir cesta (escopo grande demais para MVP).

---

## 4. Especificação funcional

### 4.1 Entrada de dados

O painel lê de `price_refs` (preços por produto × loja × data) e `line_items` (preços
efetivamente pagos). A alimentação de `price_refs` é responsabilidade de um processo
batch que roda após a consolidação de notas (Sprint 3 do <internal plan>).

**Regra**: `price_refs` é alimentado por processo batch, não em tempo real. O painel
mostra o último preço conhecido por produto × loja.

### 4.2 Comparação de preços

Para um produto canônico selecionado, o painel mostra:

| Campo | Origem | Descrição |
|---|---|---|
| Produto | `products.name` | Nome canônico |
| Categoria | `categories.name` | Categoria do produto |
| Loja | `stores.name` | Nome da loja |
| Preço unitário | `line_items.base_price` | Preço por unidade-base (g, ml, un) |
| Unidade-base | `line_items.base_unit` | UN, G ou ML |
| Data da compra | `purchase_notes.purchase_date` | Quando o preço foi observado |
| Apresentação | `presentations.description_raw` | Como veio no cupom |

**Regras**:

1. Preços são sempre exibidos por unidade-base (g, ml, ml, un). Nunca por embalagem.
2. A comparação exige que o produto canônico seja o mesmo (matcher funcional).
3. Lojas sem o produto não aparecem na comparação.
4. Preços de apresentações diferentes (ex: 500g vs 1kg) são normalizados para unidade-base.

### 4.3 Melhor preço

O painel destaca a loja com menor `base_price` para o produto selecionado.

**Regra**: O melhor preço é o menor `base_price` entre as lojas que têm o produto.
Empate: ambas as lojas são destacadas.

### 4.4 Filtros essenciais

Três filtros são essenciais no MVP:

1. **Produto** (busca textual): o usuário digita o nome do produto e vê a comparação.
2. **Loja**: filtra quais lojas aparecem na comparação.
3. **Categoria**: filtra produtos por categoria.

**Justificativa**: O usuário quer saber "onde é mais barato comprar X". Os três filtros
respondem essa pergunta. Filtros adicionais (marca, período) são refinamento, não necessidade.

### 4.5 Ordenação

Padrão: preço (menor primeiro). O usuário quer ver o mais barato no topo.

Opções: preço, loja (alfabética), data (mais recente primeiro).

---

## 5. Modelagem de produto

### 5.1 Entidades envolvidas

O painel não cria entidades novas. Ele lê de:

- **Product**: produto canônico (identidade do conteúdo).
- **Presentation**: forma comercial (quantidade, unidade, embalagem).
- **Store**: loja onde o produto foi comprado.
- **LineItem**: linha de compra com `base_price` calculado.
- **PriceRef**: referência de preço por produto × loja × data (para histórico).

### 5.2 Relação com matcher

O painel **não faz matching**. Ele exibe o resultado do matching. Se o matcher falha
(produto não identificado), o preço não aparece no painel. O usuário resolve pendências
na tela de revisão (internal task-B), não no painel.

### 5.3 Granularidade: produto canônico vs produto + marca

**MVP**: produto canônico. "Leite Integral 1L" é uma linha na comparação, independente
de marca.

**Visão futura**: produto + marca. "Leite Integral Italac 1L" e "Leite Integral HerC 1L"
são linhas separadas.

**Decisão**: MVP com produto canônico. A separação por marca é refinamento.
**Justificativa**: O matcher atual (PRD.md §3.3) opera sobre produto canônico. Separar
por marca exigiria mudança no matcher e no schema de `price_refs`.
**Alternativas descartadas**: Produto + marca desde o início (aumenta complexidade do
matcher sem proporcionalidade de valor no MVP).

---

## 6. Impactos técnicos (alto nível)

### 6.1 API

O painel exige endpoints HTTP:

- `GET /products` — lista produtos canônicos (para busca).
- `GET /products/{id}/prices` — preços do produto por loja.
- `GET /stores` — lista lojas.
- `GET /categories` — lista categorias.

### 6.2 Frontend

O painel é uma SPA (Single Page Application) que consome a API. O design system
(DESIGN.md) define os componentes.

### 6.3 Performance

- `price_refs` deve ter índice em `(product_id, store_id, ref_date)`.
- A query do painel é simples: SELECT com JOIN em `products`, `stores`, `line_items`.
- Com 480 itens e 6 lojas, a query deve retornar em < 100ms.

### 6.4 Dependências

| Dependência | Status | Bloqueia |
|---|---|---|
| Matcher funcional | não implementado | preços não aparecem sem match |
| `price_refs` populada | vazia | painel não mostra dados |
| API | inexistente | frontend não consome |
| Processo batch de alimentação | inexistente | `price_refs` não é atualizada |

---

## 7. UX/UI (alto nível)

### 7.1 Tela principal — Comparação de Preços

Baseada no wireframe "Product Comparison Page" (WIREFRAMES.md §2).

**Componentes** (DESIGN.md):

- `nav-top`: barra superior com logo, busca, filtros.
- `card-price-comparison`: card principal com produto + lojas.
- `store-row`: linha por loja com preço, unidade-base, data.
- `store-row-best`: loja com melhor preço (destaque azul).
- `badge-best-price`: badge "melhor preço".
- `filter-chip`: filtros de categoria e loja.

**Layout**:

```
┌─────────────────────────────────────────────────────────────┐
│  [LOGO]  home_shopper    [🔍 Buscar produto...]  [👤] [⚙️]  │
├─────────────────────────────────────────────────────────────┤
│  [Todos] [Laticínios] [Carnes] [Mercearia] [Bebidas] ...   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────┐  Leite Integral 1L                           │
│  │          │  Categoria: Laticínios                        │
│  │  [IMG]   │  Unidade base: L                              │
│  │          │                                               │
│  └──────────┘                                               │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ ★ Supermarket A                    MELHOR    │   │
│  │    R$ 4,49/L                              ↓ 10%     │   │
│  │    Atualizado: 15/06/2026              [Comprar →]  │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Mercado Sul                                                │   │
│  │    R$ 4,99/L                              estável   │   │
│  │    Atualizado: 15/06/2026                           │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Supermarket G                                             │   │
│  │    R$ 5,29/L                              ↑ 5%      │   │
│  │    Atualizado: 14/06/2026                           │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 Interações

- Buscar produto → atualiza comparação.
- Filtrar loja → mostra apenas lojas selecionadas.
- Filtrar categoria → mostra apenas produtos da categoria.
- Clicar em "Comprar" → link externo ou adicionar à lista (fora do MVP).

### 7.3 Estados

- **Sem dados**: "Nenhum preço encontrado para este produto."
- **Carregando**: skeleton.
- **Erro**: "Erro ao carregar preços. Tente novamente."

---

## 8. Roadmap em sprints (alto nível)

### Sprint 4 — Painel de Comparação (substitui <internal plan> §6)

**Objetivo**: Mostrar comparação de preços entre lojas para produtos canônicos.

**Entregáveis**:

1. **API** — endpoints de leitura (`/products`, `/products/{id}/prices`, `/stores`, `/categories`).
2. **Processo batch** — alimenta `price_refs` a partir de `line_items` consolidados.
3. **Frontend** — tela de comparação com filtros essenciais.
4. **Testes** — testes de integração da API e do processo batch.

**Critérios de aceite**:

- [ ] API retorna preços por produto × loja em < 100ms.
- [ ] Processo batch popula `price_refs` corretamente.
- [ ] Tela mostra comparação de preços com filtros essenciais.
- [ ] Melhor preço é destacado corretamente.
- [ ] Testes de integração cobrem fluxo completo.

**Dependências**:

- Sprint 3 (consolidação funcional).
- Matcher funcional.
- ADR-0003 (rascunho — precisa ser revisado).

---

## 9. Critérios de aceite

1. Dado um produto canônico com preços em 3 lojas, o painel mostra os 3 preços lado a lado
   por unidade-base.
2. Dado um produto com apenas 1 loja, o painel mostra apenas essa loja.
3. Dado um produto sem preços, o painel mostra "Nenhum preço encontrado".
4. O melhor preço é destacado com `store-row-best` e `badge-best-price`.
5. Filtro de loja mostra apenas lojas selecionadas.
6. Filtro de categoria mostra apenas produtos da categoria.
7. Busca de produto filtra por nome canônico.
8. Preços são sempre exibidos por unidade-base (g, ml, un), nunca por embalagem.
9. O painel não mostra preços de produtos não identificados (pendentes de matching).
10. API retorna erro 404 para produto inexistente.
11. API retorna erro 400 para parâmetros inválidos.
12. Processo batch não duplica registros em `price_refs`.
13. Tela carrega em < 2s com 480 itens e 6 lojas.

---

## 10. Decisões registradas

### 10.1 Escopo do MVP

**Decisão**: Apenas comparação de preços entre lojas. Sem alertas, sem cesta, sem
filtros avançados.
**Justificativa**: O valor central do produto é a comparação. Features adicionais
aumentam complexidade sem proporcionalidade de valor no MVP.
**Alternativas descartadas**: Incluir alertas (requer tempo real); Incluir cesta
(escopo grande demais).

### 10.2 Granularidade: produto canônico

**Decisão**: MVP com produto canônico. Marca é atributo exibido, não eixo de comparação.
**Justificativa**: O matcher opera sobre produto canônico. Separar por marca exigiria
mudança no matcher e no schema.
**Alternativas descartadas**: Produto + marca desde o início (aumenta complexidade sem
proporcionalidade de valor).

### 10.3 Filtros essenciais

**Decisão**: Três filtros — produto (busca), loja, categoria.
**Justificativa**: Respondem à pergunta central: "onde é mais barato comprar X?".
**Alternativas descartadas**: Filtros avançados (marca, período) — refinamento, não
necessidade.

### 10.4 Alimentação de `price_refs`

**Decisão**: Processo batch após consolidação de notas. Não em tempo real.
**Justificativa**: O usuário não faz compras diariamente. Atualização em tempo real não
é necessária.
**Alternativas descartadas**: Tempo real (complexidade sem valor proporcional).

### 10.5 Alertas de queda de preço

**Decisão**: Fora do MVP. Próximo ciclo.
**Justificativa**: Requer atualização em tempo real. O contexto de compras semanais/mensais
não justifica.
**Alternativas descartadas**: Incluir no MVP (complexidade sem valor proporcional).

### 10.6 Cesta básica

**Decisão**: Fora do MVP. Próximo ciclo.
**Justificativa**: Escopo grande demais. Requer reflexão adicional.
**Alternativas descartadas**: Incluir no MVP (escopo grande demais).

---

## 11. Riscos

| Risco | Impacto | Mitigação |
|---|---|---|
| Matcher não funcional | Preços não aparecem | Resolver matcher antes do painel |
| `price_refs` vazia | Painel sem dados | Processo batch de alimentação |
| Performance lenta | Usuário desiste | Índices em `price_refs` + query simples |
| Dados incompletos | Comparação incompleta | Mostrar "cobertura incompleta" na tela |
| Mudança de schema | Retrabalho | Painel não cria entidades novas |

---

## 12. Referências

- [PRD.md](../../../PRD.md) — Especificação funcional de matching
- [DESIGN.md](../../../DESIGN.md) — Design system
- [WIREFRAMES.md](../../WIREFRAMES.md) — Wireframes das telas
- [ERD.md](../../../docs/ERD.md) — Schema do banco
- [CONTEXT.md](../../CONTEXT.md) — Glossário de domínio
- [ADR-0003](../../../docs/adr/0003-units-base-price-and-aggregation.md) — Unidades e preços
- [Spec: Equivalência por categoria](../../docs/superpowers/specs/2026-10-01-product-equivalence-by-category.md)
- [Spec: UX da tela de revisão](../../docs/superpowers/specs/2026-10-01-review-screen-ux.md)
