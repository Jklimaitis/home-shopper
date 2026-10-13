---
title: UX da tela de revisão de pendências
project: home_shopper
status: proposed
created: 2026-10-01
task: internal task-B
---

# UX da tela de revisão de pendências

## Estado do documento

Especificação proposta para revisão. **Não autoriza implementação nem alteração de schema.**
Substitui a proposta discutida em thread no `#operacao` (rodada 1). Onde houver divergência entre
este arquivo e a thread, este arquivo prevalece.

Rodada 2 — corrige as 4 observações da auditoria da coordenação.

## Fontes canônicas, em ordem

1. `db/001_schema.sql`, `db/002_schema.sql`, `db/004_indexes_views.sql` — o que existe hoje.
2. `PRD.md` §6.1, §6.3, §3.4, §8 — o que a tela precisa entregar.
3. `docs/adr/0001-product-identity-and-presentations.md` r.5 — ambiguidade → revisão humana.
4. `docs/adr/0002-association-review-and-consolidation.md` — fluxo de revisão e consolidação parcial.
5. `docs/adr/0004-shared-catalogue-and-data-isolation.md` — o que é compartilhado e o que é isolado.

Toda afirmação abaixo cita a fonte. Sem fonte, está marcado `PROPOSTA`.

## Correções aplicadas nesta rodada

| Observação da auditoria | Correção |
|---|---|
| 1. Tokens `ds-*` não existem no repo | §8: a camada de tokens **não existe** neste projeto. Verificado: zero `.html`, `.css`, `.js` em `home_shopper`. Nomes `ds-*` foram **removidos** do documento; no lugar, papéis semânticos. O token layer passa a ser entregável, não premissa. |
| 2. "Criar novo produto" contradiz o escopo | Ação **removida**. §5 lista as ações que existem; criação de produto não é uma delas. |
| 3. Destino da decisão não definido | §5: a tela grava **apenas no nível da linha** (`staging_lines`). Promoção a associação reutilizável é dependência explícita da ADR-0002 e da ADR-0004, não comportamento da tela. |
| 4. Contraste WCAG não verificável | §7 separa **critério testável hoje** de **critério não verificável até existir token**. Não se afirma conformidade AA. |

## Correções da rodada 3

| Achado da auditoria (rodada 2) | Correção |
|---|---|
| §5 afirmava "pular" como comportamento estável; `v_review_queue` faz a linha voltar à fila | §5: nova coluna "Sai da fila?" e seção "Pular não é estável" com a expressão literal da view; §3 e §9 ajustados |
| Achado da §6 (usar `discarded` mudaria o total) | Confirmado com o trecho do trigger; §6 ampliada para cobrir também "pulada" e com encaminhamento formal ao 04-A |

## Escopo

**Incluído:** tela de revisão de linhas pendentes de identificação — entrada pela fila, decisão por
linha, registro da decisão.

**Fora:** criação de produto, criação de apresentação no catálogo global, promoção de revisão a
alias reutilizável, edição de atributos do candidato, exclusão de item da comparação, tela de
confirmação da nota (PRD §6.2), relatórios de cobertura (PRD §6.3).

Motivo das exclusões: ADR-0002 §"Pontos pendentes de revisão" — "autorização para transformar uma
revisão em associação reutilizável" está em aberto; ADR-0004 §"O que este documento não decide" —
"autorização e escopo de escrita no catálogo global" está em aberto. Nenhuma das duas autoriza a
tela a escrever no catálogo compartilhado.

---

## 1. Ponto de entrada — a fila já existe

`v_review_queue` (`db/004_indexes_views.sql`) é a entrada da tela. Ela é **por nota**, não por
linha, e já traz o que a triagem precisa:

| Coluna da view | Uso na tela |
|---|---|
| `store_name` | identificar a nota |
| `total_gross`, `amount_paid`, `total_computed` | contexto da nota |
| `divergence_cents` | **ordenar** — a view já ordena por `abs(divergence_cents) DESC NULLS LAST` |
| `unmatched_lines` | quantas linhas sem produto |
| `lines_to_review` | quantas linhas não revisadas |
| `total_lines` | denominador do progresso |
| `status` | `PENDING` / `IN_REVIEW` — só essas entram |

