---
title: Critérios de equivalência de produtos por categoria
project: home_shopper
status: accepted
created: 2026-10-01
---

# Critérios de equivalência de produtos por categoria

## Estado do documento

Critérios ratificados pelo usuário em 2026-10-01, com as decisões registradas em
§"Decisões ratificadas". A aceitação **não autoriza implementação, migração nem alteração de
schema**: a camada 4 do algoritmo de matching (PRD §3.3) depende desta especificação, e a
implementação precisa de plano próprio.

Substitui a spec discutida em thread no `#operacao`. Onde houver divergência entre este arquivo e
a thread, este arquivo prevalece.

## Fontes canônicas, em ordem

1. `db/001_schema.sql` e `db/002_schema.sql` — o que existe hoje.
2. `PRD.md` §3.1, §3.2, §3.3, §4.2, §9 — critérios por categoria. **Staged no git** (`A PRD.md`),
   sem commit; citado por caminho e seção, não por commit.
3. `docs/adr/0001-product-identity-and-presentations.md` — direção de domínio, status `accepted`
   desde 2026-10-01.

Nenhuma das três substitui a outra. Toda regra abaixo cita a fonte; adição sem fonte está marcada
`PROPOSTA`.

## Escopo

**Incluído:** as **8** categorias do PRD §6.2.2 — laticínios, carnes, mercearia, bebidas, hortifruti,
padaria, **limpeza** e **higiene**. As duas últimas entraram por decisão do Jonas em 2026-10-05
(D7, card `internal task`), que ratifica o review de domínio de 2026-10-03 e encerra o conflito com o
texto anterior de 6 categorias.

**Fora:** pet e demais categorias — ratificado pelo Jonas (2026-10-01; mantido na decisão de
2026-10-05). O schema já suporta a árvore de categorias (`categories.parent_id`), então acrescentar
categoria é dado, não migração — mas cada categoria nova exige lista de atributos e exemplos
validados, que são as seções de Limpeza e Higiene abaixo.

**Procedência dos exemplos dessas duas categorias:** `corpus` = par observado nas descrições do banco
canônico em 2026-10-05; `+ normalização` = a contraparte é a mesma linha com a abreviação expandida
(ADR-0002 §3); `R4`/`R5` = regra transversal já ratificada, aplicada a uma linha observada. Nenhum
par foi validado com nota nova ingerida.

**Depois:** algoritmo de matching, representação de recipiente/conteúdo, UX de revisão
(ADR-0001 §"Decisões de implementação ainda necessárias").

## Vocabulário de decisão

Todo par de descrições produz exatamente um dos três resultados:

- **MATCH** — mesmo produto canônico. Pode haver apresentações diferentes (tamanho, embalagem,
  multipack).
- **NÃO-MATCH** — produtos canônicos distintos, por diferença em atributo relevante.
- **PENDENTE** — informação insuficiente, contraditória ou ambígua. Nunca é promovido a MATCH
  por omissão (PRD §3.1 r.5; ADR-0001 r.5).

### Semântica de três estados por atributo

Cada atributo relevante de um produto está em um de três estados. A distinção é exigida pela
ADR-0001 (§"Decisões de implementação ainda necessárias", primeiro item):

| Estado | Significado | Efeito na comparação |
|---|---|---|
| **Conhecido** | A fonte informou o valor | Compara com o valor do candidato |
| **Desconhecido** | O atributo se aplica à categoria, mas a fonte não informou | PENDENTE |
| **Não se aplica** | A categoria não usa esse atributo para equivalência | Ignorado na comparação |

Consequência para a modelagem (entrada para internal task-A): **desconhecido é representado por
ausência de linha, não por linha vazia.** A linha em `product_attributes` existe apenas quando há
valor — o estado *conhecido* —, que é exatamente o que a constraint de exatamente-um valor exige
(XOR entre `value_text` e `value_boolean`). Os outros dois estados se leem no metadado de
categoria:

| Estado | Linha em `product_attributes` | Leitura |
|---|---|---|
| **Conhecido** | presente, com valor | compara com o candidato |
| **Desconhecido** | ausente, e o atributo **está declarado** para a categoria | ver abaixo |
| **Não se aplica** | ausente, e o atributo **não está declarado** para a categoria | ignorado |

