# Decisão — escrita no catálogo global (internal task / card de decisão `internal task`)

**Status:** **ACEITA** — 2026-10-05
**Decisão de:** **Jonas** (dono da decisão) · **execução:** engenharia
**Registrada em:** 2026-10-05, card `internal task` (`internal task`) — ratificação
comunicada pela coordenação em comentário do card, 2026-10-05
**Forma decidida:** FORMA 1 — escrita com aprovação
**Alternativa descartada:** FORMA 2 (base/overlay por usuário)
**Implementação:** `db/009_catalog_write_requests.sql`, `tests/smoke_test.sql` (bloco N5),
card de execução `internal task`

---

## 0. Decisão registrada (o que ficou decidido)

> **FORMA 1 — escrita com aprovação.** Somente responsável/administrador cria produto,
> apresentação e sinônimo COMPARTILHADO. O usuário comum abre uma **solicitação**
> (ticket) para criar, apresentar, sinonimar e ajustar; ele **não** escreve direto no
> catálogo global. A base continua **única e compartilhada**: não existe base por
> usuário nem overlay.
> **Data:** 2026-10-05.

Ratificação no card `internal task`: *"RATIFICADA pelo Jonas em 2026-10-05: FORMA 1, com
aprovacao. Somente responsavel/administrador cria produto, apresentacao e sinonimo
COMPARTILHADO; o usuario comum abre solicitacao. Base unica e compartilhada, sem overlay
nem DB por usuario."*

Efeitos, ponto a ponto (critérios de aceite da decisão):

| Questão | Decisão |
|---|---|
| Quem cria produto, apresentação e sinônimo compartilhado | **responsável/administrador** |
| A criação de um usuário vale para os outros? | só **depois de aprovada**: a solicitação aprovada publica no catálogo **compartilhado**, então vale para todos |
| Item global que se revela errado | corrigido por solicitação de `ADJUSTMENT` apontando o alvo (`target_id`); a linha global só muda **após aprovação**, com revisor e motivo registrados |
| Existe catálogo por usuário / overlay? | **não**. Base única e compartilhada (o ADR-0004 já havia descartado a forma 2 por escrito) |
| Sinônimo privado | continua suportado por `synonyms.scope` (`scope = user_id`); é escopo de **associação**, não um segundo catálogo |

### Por que (leitura de mercado, 2026-10-05)

A forma 1 é o padrão de governança de PIM (Akeneo Shared Catalogs, Oracle PIM,
Salesforce Industries CPQ): papel de *data owner/steward*, intake, revisão, aprovação,
publicação. A forma 2 (overlay por usuário) existe em ecommerce como **customização de
exibição/preço** (Adobe Commerce Shared Catalog, Salesforce Shared Catalog rules) — não
como governança de identidade de produto. E o ADR-0004 já descarta a forma 2 por
escrito: *"Cada pessoa teria seu proprio products. Descartado: duplicaria a identidade
do mesmo item em N cadastros, e a comparação entre lojas passaria a depender de um
mapeamento entre catálogos privados que ninguém mantém."*

### O que a estrutura entrega

- **`catalog_write_requests`** — o ticket de intake/aprovação. `kind`
  (`PRODUCT`|`PRESENTATION`|`SYNONYM`|`ADJUSTMENT`), `payload JSONB`, `target_id`
  (para ajuste em item existente), `justification`, `status`
  (`OPEN`|`APPROVED`|`REJECTED`), `reviewed_by`, `review_note`, `created_at`,
  `decided_at`.
- **O portão é regra do banco, não convenção.** Uma linha `APPROVED` não existe sem
  revisor e sem data de decisão; uma linha `OPEN` não existe com revisor; um
  `ADJUSTMENT` exige alvo; e o `payload` não aceita e-mail, CPF (com ou sem pontuação)
  nem chave de acesso de NFC-e (44 dígitos corridos **ou** no layout oficial formatado
  `2-4-14-2-3-9-9-1`) — o `payload` é o que **vira catálogo compartilhado** quando
  aprovado, então dado pessoal nele vazaria para o catálogo de todos.
