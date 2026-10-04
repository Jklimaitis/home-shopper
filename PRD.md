# PRD — home_shopper

## 1. Diagnóstico do estado atual

### 1.1 Schema implementado (código real)

- `products`: unicidade por `(name, brand)` — não captura variante (leite integral vs desnatado colidem)
- `presentations`: funde descrição + loja + conversão — não separa conteúdo de forma comercial
- `match_key`: gerado via `lower()` + `regexp_replace('[^a-z0-9]+', ' ')` — normaliza capitalização e espaços, mas **não há matcher automático**
- `synonyms`: palavra→palavra, não descrição completa→produto
- `staging_lines.match_source`: registra origem (`BARCODE`, `DESCRIPTION`, `ALIAS`, `MANUAL`, `NONE`) mas não há algoritmo
- **Zero** atributos estruturados por categoria
- **Zero** representação de recipiente/tipo de embalagem

### 1.2 Propostas existentes (não implementadas)

- **ADR-0001** (proposta): Separação produto canônico vs apresentação; critérios de equivalência por categoria; tratamento de ambiguidade
- **ADR-0002** (proposta): Reutilização de associações; revisão humana; consolidação parcial

### 1.3 Gap

Não há como decidir se `LEITE UHT HERC CX 12UN` e `LEITE INTEGRAL HERC 1L` são o mesmo produto, nem se `COXA FRANGO` e `COXA DE FRANGO SWIFT 1 kg` são equivalentes. A comparação entre lojas — o core do produto — não funciona.

---

## 2. Objetivo

Definir e implementar um sistema de matching de produtos entre lojas que:
- Reconheça o mesmo produto canônico mesmo com descrições diferentes
- Distinga produtos com diferenças relevantes de conteúdo
- Trate ambiguidades com revisão humana
- Permita comparação de preços por unidade-base

---

## 3. Especificação funcional

### 3.1 Produto canônico vs apresentação

**Produto canônico**: identidade do conteúdo comprado e das características relevantes à sua equivalência, segundo a categoria.

**Apresentação**: forma comercial em que um produto é vendido (quantidade, unidade, tipo de embalagem, configuração do pacote).

Regras:
1. Produtos com diferenças relevantes de conteúdo permanecem separados
2. Características independentes devem ser consideradas em conjunto (ex: teor de gordura + condição de lactose no leite)
3. Tamanhos e tipos de embalagem podem ser apresentações de um mesmo produto
4. A embalagem continua disponível como critério de escolha
5. Havendo informação insuficiente, contradição ou ambiguidade, o vínculo fica pendente de revisão
6. Código interno de loja e descrição do cupom são evidências, não identificadores globais
7. A comparação do mesmo produto exige identidade confirmada e unidade-base compatível
8. EAN é opcional e serve como identificador auxiliar

### 3.2 Critérios de equivalência por categoria

#### Laticínios (leite, iogurte, queijo)
- Atributos relevantes: marca, tipo (integral/desnatado/semidesnatado), condição de lactose, sabor
- Exemplos:
  - `LEITE UHT INTEGRAL` ≠ `LEITE UHT DESNATADO` ≠ `LEITE UHT INTEGRAL ZERO LACTOSE`
  - `LEITE UHT INTEGRAL 1L` = `LEITE UHT INTEGRAL CX 12UN` (mesmo conteúdo, apresentações diferentes)

#### Carnes
- Atributos relevantes: espécie, corte, preparo (com/sem tempero), marca
- Estado de conservação (refrigerado/congelado) **não** distingue
- Exemplos:
  - `COXA DE FRANGO` = `COXA FRANGO` (se mesma espécie/corte)
  - `CUPIM COMBO` ≠ `CUPIM` (combo é produto diferente)
  - `CARNE MOIDA` ≠ `CARNE MOIDA COMBO`

#### Mercearia (enlatados, massas, etc.)
- Atributos relevantes: marca, tipo de produto, sabor/variante
- Exemplos:
  - `EXTRATO DE TOMATE` ≠ `MOLHO DE TOMATE` ≠ `TOMATE PELADO`
  - `EXTRATO DE TOMATE 340G` = `EXTRATO DE TOMATE SACHÊ 340G` (se mesma marca e formulação)

#### Bebidas
- Atributos relevantes: marca, tipo, sabor
- Exemplos:
  - `COCA COLA 2L` = `COCA-COLA 2L`
  - `COCA COLA 2L` ≠ `COCA COLA ZERO 2L`

#### Hortifruti
- Atributos relevantes: variedade, marca (quando aplicável)
- Exemplos:
  - `BANANA PRATA` ≠ `BANANA NANICA`

