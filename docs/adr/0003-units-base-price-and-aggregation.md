---
status: draft
numero: 3
criado: 2026-09-30
---

# ADR-0003: Unidades de comparação, base price e agregação de preços

O schema já implementa esta decisão (enum `base_unit`, coluna `base_price`, trigger
`tr_line_items_base_price`, view `v_price_aggregation`). Este documento existe para
**registrar** a decisão, não para autorizá-la: ele precisa ser revisado contra o código
antes de virar `accepted`. Onde o código e a decisão divergirem, a divergência precisa ser
resolvida explicitamente, não silenciosamente.

## Contexto

Comparar o preço do mesmo produto entre lojas falha na unidade antes de falhar no valor.
Uma nota mistura formas incompatíveis de expressar o mesmo fato:

| Situação real | Como aparece | Por que quebra a comparação |
|---|---|---|
| Surimi 250 g | R$ 10,90 por `PC` | 250 g e 1 kg não se comparam por preço de embalagem |
| Cupim vendido a peso | 1,446 kg a R$ 39,90/kg | O preço é do kg, a quantidade é o peso comprado |
| Leite em caixa | R$ 59,88 por `CX` de 12 | Uma caixa não é um litro |
| Kani Kama 250 g vs Moída 1 kg | R$ 10,90 vs R$ 29,90 | Comparação direta diria que 250 g custa quase o triplo do quilo |

O erro de não normalizar é silencioso: os dois lados são `NUMERIC`, então nenhuma checagem
de tipo dispara. O dashboard afirmaria que o pacote de 250 g custa mais que o quilo, e o
erro passaria como dado.

Duas decisões distintas se misturam aqui e precisam ser separadas:

1. **Qual é a unidade em que o preço é comparado** (dimensional, por produto).
2. **Como vários preços do mesmo item se transformam em um preço de referência** (agregação,
   por usuário, loja e dia).

## Decisão registrada

### 1. Unidade-base: sempre a menor unidade da dimensão

`base_unit` é um enum com exatamente três valores: `UN`, `G`, `ML`.

`KG` e `L` **não existem** no enum, de propósito. Se existissem, um `MIN()` entre
`0,0299 in G` e `29,9 in KG` compararia a mesma grandeza em escalas diferentes: erro de mil
vezes, sem erro de tipo. A restrição é do schema, não uma recomendação — é o tipo que
impede o erro, não o comentário que o previne.

A escolha por unidade é **por produto, por categoria**: massa vai para `G`, volume para `ML`,
itens contáveis para `UN`. Um produto que muda de dimensão (kg de carne, ml de óleo) tem
produtos distintos; não há conversão implícita.

### 2. Conversão respeita a dimensão

**1.000 g = 1 kg** e **1.000 mL = 1 L** são conversões válidas. **1 kg = 1 L não é.**

Massa e volume são grandezas diferentes. Uma conversão entre elas exigiria densidade
conhecida do produto e condições definidas (temperatura); não pode ser presumida pelo nome
ou pela categoria. Sem densidade fundamentada, um item em massa e outro em volume **não
entram na mesma comparação** — ficam como categorias distintas, e o dashboard diz que não
são comparáveis em vez de fabricar um número.

### 3. `base_price` é derivado, nunca digitado

```
base_price = round(unit_price / factor_base, 8)
```

O trigger `tr_line_items_base_price` calcula e **recusa a linha** quando o `presentation_id`
está ausente ou a apresentação não pertence ao produto declarado. A recusa é o ponto: sem
fator de conversão não existe preço comparável, e o schema prefere perder uma linha a
armazenar um número sem significado.

`base_price` não é coluna preenchida pelo usuário em nenhum caminho. Derivado é o que impede
dois valores divergentes para o mesmo fato.

### 4. Venda por peso é um caso próprio, não uma convenção

Quando `sale_unit = 'KG'`, o item é **vendido por peso**. O `factor_base` é a referência de
preço (1 kg = 1000 g); o peso realmente comprado vai em `quantity` (1,446).

Confundir os dois é o erro clássico: tratar `KG` como "preço por quilo" e multiplicar pelo
peso, quando o cupom já traz o total. O schema separa os dois campos justamente para que a
interpretação seja explícita e revisável.

Casos reais que o enum deixou de fora por serem ambíguos: `UND9`, `KG9`, `FRC9`, `GFA9`,
`UND8`, `PCT9`, `FDO9`, `PCT8` (unidades impressas por dois emissores). São **rótulos
opacos do emissor**, não unidades de medida. Ficam em `sale_unit` como texto e exigem
mapeamento confirmado por emissor — o valor original é sempre preservado.

### 5. Agregação: média ponderada pela quantidade, nunca `min()`

`v_price_aggregation` calcula `sum(base_price * quantity) / sum(quantity)`.

Para duas compras do mesmo item no mesmo dia a R$ 39,90 e R$ 44,90:

| Agregação | Resultado | Problema |
|---|---|---|
| Média simples | 0,04240 | trata as duas compras como igualmente relevantes |
| **Ponderada pela quantidade** | o que a pessoa pagou | reflete o gasto real |
| `min()` | 0,03990 | **infla a queda e dispara alerta falso** |

`min()` é a pior das três. Um alerta de marketing errado é pior do que nenhum alerta: o
usuário perde confiança e para de ler. A ponderação é a única das três que corresponde ao que
foi efetivamente pago.

