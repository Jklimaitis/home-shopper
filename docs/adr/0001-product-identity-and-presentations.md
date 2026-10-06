---
status: accepted
---

# ADR-0001: Identidade de produtos e apresentações

O catálogo precisa reconhecer o mesmo produto entre lojas sem confundir diferenças de conteúdo com diferenças de embalagem. A regra de domínio alinhada com o usuário separa o produto canônico da sua apresentação comercial. Este registro foi revisado e está aceito quanto à direção de domínio; a aceitação **não** autoriza alteração de schema, migração ou implementação. Os critérios de equivalência por categoria estão especificados em [docs/superpowers/specs/2026-10-01-product-equivalence-by-category.md](../superpowers/specs/2026-10-01-product-equivalence-by-category.md).

## Contexto

Descrições de cupons e códigos internos variam por emissor. Embalagens de tamanhos e materiais diferentes também podem conter o mesmo produto, enquanto itens com nomes parecidos podem ter formulações ou características diferentes.

Agrupar qualquer item pelo nome ou pela unidade de medida pode gerar comparações inadequadas. Separar cada tamanho e tipo de recipiente em um produto distinto, por outro lado, dificulta comparar apresentações equivalentes por quantidade de conteúdo.

## Regra

**Produto canônico identifica o conteúdo e suas características relevantes. Apresentação identifica como ele é vendido: quantidade, unidade, tipo de embalagem e configuração do pacote. Os critérios de equivalência variam por categoria.**

1. Produtos com diferenças relevantes de conteúdo permanecem separados. Marca e variante fazem parte da análise quando aplicáveis à categoria; tamanho, recipiente ou nome parecido não são suficientes para estabelecer equivalência.
2. Características independentes devem ser consideradas em conjunto. Em leite, teor de gordura e condição de lactose são dimensões diferentes: integral zero lactose não equivale a integral convencional nem a desnatado zero lactose.
3. Tamanhos e tipos de embalagem podem ser apresentações de um mesmo produto quando a equivalência do conteúdo estiver confirmada. A mudança de recipiente, por si só, não cria outro produto canônico.
4. A embalagem continua disponível como critério de escolha. O usuário poderá restringir as apresentações consideradas; o menor preço por unidade-base não implica que uma embalagem seja a mais adequada para ele.
5. Havendo informação insuficiente, contradição ou ambiguidade, o vínculo fica pendente de revisão. Não se assume equivalência apenas para produzir uma comparação. A ausência de um atributo relevante não constitui evidência de igualdade. A ausência de um atributo aplicável **nos dois lados da comparação**, sem informação que os distinga, não gera pendência: a identidade se decide pelos atributos presentes. PENDENTE fica reservado ao caso em que um lado informa o atributo e o outro não, ou em que os valores conflitam. "Não se aplica" é distinto de "desconhecido": o primeiro decorre de a categoria não usar o atributo para equivalência, e não gera pendência.
6. Código interno de loja e descrição do cupom são evidências de identificação, não identificadores globais. Uma associação confirmada pode ser reutilizada conforme seu escopo; nenhum matcher automático é definido por esta ADR.
7. A comparação do mesmo produto exige identidade confirmada e unidade-base compatível. Comparar substitutos, como marcas ou variantes diferentes, será uma função distinta, caso venha a ser adotada.
8. EAN é opcional e serve como identificador auxiliar do item comercial quando estiver disponível. A identidade canônica, a importação e uma associação confirmada por revisão não dependem de sua existência. Não se exige um único EAN para todas as apresentações nem se inclui consulta externa ou leitura de código de barras no escopo desta decisão.
9. No escopo de comparação do home_shopper, carne refrigerada e congelada não são separadas em produtos canônicos apenas por esse estado de conservação. A equivalência ainda exige conteúdo confirmado, incluindo espécie, corte, preparo e marca quando aplicáveis. O estado de conservação pode ser preservado como informação da fonte, mas não impede a comparação por si só. Essa escolha não afirma igualdade de validade, armazenamento ou manipulação. **O alcance é restrito a carnes** (decisão de 2026-10-01): nas demais categorias a conservação permanece decisão aberta, e nenhuma regra é aplicada.
10. Um peso efetivo diferente não cria outro produto canônico. Para carnes de peso variável, a quantidade efetivamente comprada participa da comparação; embalagem e peso de cada porção não substituem os critérios de identidade.
11. A unidade de venda informada na linha orienta a interpretação do preço unitário e da quantidade, em conjunto com a apresentação confirmada. Diferenças de maiúsculas e minúsculas, como `UN`/`un` e `KG`/`kg`, não mudam a unidade. Outros rótulos exigem um mapeamento confirmado; não se presume um vocabulário idêntico entre emissores. A descrição contendo "1 kg" não basta para decidir entre venda por unidade e venda por peso. Dados ausentes ou contraditórios mantêm a interpretação pendente de revisão, e os valores originais da fonte devem ser preservados.

