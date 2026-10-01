---
status: draft
numero: 6
criado: 2026-09-30
---

# ADR-0006: Ingestão assíncrona, idempotência e a fronteira do que é uma compra

Este documento registra a terceira via do pipeline — as outras duas já estão em
[ADR-0002](0002-association-review-and-consolidation.md) (associação e revisão) e
[ADR-0003](0003-units-base-price-and-aggregation.md) (unidades e agregação). Esta é sobre
**como o trabalho entra no sistema e o que significa reprocessar**.

**Atenção ao estado atual:** quase nada disto está implementado. `staging_receipts` tem
`source`, `source_ref`, `status`, `attempts` e `error_message`; há um índice único parcial de
idempotência. Não há API, não há worker, não há Celery. Este documento é proposta, e o
schema existe para não obligar a reescrita quando ele for implementado.

## Contexto

Uma compra chega de três maneiras, com confiabilidades muito diferentes:

| Origem | Como chega | O que pode dar errado |
|---|---|---|
| `QRCODE` | link da SEFAZ | rede instável, HTML que muda, timeout |
| `SEFAZ` | consulta por chave | chave digitada errada, emitente fora do ar |
| `OCR` | foto do cupom | leitura errada de dígito, item partido em dois |
| `MANUAL` | digitação humana | tudo, mas é lento |
| `IMPORT` | arquivo XML | grande; o caso das 11 notas |

A extração é **demorada e imperfeita**. Uma nota real tem 43 a 59 linhas e nenhuma delas
tinha EAN; 10 a 14 linhas por nota exigem revisão manual. Fazer isso no ciclo da requisição
significa timeout para o usuário e trabalho jogado fora se a requisição morrer no meio.

E há um segundo problema, menos visível: **o mesmo cupom chega mais de uma vez.** Retry de
job, duplo clique, reimportação de um XML, o usuário que fotografa de novo. Sem idempotência,
cada repetição vira uma compra duplicada no histórico — e o histórico de gasto é a coisa que
o usuário mais não quer ver errada.

## Decisão proposta

### 1. `202 Accepted` e processamento assíncrono

O upload devolve `202 Accepted` com um identificador de job. A extração, o matching e a
sugestão de consolidação rodam fora do ciclo da requisição.

A consequência é a regra mais importante do fluxo: **upload concluído significa documento
recebido, não nota aprovada.** `staging_receipts.status` nasce `PENDING` e nada entra em
`purchase_notes` ou `price_refs` antes da revisão. A tela final mostra o resumo, os valores
originais, as interpretações propostas e os motivos das pendências.

*Estado: enum `consolidation_status` e colunas de diagnóstico existem; o fluxo não.*

### 2. Idempotência por chave de origem, por usuário

Duas barreiras, em camadas distintas:

```sql
-- camada 1: a nota nem chega a ser extraída duas vezes
CREATE UNIQUE INDEX uq_staging_receipts_source
    ON staging_receipts (user_id, source, source_ref_norm)
    WHERE source_ref_norm <> '';

-- camada 2: a compra consolidada não duplica
CREATE UNIQUE INDEX uq_purchase_notes_access_key
    ON purchase_notes (user_id, access_key) WHERE access_key IS NOT NULL;
```

`user_id` está nas duas porque o índice é por pessoa: reprocessar o cupom de uma pessoa não
deve falhar por causa do cupom de outra.

A camada 1 é **parcial** (`source_ref_norm <> ''`) porque uma nota digitada à mão não tem
referência, e o valor padrão de `lower(coalesce(source_ref, ''))` seria string vazia — sem a
condição, todas as notas manuais de um usuário colidiriam na mesma chave.

A camada 2 cobre o caso em que a nota foi **consolidada** e o job roda de novo. Uma chave de
NFC-e é a identidade natural do documento: uma nota por usuário.

*Estado: ambos os índices existem no schema. O comportamento de reprocessamento, não.*

### 3. Retry é esperado; duplicidade não é

`attempts` conta tentativas e `error_message` guarda o diagnóstico. Um job que falha é
tentado de novo; um job que **passa** duas vezes não pode produzir duas compras.

A consequência é o porquê de `staging_receipts.source_ref` ser declarado como "a chave de
acesso, a URL da SEFAZ, o id do upload" e nada mais: ele é a **chave de idempotência**, e seu
formato determina o que pode ser deduplicado. Uma URL de consulta com token de sessão não é
deduplicável, e o sistema precisa saber disso em vez de tentar.

*Estado: colunas existem; semântica de retry, não.*

### 4. Consolidação em transação por lote

O [ADR-0002](0002-association-review-and-consolidation.md) recomenda consolidar parcialmente:
itens resolvidos entram, pendentes ficam para revisão posterior. Duas exigências:

- **Transação por lote.** Uma falha reverte o lote, sem afetar lotes anteriores. Consolidação
  parcial não pode ser confundida com gravação incompleta por erro — a diferença precisa ser
  visível, não implícita.
- **Sem duplicidade na consolidação posterior.** Quando os itens pendentes forem resolvidos,
  eles entram **na mesma compra**: não se recria o cabeçalho, não se duplica linha, e o total
  pago **não é contado de novo**.

O vínculo único entre nota importada e compra consolidada é
`purchase_notes.staging_receipt_id` (`ON DELETE SET NULL`, para o registro original
sobreviver). Ele é o que torna a consolidação posterior possível sem duplicar.

*Estado: coluna e índice existem; a transação e a semântica de reconsolidação, não.*

### 5. O checksum é o critério de aceitação do job, não o matcher