A view filtra `status IN ('PENDING','IN_REVIEW')` e usa `LEFT JOIN` em `staging_lines` de propósito:
nota sem linhas nenhuma precisa aparecer. A tela herda essa ordem — divergência de total antes de
nome faltando — porque uma nota com soma errada é mais grave que uma linha sem nome.

**Consequência de desenho:** o fluxo tem **dois níveis**. A tela de linha (§4) não é a porta de
entrada; ela é alcançada a partir da nota.

## 2. O que existe hoje no nível da linha

`staging_lines` (`db/002_schema.sql`) oferece, por linha:

- `description_raw` — a descrição como veio do cupom. É o que o usuário precisa ler para decidir.
  O comentário da view registra por quê: "Without them the review screen showed a NULL and the user
  had no way to decide what to match."
- `store_code` — código interno do emissor. Auxílio de leitura; quando validado por GS1 é candidato revisável de vínculo, nunca descarte nem confirmação — segue pendente de revisão humana.
- `sale_unit` — unidade como impressa (`UN`, `PC`, `KG`, `CX`).
- `quantity`, `unit_price`, `line_total`, `discount_line` — valores originais.
- `product_id`, `presentation_id` — o vínculo, quando existe.
- `match_source` — enum `('BARCODE','DESCRIPTION','ALIAS','MANUAL','NONE')`. **`MANUAL` é o valor
  que a tela grava.**
- `match_note` — trilha de auditoria: por que casou, ou por que não.
- `reviewed`, `discarded` — estado de revisão.
- FK composta `(presentation_id, product_id) → presentations(id, product_id)` — o banco garante que
  a apresentação pertence ao produto declarado. A tela não pode gravar par incoerente; se tentar, o
  banco rejeita.

### O que não existe

**Não há tabela de candidatos sugeridos.** A linha guarda o vínculo final, não as opções avaliadas.
Os candidatos são calculados em tempo de leitura pela camada 3–4 do matcher (PRD §3.3) e
**não são persistidos** enquanto o usuário não decide. Nenhum estado de "sugestão" é gravado.

**Não há consulta de linha por nota.** `v_review_queue` agrega por nota e não expõe a lista de
linhas. A tela precisa de uma consulta nova (linhas de uma nota, com `description_raw`, valores,
`match_source` e `reviewed`). Isso é trabalho de leitura, não de schema — mas é dependência, não
detalhe.

**Isolamento por `user_id`.** ADR-0004 §1 exige que toda consulta de negócio filtre por `user_id`.
`v_review_queue` **expõe** `user_id` como coluna; o filtro é responsabilidade de quem consulta. A
consulta nova da tela precisa do mesmo filtro, e a ADR-0004 §"Consequências" nomeia esse como o
risco real do projeto: "Uma view nova sem essa coluna reintroduz o vazamento."

## 3. Fluxo

```
v_review_queue (notas)
  │  ordenadas por |divergence_cents| DESC, depois unmatched_lines DESC
  │
  ├─ nota com linhas_to_review = 0 ──────────► nada a fazer aqui
  │
  └─ nota com pendências
        │
        ▼
   linhas da nota (description_raw, valores, match_source, reviewed)
        │
        ▼
   ┌──────────────────────────────────────────┐
   │  LINHA PENDENTE                          │
   │  ─────────────────────────────────────   │
   │  Motivo da pendência                     │
   │  Candidatos (calculados, não gravados)   │
   │                                          │
   │  [selecionar candidato] → Confirmar      │
   │  [não é nenhum]                          │
   │  [pular]                                 │
   └──────────────────────────────────────────┘
        │
        ├─ confirmar ──► grava vínculo na linha, avança
        ├─ não é nenhum ► grava ausência de vínculo revisada, avança
        └─ pular ──────► nada gravado, avança
```

Regra que a ADR-0001 r.5 e o PRD §8 #10 exigem, e que vale repetir: **resolver uma linha nunca
bloqueia as demais da mesma nota.** A ADR-0002 §"Consolidação parcial recomendada" é explícita:
"Dúvidas locais de identificação não bloqueiam linhas independentes já resolvidas." Pular é uma
ação de primeira classe, não uma saída de emergência — mas é **adiamento, não decisão**: a linha
volta à fila na próxima abertura (§5).