A agregação é `GROUP BY (user_id, product_id, store_id, purchase_date, base_unit)`. O
`user_id` não é detalhe: duas pessoas que compraram o mesmo item na mesma loja colapsariam na
mesma chave, e uma veria o preço da outra. `base_unit` também é parte da chave — sem ele um
`MIN()` não consegue dizer se compara grandezas iguais.

`price_refs` é populado por job, não por trigger. Agregar para (usuário, produto, loja, dia) é
**decisão de negócio**; escondê-la num trigger que ninguém lê seria o lugar errado.

### 6. Tolerância no checksum, nunca igualdade exata

O checksum compara `total_gross` contra a soma das linhas, mas a autoridade fiscal
**arredonda a linha, não o produto**:

```
1,446 kg × 39,90 = 57,6954  →  gravado como 57,70
```

Somar os produtos brutos e comparar contra totais de linha já arredondados reporta divergência
falsa em qualquer nota com item a peso. Por isso a fórmula é `SUM(line_total)`.

Além disso a comparação final usa **tolerância**, nunca igualdade exata. A32: o desconto vive
nos totais, não nas linhas (550,93 − 6,00 = 544,93); comparar a soma das linhas com o valor
**pago** reportaria 600 centavos de divergência em toda nota com desconto, um falso positivo
garantido.

## Alternativas consideradas

### Manter o preço da embalagem e comparar na aplicação

Simplifica o schema. Descartado: transfere a normalização para o consumidor de cada consulta,
e qualquer consulta nova que esqueça de normalizar devolve número errado sem erro. A regra
precisa estar no banco, onde não pode ser esquecida.

### Permitir `KG` e `L` no enum de unidade-base

Mais legível para o humano. Descartado: a passagem `29,9 in KG → 29,9` sobre
`0,0299 in G` é exatamente o erro de mil vezes que o enum previne. Um valor de domínio
permissivo aqui não é simplicidade, é um erro sem sintoma.

### Agregar por `min()`, `max()` ou média simples

`min()` dispara alerta falso (ver acima). `max()` infla a queda. A média simples trata
compras de quantidades diferentes como igualmente relevantes. **Ponderada pela quantidade** é a
que reproduz o gasto real.

### Converter massa ↔ volume com densidade estimada

Permitiria comparar óleo (ml) com arroz (g) num único número. Descartado: exigiria densidade
por produto e condição, e a densidade estimada produz erro sem sinal. Dimensões diferentes
ficam em comparações separadas.

### Uma unidade de venda canônica por produto, imposta à entrada

Simplificaria a revisão. Descartado: a unidade impressa é do **emissor**, e impor uma
obrigaria o sistema a mentir sobre o cupom. O valor original é preservado e a interpretação é
uma decisão registrada e auditável.

## Consequências

**Positivas**

- Preços de Presentation e peso ficam comparáveis por construção, não por disciplina do código.
- O erro de mil vezes é impedido pelo *tipo*, não por convenção.
- A ponderação reproduz o gasto real, e o alerta de preço deixa de ser ficção.
- Nenhum `base_price` digitável: não há dois valores para o mesmo fato divergirem.

**Negativas e riscos**

- `presentations` guarda `factor_base` e a descrição da loja juntos, por decisão anterior
  (ADR-0001). Uma apresentação por loja é o custo aceito dessa escolha.
- Rótulos opacos do emissor (`UND9`, `GFA9`, `PCT8`) exigem mapeamento confirmado por CNPJ.
  Uma filial nova do mesmo Supermarket G exigiu revisão separada: os mapeamentos **não** se propagam
  automaticamente entre emissores.
- Agregar em job significa que `price_refs` pode ficar levemente atrasado em relação a uma
  compra recém-consolidada. A defasagem é pequena e conhecida, mas precisa de janela definida.
- Com 1 nota por loja, qualquer `min()`/`MAX()` sobre poucas amostras é frágil. O `min_30d` /
  `max_30d` precisam de um mínimo de amostras declarado antes de virarem alerta.

**Estado no código**

Implementado e coberto por teste: enum `base_unit`, `base_price` NOT NULL, trigger
`tr_line_items_base_price` com recusa, `ck_base_unit` sem `KG`/`L` (asserção R5), view
`v_price_aggregation` ponderada, checksum com `SUM(line_total)` e exclusão de linhas
descartadas.

**O que este documento não decide**: número mínimo de amostras para um alerta de preço ser
considerado confiável; janela de defasagem de `price_refs`; política de arredondamento por
categoria (peso líquido, peso drenado); tratamento de `qty` fracionada de itens contáveis
(`0,15 un` de sacola, `12 un` de Itubaína registrada como 12 unidades, não como fardo).

## Pontos pendentes de revisão

- Número mínimo de amostras para `min_30d`/`max_30d` gerarem alerta confiável.
- Política de arredondamento e tolerância por categoria.
- Janela de defasagem aceitável entre consolidação e `price_refs`.
- Se `factor_base` deve migrar para uma tabela de conversão versionada quando a embalagem
  mudar (ex.:Toddy passa de 390 g a 397 g sem mudar o produto).
- Como tratar peso drenado e peso líquido em conservas, que não seguem a conversão simples.