## Exemplos discutidos

Os exemplos abaixo são ilustrativos e não representam registros importados nem um catálogo já validado.

| Situação | Tratamento |
|---|---|
| Leite da mesma marca e mesma variante, em 500 mL e 1 L | Mesmo produto canônico, apresentações diferentes. |
| Leite integral e desnatado da mesma marca | Produtos canônicos distintos. |
| Leite integral convencional e integral zero lactose | Produtos canônicos distintos. |
| Extrato de tomate da mesma marca, linha e formulação, em sachê, lata ou caixa | Mesmo produto canônico, apresentações diferentes, se a equivalência estiver confirmada. |
| Embalagens de extrato com composição ou concentração relevantes diferentes | Não agrupar automaticamente; avaliar como produtos distintos. |
| Extrato de tomate, molho pronto e tomate pelado | Produtos distintos; compartilhar ingrediente não estabelece equivalência. |
| Descrição de extrato sem informação suficiente sobre a variante | Manter identificação pendente de revisão. |
| Carne equivalente quanto à espécie, corte, preparo e marca quando aplicável, refrigerada em bandeja ou congelada em pacote | Mesmo produto canônico no escopo do projeto; o recipiente pode distinguir apresentações, mas a conservação isoladamente não distingue a identidade. |
| Porções com pesos efetivos diferentes de uma mesma carne equivalente | Mesmo produto canônico; registrar a quantidade efetivamente comprada para comparação. |
| Carne sem tempero e uma versão temperada, ou espécies e cortes diferentes | Não agrupar automaticamente; há diferenças de conteúdo ou preparo, não apenas de conservação. |
| `ERVILHA 1KG` e `ERVILHA 800G` | Produtos distintos (PRD §9.4). Caso nomeado: **não** se generaliza para conserva como classe (decisão de 2026-10-01). |

A comparação por massa exige a quantidade de conteúdo pertinente à categoria, não o peso do recipiente. Itens com peso drenado, peso variável ou vendidos por contagem precisam de critérios próprios antes da comparação; esses critérios estão especificados no documento de critérios por categoria.

Conversões devem respeitar a dimensão: **1.000 g = 1 kg** e **1.000 mL = 1 L**. Não se adota **1 kg = 1 L** como convenção, porque massa e volume são grandezas diferentes. Uma conversão entre elas exigiria densidade adequada ao produto e condições conhecidas; ela não será presumida a partir do nome ou da categoria. Sem conversão fundamentada, medidas de dimensões diferentes não entram na mesma comparação.

A escolha da unidade-base de exibição, da precisão e das regras de cálculo de preços será detalhada na decisão de comparação e agregação, sem ampliar esta ADR para um contrato de implementação.

## Escopo ratificado

Decisões do usuário registradas em 2026-10-01:

1. **Categorias** — as 6 do PRD §3.2 (laticínios, carnes, mercearia, bebidas, hortifruti, padaria). Limpeza, higiene e pet ficam fora deste ciclo; acrescentá-las depois é dado, não migração.

   > **Emenda de 2026-10-05 (D7, card `internal task`):** o escopo passa a **8** categorias — **Limpeza** e **Higiene** entram, com `product_type` e `variant` declarados; a fronteira de classificação é a do review de 2026-10-03. **Pet segue fora.** O texto original acima fica preservado como registro da decisão de 2026-10-01 e aponta a sucessora; detalhe em `docs/decisions/2026-10-05-escopo-8-categorias-limpeza-higiene.md`.
2. **Conservação** — restrita a carnes (regra 9). Não se generaliza.
3. **Origem em hortifruti** — `orgânico ≠ convencional` não é adotado.
4. **Equivalências de rótulo** — `zero lactose` ≡ `sem lactose` e `zero` ≡ `sem açúcar` ficam **PENDENTE**. São sinônimos com escopo, não regra de identidade.
5. **Peso drenado** — vale só o caso do PRD §9.4 (`ERVILHA 1KG` ≠ `ERVILHA 800G`). A generalização para produto enlatado foi rejeitada; demais conservas com peso declarado diferente seguem a regra 3 (peso é apresentação).

## Alternativas consideradas

### Um produto para cada embalagem ou tamanho

Simplifica a identificação de cada item comercial, mas fragmenta a comparação entre conteúdos equivalentes. A regra adotada mantém esses itens distinguíveis no nível da apresentação, preservando a possibilidade de compará-los por unidade-base.

### Um produto genérico por nome ou categoria

Reduz o catálogo, mas mistura marcas, formulações e restrições relevantes. A regra adotada evita esse agrupamento; uma eventual comparação de substitutos deverá ser explícita.

### Produto canônico com apresentações separadas

É a opção escolhida como direção de domínio. Permite agrupar conteúdo equivalente sem eliminar tamanho ou embalagem, mas exige critérios por categoria, evidência de equivalência e tratamento de ambiguidades.

## Consequências e limites

- O catálogo não pode depender apenas de uma lista universal de variantes. As características relevantes precisam ser definidas e verificadas por categoria.
- Embalagem e configuração do pacote precisam ser distinguíveis para filtros e conversões, mesmo quando o conteúdo pertence ao mesmo produto.
- Identificação automática deve admitir um resultado inconclusivo. A revisão humana faz parte da regra, mas seu fluxo será definido em outra decisão.
- A regra permite comparar apresentações; ela não decide o tratamento de descontos, arredondamento, média ponderada ou preço de referência.
- Reclassificar um item poderá afetar associações e histórico de comparações. A estratégia de correção e preservação de histórico ainda precisa ser definida.

## Relação com o banco atual

`products` hoje tem unicidade por `(name, brand)` e um único campo opcional `ean`. Isso não representa uma identidade completa por categoria e variante. `presentations` combina descrição, loja, unidade de venda e fator de conversão; não possui um atributo estruturado para o tipo de embalagem.

Portanto, a regra aceita não deve ser confundida com uma garantia das constraints existentes. Este documento não modifica os arquivos de bootstrap, os testes ou os dados.

## Decisões de implementação ainda necessárias

- Como representar recipiente, quantidade de conteúdo e configuração de multipacks, incluindo a quantidade pertinente à comparação.
- Como associar EANs aos itens comerciais quando apresentações de um produto tiverem códigos diferentes; o campo único atual em `products` não resolve esse caso.
- Se descrições e aliases por loja devem ficar separados da apresentação comercial, para evitar duplicar a embalagem a cada nova descrição.
- Como representar o comportamento do peso drenado — atado ao caso nomeado do §9.4, não a uma classe de categoria nem a um valor por produto.
- Como revisar vínculos e corrigir o histórico, incluindo categorias sem marca e com peso variável.

A representação de características por categoria e a distinção entre valor desconhecido, ausente e não aplicável foram resolvidas na especificação de critérios por categoria e estão em avaliação técnica em internal task-A (proposta de `category_attributes` + `product_attributes`, ainda não aprovada nem migrada).

Estes pontos não são cobertos pela aceitação desta regra e serão detalhados em propostas próprias antes de qualquer migração ou implementação.