O estado *desconhecido* não resolve sozinho o resultado da comparação — depende dos dois lados
(critério de aceite #12): ausente nos dois lados → não distinguível, decide-se pelos atributos
presentes; um lado informa e o outro não → PENDENTE; os dois informam e divergem → NÃO-MATCH.

Isso torna `category_attributes` **obrigatório para interpretar a ausência**: sem a lista de
atributos da categoria, *desconhecido* e *não se aplica* são indistinguíveis. Exige também que a
lista de uma categoria seja autoritativa — um atributo declarado que não se aplique a um produto
específico da categoria produz PENDENTE falso.

**`is_required` (04-A) — removido por ruling.** O arbitramento da coordenação (6ª rodada) decidiu:
**remover `is_required`**. Aplicabilidade vem de o atributo **existir** em `category_attributes`
para a categoria; um segundo flag criaria uma segunda fonte de verdade para o mesmo fato.
Referência: `db/001_schema.sql` regra 3.3 (um fato, um lugar).

Se `FALSE` significasse "declarado, mas a ausência não gera pendência", violaria a ADR-0001 r.5
(ausência não é evidência de igualdade) e contradiria a tabela acima. Aplicado o ruling: todo
atributo declarado para uma categoria participa da identidade, e ausência → PENDENTE, sem
exceção.

O caso que provavelmente motivou o flag é real, mas não é de categoria: `flavor` se aplica a bolo
e a iogurte, e não a pão francês nem a leite. É aplicabilidade **por produto**, não por categoria
— um flag no metadado de categoria não consegue expressá-la, e `FALSE` criaria falso MATCH por
omissão. Fica como ponto de modelagem aberto para 04-A.

## Regras transversais

**R1 — Produto canônico vs apresentação.** Produto canônico identifica o conteúdo e as
características relevantes à categoria. Apresentação identifica como ele é vendido: quantidade,
unidade, tipo de embalagem, configuração do pacote. (PRD §3.1)

**R2 — Diferença de conteúdo relevante separa produtos.** Marca e variante entram na análise
quando aplicáveis à categoria. Nome parecido, tamanho ou recipiente não bastam para estabelecer
equivalência. (ADR-0001 r.1)

**R3 — Características independentes são avaliadas em conjunto.** Em leite, teor de gordura e
condição de lactose são dimensões distintas: integral zero lactose não equivale a integral
convencional nem a desnatado zero lactose. (ADR-0001 r.2)

**R4 — Tamanho, embalagem e multipack não criam produto canônico.** São apresentação. A única
exceção é o caso nomeado do §9.4 (R8). (PRD §3.1 r.3)

**R5 — Marca.** `products.brand` é o armazenamento — coluna já existente no schema, única e
global. A marca **não** entra em `category_attributes` (sem duplicação de fato). O que varia por
categoria é a *aplicabilidade*:

- Marca aplicável e ausente na fonte → **desconhecido** → PENDENTE se o outro lado informar marca;
  ausente nos dois lados → não distinguível (critério #12). Ausência de marca não é evidência de
  igualdade (ADR-0001 r.5).
- Marca não aplicável à categoria → **não se aplica**. Não gera pendência.

A marca é não aplicável onde a categoria tolera produto sem marca: hortifruti (PRD §9.1) e
padaria (PRD §3.2 não lista marca entre os atributos; exemplo `PÃO FRANCÊS = PÃO FRANCÊS (se
mesmo tipo)`). A base de padaria é a lista de atributos da §3.2, **não** a §9.1 — a §9.1 nomeia
hortifruti.

**R6 — Conservação não distingue produto apenas em carnes.** Carne refrigerada e congelada não
são separadas por esse estado; a equivalência ainda exige espécie, corte, preparo e marca quando
aplicáveis. (ADR-0001 r.9) Nas demais categorias a conservação é **decisão aberta**: o matcher
não aplica regra alguma, e a ADR-0001 não generaliza o r.9.

**R7 — Peso efetivo variável não cria produto canônico.** Para carnes e hortifruti vendidos por
peso, porções de peso diferente são o mesmo produto; a quantidade efetivamente comprada entra na
comparação. (ADR-0001 r.10)

**R8 — Peso drenado: só o caso do PRD §9.4.** `ERVILHA 1KG` ≠ `ERVILHA 800G` → produtos distintos.
A regra vale por esse par, **não** pela categoria — a generalização para conserva como classe foi
rejeitada pelo Jonas (2026-10-01). Detalhamento em §"Lacunas fechadas".

**R9 — Informação insuficiente, contraditória ou ambígua → PENDENTE.** Inclui múltiplos
candidatos compatíveis. O sistema nunca força associação para produzir uma comparação. (PRD §3.1
r.5; ADR-0001 r.5)

**R10 — Diferença de atributo relevante → NÃO-MATCH**, mesmo com descrição textualmente
semelhante. Semelhança textual sugere candidatos, não confirma equivalência (ADR-0002 §3).

**R11 — Unidade de venda.** A unidade informada na linha orienta a interpretação de preço e
quantidade. `UN`/`un` e `KG`/`kg` não mudam a unidade. Outros rótulos (`CX`, `PC`, `PCT`, `SC`,
`LT`) exigem mapeamento confirmado — não se presume vocabulário idêntico entre emissores. A
descrição conter "1 kg" não decide entre venda por unidade e venda por peso. (ADR-0001 r.11)

## Categorias

Atributos marcados **[global]** vivem em `products` (R5). Os demais são atributos de conteúdo,
candidatos a `category_attributes` (internal task-A).

### Laticínios (leite, iogurte, queijo)

**Atributos relevantes:** marca **[global]**, `fat_content` (integral / semidesnatado /
desnatado), `lactose_free`, `flavor`. (PRD §3.2 e §4.2)

**Regras de ambiguidade:**
- Tipo (teor) ausente na fonte → PENDENTE. Não assumir integral como padrão.
- `light` em laticínio pode significar redução de gordura ou de açúcar → PENDENTE sem
  detalhamento.

**Exemplos:**

| # | Par | Resultado | Base |
|---|---|---|---|
| 1 | `LEITE UHT INTEGRAL 1L` ≡ `LEITE UHT INTEGRAL CX 12UN` | MATCH | PRD §3.2 |
| 2 | `LEITE UHT HERC INTEGRAL 1L` ≡ `LEITE INTEGRAL HERC 1L` | MATCH | mesmo conteúdo; ordem das palavras |
| 3 | `IOGURTE NATURAL DANONE 170G` ≡ `IOGURTE NATURAL DANONE 850G` | MATCH | R4 — tamanho é apresentação |
| 4 | `LEITE UHT INTEGRAL` ≠ `LEITE UHT DESNATADO` | NÃO-MATCH | PRD §3.2 |
| 5 | `LEITE UHT INTEGRAL` ≠ `LEITE UHT INTEGRAL ZERO LACTOSE` | NÃO-MATCH | PRD §3.2; R3 |
| 6 | `LEITE ITAMBÉ INTEGRAL 1L` ≠ `LEITE HERC INTEGRAL 1L` | NÃO-MATCH | R2 — marca aplicável |
| 7 | `LEITE UHT 1L` | PENDENTE | tipo ausente |

### Carnes

**Atributos relevantes:** `species`, `cut`, `seasoning` (com/sem tempero), marca **[global]**.
(PRD §3.2 e §4.2)

**Regras de ambiguidade:**
- Espécie ausente → PENDENTE.
- Preparo (temperado vs. in natura) difere → NÃO-MATCH, não é só conservação (ADR-0001 r.9).
- Conservação (refrigerado/congelado) **não** distingue (R6).
- Peso variável não cria produto (R7); registrar quantidade efetiva.

**Exemplos:**

| # | Par | Resultado | Base |
|---|---|---|---|
| 1 | `COXA DE FRANGO` ≡ `COXA FRANGO` | MATCH | PRD §3.2 |
| 2 | `PATINHO BOVINO REFRIGERADO 1KG` ≡ `PATINHO BOVINO CONGELADO 1KG` | MATCH | ADR-0001 r.9; R6 |
| 3 | `COXA DE FRANGO SWIFT 1KG` ≡ `COXA DE FRANGO SWIFT 500G` | MATCH | R4 |
| 4 | `CUPIM COMBO` ≠ `CUPIM` | NÃO-MATCH | PRD §3.2 |
| 5 | `CARNE MOIDA` ≠ `CARNE MOIDA COMBO` | NÃO-MATCH | PRD §3.2 |
| 6 | `ALCATRA BOVINA` ≠ `PATINHO BOVINO` | NÃO-MATCH | `cut` |
| 7 | `COXA DE FRANGO TEMPERADA` ≠ `COXA DE FRANGO` | NÃO-MATCH | `seasoning` |
| 8 | `CARNE MOIDA 1KG` | PENDENTE | espécie ausente |

### Mercearia (enlatados, massas, etc.)

**Atributos relevantes:** marca **[global]**, `product_type`, `flavor`, `variant`. (PRD §3.2 e
§4.2)

**Regras de ambiguidade:**
- Tipo de produto difere (`EXTRATO DE TOMATE` vs `MOLHO DE TOMATE` vs `TOMATE PELADO`) →
  NÃO-MATCH. Compartilhar ingrediente não estabelece equivalência (ADR-0001 §Exemplos).
- Tipo ausente → PENDENTE.
- Recipiente (lata, sachê, caixa, vidro) **não** distingue: é apresentação (R4).
- Peso declarado diferente **não** distingue por si só — conserva não é classe especial (decisão
  do Jonas, 2026-10-01). A exceção é o caso nomeado do PRD §9.4: `ERVILHA 1KG` ≠ `ERVILHA 800G`
  (R8; exemplo #9).

**Exemplos:**

| # | Par | Resultado | Base |
|---|---|---|---|
| 1 | `EXTRATO DE TOMATE ELEFANTE 340G` ≡ `EXTRATO DE TOMATE ELEFANTE SACHÊ 340G` | MATCH | PRD §3.2 (mesma marca e formulação) |
| 2 | `FEIJAO CARIOCA CAMIL 1KG` ≡ `FEIJAO CARIOCA CAMIL 500G` | MATCH | R4 |
| 3 | `MACARRAO ESPAGUETE BARILLA 500G` ≡ `MACARRAO ESPAGUETE BARILLA 1KG` | MATCH | R4 |
| 4 | `EXTRATO DE TOMATE` ≠ `MOLHO DE TOMATE` | NÃO-MATCH | PRD §3.2 |
| 5 | `EXTRATO DE TOMATE` ≠ `TOMATE PELADO` | NÃO-MATCH | PRD §3.2 |
| 6 | `ARROZ BRANCO CAMIL 5KG` ≠ `ARROZ INTEGRAL CAMIL 5KG` | NÃO-MATCH | `variant` |
| 7 | `MOLHO DE TOMATE QUERO` ≠ `MOLHO DE TOMATE ELEFANTE` | NÃO-MATCH | R5 — marca aplicável |
| 8 | `ARROZ 5KG` | PENDENTE | tipo ausente |
| 9 | `ERVILHA 1KG` ≠ `ERVILHA 800G` | NÃO-MATCH | PRD §9.4; R8 — caso nomeado, não se generaliza para conserva |
| 10 | `EXTRATO DE TOMATE 340G` | PENDENTE | marca e formulação ausentes — a §3.2 condiciona o agrupamento a "mesma marca e formulação" |
| 11 | `MILHO VERDE 1KG` ≡ `MILHO VERDE 800G` | MATCH | R4 — generalização rejeitada pelo Jonas (2026-10-01); peso é apresentação |

### Bebidas

**Atributos relevantes:** marca **[global]**, `type`, `flavor`. (PRD §3.2 e §4.2)

**Regras de ambiguidade:**
- Tipo ou sabor ausente → PENDENTE.
- Tipo de embalagem (lata, garrafa, vidro) e tamanho **não** distinguem (R4).
- Variação de grafia do mesmo nome (`COCA COLA` / `COCA-COLA`) não é diferença de conteúdo
  (ADR-0002 §3 — normalização).

**Exemplos:**

| # | Par | Resultado | Base |
|---|---|---|---|
| 1 | `COCA COLA 2L` ≡ `COCA-COLA 2L` | MATCH | PRD §3.2 |
| 2 | `COCA COLA 2L` ≡ `COCA COLA 350ML` | MATCH | R4 |
| 3 | `SUCO DE LARANJA DEL VALLE 1L` ≡ `SUCO DE LARANJA DEL VALLE 500ML` | MATCH | R4 |
| 4 | `COCA COLA 2L` ≠ `COCA COLA ZERO 2L` | NÃO-MATCH | PRD §3.2 |
| 5 | `SUCO DE LARANJA` ≠ `SUCO DE UVA` | NÃO-MATCH | `flavor` |
| 6 | `COCA COLA 2L` ≠ `PEPSI 2L` | NÃO-MATCH | R5 — marca aplicável |
| 7 | `REFRIGERANTE 2L` | PENDENTE | tipo e marca ausentes |

### Hortifruti

**Atributos relevantes:** `variety`; marca **[global, quando aplicável]**. (PRD §3.2)

**Regras de ambiguidade:**
- Variedade ausente → PENDENTE.
- Marca ausente → **não se aplica** (PRD §9.1), não gera pendência (R5).
- Peso variável não cria produto (R7); venda por `KG` ou por `UN` é apresentação (R11).

**Exemplos:**

| # | Par | Resultado | Base |
|---|---|---|---|
| 1 | `BANANA PRATA 1KG` ≡ `BANANA PRATA 500G` | MATCH | R4 |
| 2 | `BANANA PRATA` ≡ `BANANA PRATA KG` | MATCH | R11 — unidade de venda é apresentação |
| 3 | `TOMATE ITALIANO 1KG` ≡ `TOMATE ITALIANO 500G` | MATCH | R4 |
| 4 | `BANANA PRATA` ≠ `BANANA NANICA` | NÃO-MATCH | PRD §3.2 |
| 5 | `TOMATE ITALIANO` ≠ `TOMATE CEREJA` | NÃO-MATCH | `variety` |
| 6 | `MACA FUJI` ≠ `MACA GALA` | NÃO-MATCH | `variety` |
| 7 | `ALFACE 1UN` | PENDENTE | variedade ausente |

### Padaria

**Atributos relevantes:** `type`, `flavor`. (PRD §3.2 e §4.2)

**Nota:** o PRD §4.2 lista apenas `type` e `flavor` para padaria, mas o §3.2 traz o exemplo
`PÃO FRANCÊS = PÃO FRANCÊS (se mesmo tipo)` e o PRD não oferece atributo para a distinção
integral/branco. **`formulation` não está na lista acima** porque não é rastreável a §3.2/§4.2
(critério de aceite #1). A distinção integral/branco aparece no exemplo #4 marcada `PROPOSTA` e
nas adições propostas (an earlier PR). Enquanto não for decidida, o exemplo #4 é ilustrativo, não
especificação.

**Regras de ambiguidade:**
- Tipo ausente → PENDENTE.
- Marca não está na lista da §3.2 → **não se aplica** (R5). Ausência de marca não gera
  pendência nem impede MATCH.
- Conservação (fresco / congelado / embalado) é **decisão aberta** — o ADR-0001 r.9 é restrito a
  carnes (R6). O matcher não aplica regra.

**Exemplos:**

| # | Par | Resultado | Base |
|---|---|---|---|
| 1 | `PAO FRANCES` ≡ `PAO FRANCES` | MATCH | PRD §3.2 (mesmo tipo) |
| 2 | `PAO DE FORMA INTEGRAL 400G` ≡ `PAO DE FORMA INTEGRAL 500G` | MATCH | R4 |
| 3 | `BOLO DE CHOCOLATE 400G` ≡ `BOLO DE CHOCOLATE 300G` | MATCH | R4 — mesmo tipo e sabor |
| 4 | `PAO DE FORMA INTEGRAL` ≠ `PAO DE FORMA BRANCO` | NÃO-MATCH | `formulation` — `PROPOSTA` |
| 5 | `BOLO DE CHOCOLATE` ≠ `BOLO DE LARANJA` | NÃO-MATCH | `flavor` |
| 6 | `PAO FRANCES` ≠ `PAO DE QUEIJO` | NÃO-MATCH | `type` |
| 7 | `PAO 1UN` | PENDENTE | tipo ausente |

### Limpeza (limpeza e cuidado doméstico)

**Atributos relevantes:** marca **[global]**, `product_type`, `variant`. (D7, 2026-10-05)

**Fronteira de classificação (2026-10-03):** repelente de ambiente — inclusive de tomada — e
odorizador de ambiente são Limpeza; repelente corporal é Higiene.

**Regras de ambiguidade:**
- Tipo de produto ausente ou não resolvido na descrição → PENDENTE.
- Tamanho, recipiente e refil **não** distinguem (R4).
- Marca é aplicável (o corpus traz marca em praticamente toda linha) → ausente = desconhecido (R5).
- Descrição que não resolve a própria categoria — `ALCOOL COOPER 1L CLA` (álcool doméstico × álcool de
  uso pessoal) — fica PENDENTE de classificação; a identidade não decide isso.

**Exemplos:**

| # | Par | Resultado | Base |
|---|---|---|---|
| 1 | `DESTAC 750ML MADEIRA` ≡ `DESTAC MADEIRAS 750` | MATCH | corpus — mesmo produto; ordem das palavras e abreviação |
| 2 | `LIMPADOR AZULIM PISOS LAMIN.750ml` ≡ `LIMPADOR AZULIM PISOS LAMINADOS 750ML` | MATCH | corpus + normalização |
| 3 | `DET LIMPOL 500ML COC` ≠ `DET LIMPOL 500ML CRI` | NÃO-MATCH | corpus — `variant` |
| 4 | `AGUA SAN CANDIDA 2L` ≠ `AGUA SANI SUPREMA 2L` | NÃO-MATCH | corpus — R5 |
| 5 | `LIMPADOR AZULIM PISOS LAMIN.750ml` ≠ `LIMPADOR VEJA M.USO GOLD EMB.ECON.750ml` | NÃO-MATCH | corpus — `product_type` + R5 |
| 6 | `AMAC DOWNY 1L BRISA` ≠ `AMAC VIDA MACIA 1L G` | NÃO-MATCH | corpus — R5 |
| 7 | `LIMPADOR AZULIM PISOS LAMIN.750ml` ≡ `LIMPADOR AZULIM PISOS LAMIN.500ml` | MATCH | R4 — tamanho é apresentação |
| 8 | `ALCOOL COOPER 1L CLA` | PENDENTE | corpus — categoria e tipo não resolvidos |
| 9 | `PROT WYDA MOL 27X27` | PENDENTE | corpus — `product_type` ausente |

### Higiene (higiene pessoal e cuidados corporais)

**Atributos relevantes:** marca **[global]**, `product_type`, `variant`. (D7, 2026-10-05)

**Regras de ambiguidade:**
- Tipo ausente ou não resolvido → PENDENTE.
- Tamanho e multipack **não** distinguem (R4/R11): `… 12un` é apresentação.
- Papel higiênico é Higiene; papel-toalha e guardanapo de cozinha são cuidado doméstico, **não**
  Higiene — e hoje ficam fora das 8 categorias.
- Marca é aplicável (Mili, Snob, Nivea, Protex, Colgate, Pantene, Granado observados) → ausente =
  desconhecido (R5).

**Exemplos:**

| # | Par | Resultado | Base |
|---|---|---|---|
| 1 | `SAB NIVEA CACAU E JA` ≠ `SAB NIVEA KARIT E L.` | NÃO-MATCH | corpus — `variant` |
| 2 | `SAB GRANADO BE 90G E` ≡ `SABONETE GRANADO BEBÊ 90G` | MATCH | corpus + normalização |
| 3 | `PAPEL HIG.MILI NEUTRO F.D.30m 12un` ≡ `PAPEL HIGIÊNICO MILI NEUTRO FOLHA DUPLA 30M` | MATCH | corpus + normalização; multipack é apresentação (R4) |
| 4 | `SAB PROTEX 85G MACAD` ≠ `SAB GRANADO BE 90G E` | NÃO-MATCH | corpus — R5 |
| 5 | `CR DEN COLG 90G` ≠ `SH PANT 400ML BAMBU` | NÃO-MATCH | corpus — `product_type` |
| 6 | `CR DEN COLG 90G` ≡ `CREME DENTAL COLGATE 90G` | MATCH | corpus + normalização |
| 7 | `TOALHA HIP SNOB C/3R` | PENDENTE | corpus — "HIP" não resolve papel higiênico × papel-toalha |
| 8 | `HIDROST BLISTER 50ML` | PENDENTE | corpus — `product_type` ausente |

## Lacunas fechadas

A ADR-0001 (linha 48) exige critério próprio para peso drenado, peso variável e venda por
contagem antes de qualquer comparação. Os três estão abaixo.

### Peso variável

Carnes e hortifruti vendidos por peso: porções de peso efetivo diferente são o **mesmo produto
canônico**. A quantidade efetivamente comprada entra na comparação em `G`. Embalagem e peso de
cada porção não substituem os critérios de identidade. (ADR-0001 r.10; R7)

`PATINHO BOVINO 1,2KG` ≡ `PATINHO BOVINO 0,8KG` → MATCH.

### Peso drenado

**Decisão do PRD §9.4:** `ERVILHA 1KG` ≠ `ERVILHA 800G` → produtos distintos, porque a diferença
de peso é relevante ao consumidor (bruto vs. drenado).

**Alcance ratificado pelo Jonas (2026-10-01): a regra não se generaliza para o subgrupo conserva.**
Fica restrita ao caso do PRD.

| Situação | Resultado | Base |
|---|---|---|
| O par do §9.4, `ERVILHA 1KG` ≠ `ERVILHA 800G` | **NÃO-MATCH** | PRD §9.4 |
| Demais conservas (milho, atum, sardinha, azeitona, palmito) com peso declarado diferente | **MATCH** — apresentações do mesmo produto | PRD §3.1 r.3; R4 |
| Apenas um lado da comparação informa que o peso é drenado | **PENDENTE** | R9 |

**Entrada para internal task-A:** o comportamento está atado a um caso nomeado, não a uma classe de
categoria nem a um valor por produto. Não cabe em `product_attributes` (EAV de valores) — exige
representação própria, a ser definida.

### Venda por contagem

Comparação na unidade-base `UN` (enum `base_unit`, `db/001_schema.sql`). Multipack: o conteúdo é
N × unidades internas — `CX 12UN` → 12 unidades (PRD §9.3). Preço unitário sempre re-expresso em
unidade-base antes de comparar (regra 2 do schema).

`PROPOSTA`: `CX`, `PC`, `PCT`, `SC`, `LT` exigem mapeamento confirmado, por emissor, sem
presumir vocabulário comum (ADR-0001 r.11). Até o mapeamento existir, a unidade de venda
desconhecida mantém a linha PENDENTE para fins de comparação.

## Adições propostas (não grounded)

Regras plausíveis que **não** estão na ADR-0001 nem no PRD. Afirmar equivalência é decisão, não
derivação (ADR-0001 r.5). Todas exigem decisão explícita:

1. `zero lactose` ≡ `sem lactose` — vocabulário do emissor. A ADR-0001 r.11 diz que não se
   presume vocabulário idêntico. Caminho alternativo: sinônimo com escopo (PRD §9.2), não regra
   de identidade.
2. `zero` ≡ `sem açúcar` — mesma objeção.
3. `teor alcoólico` como atributo de bebidas — não consta em §3.2 nem §4.2.
4. "cerveja sem tipo (pilsen/lager/IPA) → PENDENTE" — não grounded.
5. `TOMATE ORGANICO` ≠ `TOMATE CONVENCIONAL` — origem não consta na §3.2. Sem evidência nas 3
   NFC-e / 42 itens; orgânico tende a ter EAN/PLU próprio.
6. Generalização do peso drenado para todo o subgrupo conserva (ver §"Lacunas fechadas").
   **Rejeitada pelo Jonas (2026-10-01)** — mantida aqui como registro da alternativa descartada.
7. Mapeamento de `CX`/`PC`/`PCT`/`SC`/`LT` por emissor (ver §"Lacunas fechadas").
8. `formulation` (integral/branco) como atributo de padaria — o PRD §4.2 lista apenas `type` e
   `flavor`, mas o §3.2 usa a distinção no exemplo do pão de forma.
9. Aplicabilidade por produto (ex.: `flavor` vale para bolo e iogurte, não para pão francês) —
   não cabe em flag de categoria (ver §"Semântica de três estados").

## Decisões ratificadas pelo Jonas (2026-10-01)

Registradas na thread do `#operacao`. Substituem as pendências correspondentes.

1. **Escopo** — ~~manter as 6 categorias. Limpeza, higiene e pet ficam fora deste ciclo.~~
   **Substituída em 2026-10-05 (D7, card `internal task`):** o escopo passa a **8 categorias**, com
   **Limpeza** e **Higiene** dentro; pet segue fora. O item original fica registrado apontando a
   decisão sucessora.
2. **Conservação fora de carnes** — restrita a carnes. Não se generaliza.
3. **Origem em hortifruti** — não adotar `orgânico ≠ convencional`.
4. **Equivalências de rótulo** — `zero lactose` ≡ `sem lactose` fica PENDENTE; é sinônimo com
   escopo (PRD §9.2), não regra de identidade.
5. **Peso drenado** — só o caso do PRD §9.4 (`ERVILHA 1KG` ≠ `ERVILHA 800G`). Generalização para
   enlatado **rejeitada**. Consequência aceita pelo Jonas: milho, atum, sardinha, azeitona e
   palmito com peso declarado diferente caem na regra 6 (peso é apresentação → MATCH).

## Decisões ainda pendentes

1. **Versionamento** — `PRD.md`, este spec, `docs/DECISIONS.md` e `docs/adr/0001-…md` estão
   **staged** (`git add` executado pela coordenação), **sem commit**. HEAD segue em `001f798`.
   Nenhum `commit`/`push` foi feito. O produto não executa `git add`/`commit`/`push` sem ordem
   explícita; o commit é ação da coordenação.

Sem outra pendência de decisão de produto. Os itens abaixo são de modelagem técnica (internal task-A)
ou de desenho de interface (internal task-B), não de produto:

- `formulation` em padaria — atributo novo, ou integral/branco como `type` distinto (adição
  proposta #8). Não bloqueia: os atributos de padaria ficam em `type`, `flavor`.
- Aplicabilidade por produto (ex.: `flavor` vale para bolo e iogurte, não para pão francês) —
  adição proposta #9.
- Representação do comportamento de peso drenado (caso nomeado, não classe de categoria).

Conflitos 04 ↔ 04-A encerrados por ruling da coordenação (6ª rodada): `brand` fora do EAV;
desconhecido = ausência de linha, com o XOR de 04-A mantido; `is_required` removido.

## Critérios de aceite

1. Cada categoria tem lista de atributos rastreável a PRD §3.2/§4.2, com a fonte citada.
2. Cada categoria tem ≥3 MATCH, ≥3 NÃO-MATCH e ≥1 PENDENTE, consistentes com os atributos
   declarados.
3. Nenhuma regra de equivalência afirmada sem fonte; adições marcadas `PROPOSTA`.
4. Conservação não distingue produto **apenas em carnes** (ADR-0001 r.9); nas demais categorias é
   decisão aberta e o matcher não aplica.
5. Marca é armazenada em `products.brand` e **não** em `category_attributes`. "Não se aplica"
   decorre de a categoria tolerar produto sem marca (hortifruti — PRD §9.1; padaria — PRD §3.2),
   não da ausência de marca na lista de atributos. Onde a marca é aplicável e está ausente → 
   desconhecido, tratado pelo critério #12 (ADR-0001 r.5).
6. Tamanho, embalagem e multipack não criam produto canônico — são apresentação (PRD §3.1 r.3).
7. Peso efetivo variável (carnes/hortifruti por peso) não cria produto canônico (ADR-0001 r.10);
   a quantidade efetiva é registrada para comparação.
8. `ERVILHA 1KG` ≠ `ERVILHA 800G` → produtos distintos (PRD §9.4). A regra vale pela informação
   declarada na linha, não pela categoria — **não se generaliza para conserva como classe**
   (decisão do Jonas, 2026-10-01). Milho, atum, sardinha, azeitona e palmito com peso declarado
   diferente caem na regra 6 (peso é apresentação → MATCH).
9. Informação insuficiente ou ambígua → PENDENTE (PRD §3.1 r.5; ADR-0001 r.5).
10. Diferença de atributo relevante → NÃO-MATCH, mesmo com descrição textualmente semelhante.
11. Cada linha das tabelas de exemplos é um caso de teste objetivo: par de descrições →
    MATCH | NÃO-MATCH | PENDENTE.
12. Todo atributo declarado para uma categoria participa da identidade. O tratamento da ausência
    de valor distingue três casos:
    - **ausente nos dois lados**, sem informação que os distinga → **não distinguível**; não gera
      pendência, e a identidade se decide pelos atributos presentes;
    - **um lado informa e o outro não** → **PENDENTE**;
    - **os dois informam e divergem** → **NÃO-MATCH**.
    Não existe atributo declarado não obrigatório.
13. Os três estados (conhecido / desconhecido / não se aplica) são distinguíveis com os dados
    propostos: conhecido = linha com valor; desconhecido e não se aplica = ausência de linha,
    separados pela lista de atributos da categoria.
14. Ausência bilateral de um atributo declarado não derruba MATCH: descrições curtas de cupom, em
    que nenhum dos lados traz o atributo, continuam comparáveis pelos atributos presentes
    (critério #12, primeiro caso).

## Nota de implementação

Nenhum código de matching existe (`PRD.md` §1.1). As tabelas de exemplos deste documento são o
conjunto inicial de casos de teste da camada 4 (`PRD.md` §3.3), a serem versionados em `tests/`
quando houver plano aprovado. Nada aqui altera `db/001_schema.sql`, `db/002_schema.sql`, os
testes existentes ou os dados.