- **`v_catalog_write_queue`** — a fila de aprovação, com a contagem por `status` e
  `kind`.
- **Rastro que sobrevive à exclusão LGPD.** `requested_by` é FK `ON DELETE SET NULL`
  — a pessoa some, o ticket fica — e `requested_by_email` preserva a proveniência.
- **`synonyms.scope` documentado sem FK.** `scope IS NULL` = global; `scope = user_id`
  = privado. Nenhuma FK para `users` ainda: **se** apagar o usuário apaga ou mantém o
  sinônimo privado é decisão em aberto (card D3-follow), e uma FK agora a decidiria por
  acidente.

## 1. Consequência registrada (honestidade brutal)

Esta decisão resolve **contaminação alheia** (um erro de um usuário não reescreve o
catálogo de todos) e dá um **caminho à Ana** (persona 2.2, que não cadastra catálogo:
ela abre solicitação em vez de ficar bloqueada). Mas **cria uma fila de aprovação**.

Com **um único usuário real** — o próprio Jonas, PRD 9: não é SaaS — **o aprovador é o
próprio solicitante**. O portão é **cerimonial** até existir um segundo usuário real. O
risco 13.9 (custo recorrente de revisão) **não** é resolvido por esta decisão: ela troca
"cada um revisa a mesma linha" por "cada um espera um aprovador que hoje é ele mesmo".
Não vender a decisão como se ela removesse esse custo.

## 2. Uma decisão de engenharia dentro do desenho (declarada)

`reviewed_by` **não** tem FK para `users`, apesar da lista de colunas do card dizer
"(FK users, nullable)". Motivo: uma FK `ON DELETE SET NULL` faria o caminho de exclusão
LGPD **abortar** — apagar o revisor tentaria anular `reviewed_by` numa linha `APPROVED`
e o `CHECK` (`APPROVED` exige revisor) dispararia dentro da mesma instrução, quebrando
`DELETE FROM users`. É a **mesma classe de bug** já reproduzida duas vezes neste repo
(`audit_log.user_id`, ADR-0004 §5; e o ponteiro de proveniência de `db/006`), sempre
resolvida removendo a FK, nunca enfraquecendo o invariante. O revisor vira **metadado de
ator** (como `audit_log.user_id`), e `reviewed_by_email` guarda o rastro legível. O teste
N5 do `smoke_test.sql` prova: aprovação continua íntegra após a remoção do
revisor.

O `CHECK` de dado pessoal no `payload` **não é cópia** de
`scripts/guard_dados_sensiveis.py`: é um **superconjunto**. Cobre os mesmos quatro
padrões que o guard cobre — as **duas formas** da chave de acesso de NFC-e e as **duas**
do CPF — e **acrescenta e-mail**, que o guard não procura. As duas formas da chave
importam: uma regra que só enxerga 44 dígitos corridos deixa passar a chave escrita no
layout oficial `2-4-14-2-3-9-9-1`, que é como a pessoa copia do app da SEFAZ — a
assimetria que a própria docstring do guard alerta a evitar, e o `payload` é justamente o
que vira catálogo compartilhado. O PG16 não tem look-around (ARE), então as fronteiras da
chave formatada são expressas por alternação (`(^|[^0-9-])` … `([^0-9-]|$)`); para as
sequências de dígitos puros o `\y` faz o mesmo papel dos look-arounds do guard (é o que
impede o CPF de 11 dígitos de disparar dentro de um GTIN de 13). É **conservador de
propósito**: um falso positivo manda o solicitante reescrever, que é a direção segura
(ADR-0004, "favorável à revisão").

## 3. Estado

- `db/009_catalog_write_requests.sql` **aplicado limpo em base descartável** (001→009),
  0 constraint sem nome, `smoke_test.sql` sem regressão (bloco N5, 11 asserções, tudo
  PASS), `scripts/guard_dados_sensiveis.py` OK (66 arquivos).
- **Integração por PR**, a partir do branch
  `home_shopper/internal task-internal task` (worktree do card
  `internal task`). Nunca direto na `main`.