`staging_receipts` carrega `total_gross`, `total_computed` e `divergence_cents`, e o trigger
`tr_staging_lines_checksum` recalcula a soma das linhas a cada mudança, excluindo linhas
descartadas.

A checagem é o que fecha o loop: se a soma das linhas extraídas bater com o total declarado
no cupom, a extração provavelmente leu certo. Se não bater, a nota **vai para revisão
humana** — não é consolidada, não é descartada, fica pendente com o valor da divergência
visível.

O que o job **não** decide: se um item é o mesmo produto que outro. Isso é
[ADR-0002](0002-association-review-and-consolidation.md). Misturar as duas responsabilidades é
o que faz um sistema de ingestão parecer que sabe mais do que sabe.

*Estado: implementado e testado (A1, A2).*

### 6. A nota completa é a unidade financeira, mesmo consolidada parcialmente

Se a consolidação é parcial, a conferência financeira continua sobre a **nota inteira**. Não
se compara o total fiscal com a soma do subconjunto consolidado — isso reportaria divergência
em toda nota com pendência.

O total pago é registrado uma única vez, no cabeçalho, quando cabeçalho e totais estiverem
validados. Comparações e análises por produto usam apenas as linhas elegíveis e **indicam
cobertura incompleta**.

Três notas também apresentam diferença entre total bruto e valor pago, e duas trazem
valores de rodapé sem rótulo — `300,00` e `54,32` cuja soma é o total, mas cuja atribuição é
ambígua. Nesses casos `amount_paid` fica `NULL` em vez de receber um palpite. Um total de
pagamento errado é pior que um total ausente.

*Estado: comprovado em 11 notas; a regra de consolidação parcial, não.*

## Alternativas consideradas

### Processamento síncrono na requisição

Sem fila, sem `attempts`, sem `error_message`. Descartado: uma nota com 56 linhas e OCR não
termina dentro de um timeout razoável, e o trabalho é perdido se a conexão cair. O usuário
esperaria minutos sem saber se deu certo.

### Confiar apenas no id do job para idempotência

Mais simples. Descartado: o id do job é novo a cada tentativa, então a deduplicação nunca
acerta. A idempotência precisa de uma identidade do **documento**, não do processamento.

### Índice único em `source_ref` sem o filtro parcial

Simplifica. Descartado: `source_ref_norm` de uma nota manual é string vazia, e todas as
notas manuais de um usuário colidiriam numa chave só. O filtro `WHERE source_ref_norm <> ''`
é o que separa "tem identidade deduplicável" de "não tem".

### Deduplicar por (usuário, data, total, loja)

Funciona paraReceipts sem chave. Descartado: duas compras reais no mesmo dia na mesma loja
podem ter o mesmo total com frequência baixa mas suficiente para acontecer, e a falha seria
silenciosa: o usuário perde uma compra do histórico sem nenhum aviso.

### Descartar a nota quando o checksum não fecha

Simples. Descartado: um erro de OCR em um dígito torna a nota inteira inutilizável, quando o
real é um dígito. O caminho é pendente com a divergência visível, não descarte.

### Consolidação apenas integral, espera resolver tudo

Simplifica o estado. Descartado: uma única linha ambígua de 56 impede usar 42 itens já
resolvidos. A parcialidade entrega valor antes, ao custo de precisar indicar cobertura
incompleta — o que é honesto, desde que a interface diga.

## Consequências

**Positivas**

- Upload responde rápido e o trabalho pesado não se perde.
- Reprocessar é seguro: nem a extração nem a consolidação duplicam.
- O checksum dá um critério objetivo para "a extração provavelmente leu certo".
- Consolidação parcial entrega comparação antes de a nota estar 100% resolvida.

**Negativas e riscos**

- `202 Accepted` exige uma noção de estado que o usuário precisa ver: pendente, em revisão,
  concluído, com erro. Sem isso, a resposta assíncrona vira "cadê meu recibo?".
- Reprocessar uma nota **já consolidada** precisa de caminho explícito — os dois índices
  protect, mas nenhum diz o que fazer quando o segundo processamento chega. Isso é uma
  decisão de UX tanto quanto de código.
- O checksum fecha a extração, não o significado. Uma nota pode fechar o total e ainda ter
  itens associados ao produto errado.
- `source_ref` guarda dado pessoal quando é chave de acesso ou URL da SEFAZ. Ele fica no
  staging, que é usuário-isolado, mas o caminho de expurgo é o mesmo da
  [ADR-0005](0005-privacy-minimisation-and-erasure.md).
- Duas notas com `amount_paid` ambíguo ficam sem total pago. Precisa ser visível para o
  usuário, não um `NULL` silencioso no banco.

## O que este documento não decide

- Tecnologia da fila e do worker (Celery, arq, Dramatiq; Redis ou RabbitMQ).
- Política de retry: número de tentativas, backoff, quando desistir e notificar.
- Se o usuário pode cancelar um job em andamento.
- O que a interface mostra durante o processamento.
- Como tratar uma nota cuja consolidação parcial foi depois completada — se o histórico de
  "nota completa" é reconstruído ou se a cobertura parcial é permanente e visível.
- Se `source_ref` deve ser **criptografado** em repouso, já que pode ser chave de acesso.

## Pontos pendentes de revisão

- Se `source_ref` (chave de acesso / URL) deve ser cifrado em repouso.
- Política de retry: tentativas, backoff, desistência.
- Comportamento quando um segundo processamento chega para uma nota já consolidada.
- Como a interface representa pendente, parcial e completo sem mentir sobre a cobertura.
- Definição de "sucesso" do job: só o checksum, ou também uma verificação de cobertura de
  produtos.
- Expurgo de `source_ref` após a consolidação.