## 4. Tela de linha — componentes

Um card por vez, não uma tabela. Cada card responde três perguntas: o que veio do cupom, por que
está pendente, e quais são as opções.

**Cabeçalho da nota** (fixo no topo)
- `store_name`, contagem `lines_to_review` de `total_lines`, `divergence_cents` quando ≠ 0.

**Descrição de origem**
- `description_raw`, sem alteração — a ADR-0002 §2 exige preservar a descrição original.
- `sale_unit`, `quantity`, `unit_price`, `line_total` como vieram da fonte.
- `store_code` quando presente, rotulado como código da loja — evidência, não identificador
  (ADR-0001 r.6).

**Motivo da pendência**
- Texto derivado do resultado do matcher. Casos que a especificação por categoria produz
  (`docs/superpowers/specs/2026-10-01-product-equivalence-by-category.md`):
  - atributo declarado para a categoria ausente de um lado e presente no outro → PENDENTE
    (critério #12);
  - múltiplos candidatos compatíveis (PRD §3.3 camada 5);
  - nenhum candidato encontrado (PRD §3.3 camada 5).
- A razão precisa ser legível: o critério #12 daquela spec é o caso mais frequente e o menos óbvio
  — "a variante não foi informada nesta linha" é acionável; "match ambíguo" não é.

**Candidatos**
- Lista selecionável, comportamento de radio.
- Cada candidato mostra os atributos **declarados para a categoria** daquele produto, com o estado
  de cada um: coincide / diverge / não informado.
- O estado não é comunicado **apenas** por cor: cada estado (coincide / diverge / não informado) tem
  rótulo textual e ícone próprios, válidos em qualquer paleta futura (ADR-0001 r.5 — ausência não é
  evidência de igualdade, e a tela não pode sugerir o contrário).
- Diferenças ficam visíveis. Esconder a divergência para reduzir ruído empurraria o usuário para o
  falso positivo, que a ADR-0002 §"Alternativas" lista como o erro caro.

**Ações** — exatamente três (§5).

## 5. Ações e destino da decisão

| Ação | O que grava | Onde | Sai da fila? |
|---|---|---|---|
| **Confirmar seleção** | `product_id`, `presentation_id`, `match_source='MANUAL'`, `reviewed=TRUE`, `match_note` com o motivo | `staging_lines` | sim |
| **Não é nenhum** | `reviewed=TRUE`, sem vínculo, `match_note` registrando a decisão | `staging_lines` (ver §6) | sim |
| **Pular** | **nada** | — | **não** |

Habilitado/desabilitado: "Confirmar seleção" só habilita com candidato selecionado. "Não é nenhum"
pede confirmação inline — é afirmação forte, e o par `presentation_id`/`product_id` tem FK composta;
gravar errado é pior que perguntar.

### Pular não é estável — a linha volta à fila

`v_review_queue` (`db/004_indexes_views.sql`) calcula:

```
count(sl.id) FILTER (WHERE NOT sl.reviewed AND NOT sl.discarded) AS lines_to_review
```

Pular não grava nada, então a linha continua `reviewed = FALSE` e **reaparece na fila em toda
reabertura da nota** — enquanto a nota seguir em `status IN ('PENDING','IN_REVIEW')`. Isso é
intencional, não defeito: a ADR-0002 §"Fluxo recomendado" exige "Permitir salvar o progresso e
retomar a revisão", e uma pendência não resolvida precisa continuar visível. Mas a tela não pode
apresentar "pular" como se encerrasse a linha.

Consequências que a tela assume:

- "Pular" é adiamento, não decisão. O rótulo e o estado do card precisam deixar isso claro.
- Não há contador de "puladas" que sobreviva à sessão — sem gravação, não há registro. Se o produto
  quiser distinguir "nunca vista" de "vista e adiada", isso exige representação própria (§6) e não
  pode ser simulado na interface.
- A nota não fica "concluída" com linhas puladas: `lines_to_review` continua > 0, o que está correto
  pela ADR-0002 §"Consolidação parcial" — "Não chamar de concluída uma nota com pendências".


### O que a tela não decide

**A tela grava no nível da linha. Só.** `staging_lines` pertence a uma nota, e `staging_receipts`
tem `user_id` — o vínculo é dado isolado do usuário.

O catálogo é outra história. `presentations` **não tem `user_id`** (ADR-0004 §1): é compartilhado
por todos. Pela própria definição do schema, "a presentation links FULL DESCRIPTION → PRODUCT" — ou
seja, transformar uma confirmação manual em apresentação reutilizável é **escrever no catálogo
compartilhado**, e isso afeta a comparação de todos os outros usuários.

Essa escrita não é autorizada por nenhuma decisão vigente:

- ADR-0002 §"Pontos pendentes": "Definir escopo, manutenção e revogação de aliases; autorização para
  transformar uma revisão em associação reutilizável; comportamento diante de conflitos."
- ADR-0004 §"O que este documento não decide": "Autorização e escopo de escrita no catálogo global:
  quem pode criar produto, apresentação ou sinônimo, e se a criação por um usuário é aceita por todos
  os outros."

Portanto: **a tela registra a decisão; ela não promove a decisão a associação reutilizável.** A
promoção é ação separada, posterior, e depende dessas duas ADRs. Fica como dependência explícita,
não como resolvido.

## 6. Lacuna de schema — duas decisões sem representação própria

Medido nos arquivos, não suposto. Em `staging_lines`:

- `match_source` tem `'NONE'`, e o default é `'NONE'`.
- `product_id NULL` é o estado inicial de toda linha não casada.
- `reviewed BOOLEAN DEFAULT FALSE`.
- `discarded BOOLEAN DEFAULT FALSE`.

Dois estados da tela não têm representação distinta da ausência de estado:

**(a) "não é nenhum".** "O usuário revisou e confirmou que nenhum candidato serve" e "a linha nunca
foi revisada" ficam **ambos** em `product_id IS NULL, match_source='NONE'` — a diferença só existe em
`reviewed` e, sem `match_note`, a tela não distingue os dois ao reabrir a nota.

**(b) "pulada" (§5).** "O usuário viu esta linha e adiou" não é representável em absoluto: qualquer
gravação tiraria a linha de `lines_to_review` e a trataria como resolvida. Não há coluna de adiamento.

`discarded` não serve para nenhum dos dois: é a linha rejeitada (erro de OCR, linha inválida) e o
trigger `compute_receipt_divergence()` (`db/003_triggers.sql`) a **exclui da soma** — usá-la mudaria o
total calculado da nota. Confirmado no trigger:

```
SELECT coalesce(sum(line_total), 0) INTO v_sum
  FROM staging_lines
 WHERE receipt_id = v_receipt
   AND NOT discarded;
```

**Encaminhamento formal a internal task-A.** Não é decisão de interface, é modelagem. Três saídas
possíveis, todas de modelagem e nenhuma escolhida por este documento:

1. Valor novo no enum `match_source` para "revisado sem correspondência" — separa (a) de "nunca
   revisada" sem coluna nova.
2. Coluna própria de decisão de revisão, com os três estados explícitos.
3. Manter como está e aceitar que a tela usa `match_note` como registro informal — o que não resolve
   (b), porque pular não grava.

Enquanto não for resolvido, a tela grava `match_note` com a decisão onde há decisão, e **não inventa
estado**. Pular continua sem gravação, com a consequência descrita na §5.


## 7. Acessibilidade

Separação entre o que é verificável agora e o que só será depois de existir camada visual.

**Testável hoje — critério de aceite:**

- **Teclado:** Tab percorre candidatos e depois as ações; setas movem a seleção no grupo de radio;
  Enter seleciona; o foco nunca fica preso em um card.
- **Rótulo acessível por candidato:** cada candidato é um `radio` com nome acessível que inclui o
  nome canônico e o estado de cada atributo — "LEITE UHT HERC INTEGRAL 1L, marca HERC, variante
  integral, marca coincide, variante não informada".
- **Não depender de cor:** cada estado (coincide / diverge / não informado) tem ícone e texto
  próprios. Passa a valer com qualquer paleta futura.
- **Foco visível:** indicador de foco presente e não removido por reset de CSS.
- **Alvo de toque:** ≥ 44×44 px nas ações, em viewport mobile.
- **Ordem de leitura:** descrição de origem → motivo → candidatos → ações. É a ordem de decisão.

**Não verificável até existir token — não afirmo conformidade:**

- **Contraste.** "Ratio ≥ 4.5:1" sem as cores de origem é intenção, não critério. Quando a camada de
  tokens existir, os pares a medir são: texto primário / fundo do card; texto secundário / fundo do
  card; rótulo de estado / fundo do card (os três estados); texto do botão / fundo do botão (primário
  e secundário); indicador de foco / fundo adjacente. Medir com ferramenta, não por inspeção visual.
- **Estados de foco e hover em contraste**, pelo mesmo motivo.

Até lá, a tela é especificada sem afirmar WCAG AA.

## 8. Tokens — a camada não existe neste projeto

Verificado, não presumido:

- `design_system/design-system.html` **não existia** em `home_shopper` na data desta spec.
- Zero arquivos `.html`, `.css`, `.js`, `.jsx`, `.ts`, `.tsx`, `.scss`, `.vue` no repo.
- Zero ocorrências de `ds-`, `--ds-`, `tailwind` ou design tokens.
- Não há `templates/` nem `static/`.

O repo hoje é SQL, docs e um script Python. **Não há camada visual para respeitar** — a rodada 1
citou `ds-border-warning`, `ds-icon-warning`, `ds-border-success`, `ds-border-neutral` e
`ds-focus-ring` como se existissem. Não existem. Foram invenção da rodada anterior, e estão removidos deste
documento.

Duas saídas, e a escolha é do dono da decisão:

1. O design system vive em outro repositório ou caminho → **é preciso o caminho** para citar tokens
   reais em vez de papéis.
2. Não existe ainda → a camada de tokens é entregável deste projeto, e a tela é especificada por
   papel semântico, como abaixo.

`PROPOSTA` — papéis semânticos que a tela exige, a mapear em tokens quando existirem. Nomes são
proposta, não referência:

| Papel | Uso na tela |
|---|---|
| superfície de card | fundo do card de pendência |
| texto primário | `description_raw`, nome canônico do candidato |
| texto secundário | rótulos de atributo, `store_code`, valores da linha |
| borda de atenção | linha com pendência aberta |
| borda neutra | linha pulada ou resolvida sem vínculo |
| indicador de coincidência | atributo que coincide |
| indicador de divergência | atributo que diverge — o mais crítico, não pode ser sutil |
| indicador de não informado | atributo declarado e ausente — distinto de "não se aplica" |
| ação primária | "Confirmar seleção" |
| ação secundária | "Não é nenhum" |
| ação terciária | "Pular" |
| anel de foco | foco visível em todos os interativos |

## 9. Critérios de aceite — mapeamento

| Critério (internal task-B) | Onde |
|---|---|
| Selecionar candidato | §4 candidatos, §5 confirmar seleção |
| Confirmar que não é nenhum | §5, com confirmação inline; representação em §6 |
| Pular | §5 — grava nada, **a linha volta à fila** (adiamento, não decisão) |
| Sem bloquear outras linhas | §3, e PRD §8 #10 / ADR-0002 §"Consolidação parcial" |
| Diferenças destacadas | §4 candidatos — estado por atributo, com rótulo e ícone |
| Explicação do motivo | §4 motivo da pendência |

## 10. Dependências

| Dependência | Status | Bloqueia |
|---|---|---|
| Consulta de linhas por nota (§2) | não existe | a tela não renderiza sem ela |
| Representação de "não é nenhum" (§6a) | lacuna aberta | distinguir decisão de linha nunca revisada |
| Representação de "pulada" (§6b) | lacuna aberta | distinguir adiamento de linha nunca vista |
| Autorização de escrita no catálogo (ADR-0004) | aberta | promoção a alias |
| Escopo de alias reutilizável (ADR-0002) | aberta | promoção a alias |
| Camada de tokens (§8) | não existe | tokens reais; contraste verificável |

## Nota de implementação

Nada aqui autoriza código, migração ou alteração de schema. A tela depende de: `v_review_queue`
existe e serve de entrada; `staging_lines` suporta o registro da decisão em nível de linha via
`match_source='MANUAL'` + `reviewed` + `match_note`; a promoção a associação reutilizável não é
suportada por decisão vigente e não faz parte desta tela.