#### Padaria
- Atributos relevantes: tipo, sabor
- Exemplos:
  - `PÃO FRANCÊS` = `PÃO FRANCÊS` (se mesmo tipo)

### 3.3 Algoritmo de matching

#### Camada 1 — Normalização textual
- Lowercase, remover acentos, normalizar espaços
- Expandir abreviações via `synonyms` (com escopo)
- Separar palavras concatenadas quando reconhecido com segurança

#### Camada 2 — Extração de atributos
- Extrair quantidade + unidade (`1 kg`, `500 ml`, `12 un`)
- Extrair tipo de embalagem (`cx`, `pc`, `pct`, `sc`, `lt`)
- Extrair marca (lista de marcas conhecidas ou padrão)
- Extrair características da categoria (regras por categoria)

#### Camada 3 — Busca de candidatos
- Buscar por `match_key` exato
- Se não encontrar, buscar por similaridade (`pg_trgm`)
- Filtrar por categoria

#### Camada 4 — Verificação de atributos
- Para cada candidato, verificar atributos relevantes da categoria
- Se todos coincidirem → match
- Se algum divergir → não match
- Se falta informação → pendente

#### Camada 5 — Decisão
- Match único com todos os atributos coincidindo → **automático**
- Múltiplos candidatos com atributos coincidindo → **pendente** (ambiguidade)
- Nenhum candidato → **pendente** (não encontrado)
- Candidato com atributo divergente → **não match**

### 3.4 Fluxo de tratamento de ambiguidade

1. Sistema identifica ambiguidade (múltiplos candidatos ou informação insuficiente)
2. Apresenta candidatos ao usuário com diferenças destacadas
3. Usuário escolhe o candidato correto ou confirma que não é nenhum
4. Decisão é registrada e pode virar associação reutilizável (com escopo)
5. Se usuário não resolver, item fica pendente de revisão
6. Pendência não bloqueia outras linhas da mesma nota

### 3.5 Reutilização de associações

- Associações confirmadas podem ser reutilizadas automaticamente dentro do escopo em que são válidas
- Requisitos: atributos relevantes continuam compatíveis e não há candidatos conflitantes
- Semelhança textual isolada serve para sugerir candidatos, não para confirmar equivalência
- Escopo pode ser: global, por loja, por emissor

---

## 4. Modelagem de produto

### 4.1 Entidades

- **Product**: produto canônico (identidade do conteúdo)
- **Presentation**: forma comercial (quantidade, unidade, embalagem)
- **Category**: categoria do produto (com hierarquia)
- **Synonym**: abreviação/sinônimo (palavra→palavra, com escopo)
- **ProductAttribute**: atributo estruturado por categoria (ex: teor de gordura, condição de lactose)

### 4.2 Atributos por categoria

Cada categoria define quais atributos são relevantes para equivalência:
- Laticínios: `fat_content`, `lactose_free`, `flavor`
- Carnes: `species`, `cut`, `seasoning`, `brand`
- Mercearia: `product_type`, `flavor`, `variant`
- Bebidas: `type`, `flavor`
- Hortifruti: `variety`
- Padaria: `type`, `flavor`

### 4.3 Representação de recipiente e quantidade

- `container_type`: tipo de embalagem (cx, pc, pct, sc, lt, un)
- `content_quantity`: quantidade de conteúdo (ex: 1000, 500, 340)
- `content_unit`: unidade de conteúdo (g, ml, un)
- `multipack_quantity`: quantidade de unidades no pacote (ex: 12 para CX 12UN)

---

## 5. Impactos técnicos (alto nível)

### 5.1 Schema

- Nova tabela `product_attributes` para atributos estruturados
- Nova tabela `product_aliases` para associações reutilizáveis (descrição completa→produto)
- Modificação de `presentations` para separar conteúdo de forma comercial
- Índice `pg_trgm` para busca por similaridade

### 5.2 Algoritmo

- Normalização textual (lowercase, acentos, espaços)
- Extração de atributos (regex + regras por categoria)
- Busca de candidatos (match_key + pg_trgm)
- Verificação de atributos (comparação estruturada)

### 5.3 Performance

- Índice `pg_trgm` em `presentations.match_key`
- Cache de associações confirmadas
- Processamento assíncrono para notas grandes

---

## 6. UX/UI (alto nível)

### 6.1 Tela de revisão

- Lista de itens pendentes com candidatos sugeridos
- Destaque de diferenças entre candidatos
- Ação: selecionar candidato, confirmar que não é nenhum, ou pular
- Explicação do motivo da pendência

### 6.2 Tela de confirmação

- Resumo da nota com valores originais
- Itens resolvidos vs pendentes
- Confirmação final da nota

### 6.3 Feedback

- Mensagem clara quando não há match
- Indicação de cobertura incompleta nos relatórios

---

## 7. Roadmap em sprints (alto nível)

### Sprint 1 — Fundação
- Schema: `product_attributes`, `product_aliases`
- Normalização textual básica
- Extração de quantidade + unidade

### Sprint 2 — Matching
- Busca por `match_key`
- Verificação de atributos por categoria
- Decisão automática vs pendente

### Sprint 3 — Revisão
- Tela de revisão de pendências
- Reutilização de associações
- Feedback ao usuário

### Sprint 4 — Refinamento
- Busca por similaridade (`pg_trgm`)
- Extração de marca e tipo de embalagem
- Performance e cache

---

## 8. Critérios de aceite

1. Dado `LEITE UHT HERC CX 12UN` e `LEITE INTEGRAL HERC 1L`, o sistema reconhece como mesmo produto canônico com apresentações diferentes
2. Dado `LEITE UHT INTEGRAL` e `LEITE UHT DESNATADO`, o sistema reconhece como produtos distintos
3. Dado `COXA FRANGO` e `COXA DE FRANGO SWIFT 1 kg`, o sistema reconhece como equivalentes (se mesma espécie/corte)
4. Dado `CUPIM COMBO` e `CUPIM`, o sistema reconhece como produtos distintos
5. Dado `EXTRATO DE TOMATE` e `MOLHO DE TOMATE`, o sistema reconhece como produtos distintos
6. Dado `COXA FRG` com contexto desconhecido, o sistema mantém pendente de revisão
7. Dado `LEITE UHT HERC CX 12UN` sem informação de tipo (integral/desnatado), o sistema mantém pendente
8. O sistema nunca força uma associação apenas para produzir uma comparação
9. Associações confirmadas são reutilizadas automaticamente dentro do escopo válido
10. Pendências não bloqueiam outras linhas da mesma nota

---

## 9. Decisões registradas

### 9.1 Marca como atributo obrigatório?
**Decisão**: Marca é atributo relevante quando aplicável. Para hortifruti, ausência de marca é "não se aplica", não "informação insuficiente".
**Justificativa**: Hortifruti geralmente não tem marca, mas variedade é suficiente para equivalência.
**Alternativas descartadas**: Exigir marca para todos (bloquearia hortifruti); Ignoraria marca (misturaria produtos de marcas diferentes).

### 9.2 Sinônimos globais vs. locais
**Decisão**: Sinônimos têm escopo (global, por loja, por emissor). Padrão é local.
**Justificativa**: `CX FRG` pode significar coisas diferentes em emissores diferentes.
**Alternativas descartadas**: Sinônimos globais (geraria conflitos); Sem escopo (impossibilitaria reutilização).

### 9.3 Multipacks
**Decisão**: A quantidade de conteúdo é extraída do nome quando possível (ex: `CX 12UN` → 12 unidades).
**Justificativa**: A informação está disponível na descrição do cupom.
**Alternativas descartadas**: Exigir informação separada (aumentaria fricção); Ignoraria multipacks (compararia preços incorretamente).

### 9.4 Peso drenado
**Decisão**: `ERVILHA 1KG` (peso bruto) e `ERVILHA 800G` (peso drenado) são produtos distintos.
**Justificativa**: A diferença de peso é relevante para o consumidor.
**Alternativas descartadas**: Tratar como mesmo produto (ignoraria diferença relevante); Exigir peso drenado para todos (bloquearia produtos sem essa informação).

### 9.5 Reclassificação
**Decisão**: Se um item é reclassificado, o histórico de comparações é invalidado e recalculado.
**Justificativa**: Comparações antigas podem estar incorretas.
**Alternativas descartadas**: Manter histórico (poderia mostrar comparações erradas); Excluir histórico (perderia dados válidos).

---

## 10. Riscos

- **Falso positivo**: Sistema associa produtos diferentes → mitigação: revisão humana para casos ambíguos
- **Falso negativo**: Sistema não associa produtos equivalentes → mitigação: busca por similaridade + revisão humana
- **Performance**: Busca por similaridade pode ser lenta → mitigação: índice `pg_trgm` + cache
- **Escalabilidade**: Categorias novas exigem novos atributos → mitigação: design extensível

---

## 11. Referências

- [ADR-0001](docs/adr/0001-product-identity-and-presentations.md) — Identidade de produtos e apresentações
- [ADR-0002](docs/adr/0002-association-review-and-consolidation.md) — Associação de itens, revisão humana e consolidação
- [CONTEXT.md](CONTEXT.md) — Glossário de domínio
- [ERD.md](docs/ERD.md) — Schema do banco
- [DECISIONS.md](docs/DECISIONS.md) — Índice de ADRs
