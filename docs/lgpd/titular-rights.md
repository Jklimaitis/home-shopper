# Direitos do titular: canal, prazos e procedimento

Como o titular exerce os direitos do art. 18 da LGPD neste projeto, o que o sistema responde
sozinho, o que exige decisão humana e **em que ordem** a eliminação é executada.

**Fontes consultadas** (2026-10-05, texto primário):

- Lei nº 13.709/2018 (LGPD), arts. 9º, 18, 19, 37, 41 — texto compilado do Planalto.
- Resolução CD/ANPD nº 2, de 27/01/2022, arts. 7º, 9º, 11, 13, 14 e 15 — texto consolidado
  publicado pela ANPD.

A política de retenção (prazos, finalidades, fundamentos) está em `retention-policy.md`; este
documento trata de **pedido do titular**, que é outro gatilho: a eliminação do art. 18, VI não
espera prazo nenhum.

---

## 1. Canal de comunicação — obrigatório mesmo sem encarregado

A Resolução dispensa o agente de pequeno porte de indicar o encarregado (art. 11), mas **não**
dispensa o canal: o §1º exige que o agente que não indicar encarregado disponibilize canal de
comunicação com o titular, para atender o art. 41, §2º, I da LGPD. O art. 7º da Resolução
admite o canal por meio eletrônico, impresso ou outro que assegure acesso facilitado.

**Canal adotado:** eletrônico (e-mail dedicado ao titular), declarado publicamente. O endereço
e quem responde por ele **ainda não estão definidos** — é decisão do Jonas, e enquanto não
existir endereço publicado o canal não existe de fato.

Não há formulário web hoje. Se houver, ele **não pode** guardar CPF, e-mail ou qualquer dado do
titular em tabela nova **sem linha correspondente em `retention_policy`** — é o portão que
impede o formulário de virar um segundo cadastro de dados pessoais sem prazo. A tabela
existente para isso é `data_erasure_requests`, que tem política registrada (90 dias para o
e-mail).

## 2. Os direitos do art. 18, um por um

Art. 18 do caput, na literalidade: confirmação da existência de tratamento (I); acesso aos
dados (II); correção de dados incompletos, inexatos ou desatualizados (III); anonimização,
bloqueio ou eliminação de dados desnecessários, excessivos ou tratados em desconformidade
(IV); portabilidade (V); eliminação dos dados tratados com consentimento, exceto nas hipóteses
do art. 16 (VI); informação sobre uso compartilhado (VII); informação sobre a possibilidade de
não fornecer consentimento e suas consequências (VIII); revogação do consentimento (IX). O §3º
diz que os direitos se exercem por requerimento expresso do titular ou de representante
legalmente constituído; o §5º, que o atendimento é **gratuito**.

O que o `home_shopper` consegue responder, e por meio de quê:

| Direito (art. 18) | Resposta | De onde sai |
|---|---|---|
| I — confirmação | direta: existe conta, notas, referências de preço | `users`, `purchase_notes`, `staging_receipts`, `price_refs` |
| II — acesso | direta: as notas, as linhas, as lojas, os preços observados | as mesmas tabelas; `v_current_prices` para o histórico comparado |
| III — correção | **humana**: dado de origem fiscal não se "corrige" no sistema; o que se corrige é o mapeamento (produto/apresentação) e a linha de staging | `staging_lines`, `presentation_sources`, `synonyms` |
| IV — anonimização/bloqueio/eliminação de dado desnecessário | por política: é o expurgo — `scripts/purge_expired.py` e `scripts/purge_coupon_image.py` | `retention_policy` |
| V — portabilidade | **não implementada**: não há formato de exportação definido | — |
| VI — eliminação | procedimento da seção 4 | `data_erasure_requests` + cascade + expurgo de disco |
| VII — uso compartilhado | direta: **não há compartilhamento com terceiros**; o catálogo (`products`, `stores`, `presentations`) é compartilhado entre usuários e não é dado pessoal (ADR-0004) | `docs/adr/0004-shared-catalogue-and-data-isolation.md` |
| VIII — consequência de não consentir | informativo: o tratamento não se apoia em consentimento | fundamentos no `retention-policy.md` |
| IX — revogação | **sem efeito prático aqui**: os fundamentos registrados são execução de contrato (art. 7, V) e interesses legítimos (art. 7, IX), não consentimento (art. 7, I). Revogação não é o caminho; eliminação é | `retention_policy.legal_basis` |

**Ponto honesto:** o sistema **não tem** consentimento registrado em lugar nenhum, e é
proposital — se algum tratamento futuro passar a se apoiar no art. 7, I, ele precisa vir com
registro do consentimento (art. 8, §2º: o ônus da prova é do controlador) e com prazo em
`retention_policy`. Não existe hoje.

## 3. Prazos de resposta

| Pedido | Prazo da LGPD | Prazo com o art. 14 da Resolução (pequeno porte) |
|---|---|---|
| Confirmação/acesso em **formato simplificado** (art. 19, I) | **imediatamente** | até **15 dias** (Resolução, art. 15) |
| Confirmação/acesso por **declaração clara e completa** (art. 19, II) | até 15 dias | **30 dias** (15 × 2 — Resolução, art. 14, III) |
| Demais solicitações do art. 18 (art. 18, §§3º e 5º) | conforme regulamentação específica | **prazo em dobro** (Resolução, art. 14, I) |

O sistema **não** responde automaticamente hoje: os prazos acima são o limite humano, e o
atendimento é operação manual. O que o sistema faz é tornar a resposta **produzível** — os
dados estão todos em tabelas filtráveis por `user_id`, e o e-mail do titular pede
`formato eletrônico, seguro e idôneo` (art. 19, §2º, I).

Estes prazos **não** têm relação com os prazos de retenção de `retention-policy.md`: uma coisa é
responder ao titular, outra é por quanto tempo o dado vive.

## 4. Procedimento de eliminação (art. 18, VI)

A ordem abaixo foi executada e verificada de ponta a ponta (internal task). Ela não é uma
sugestão de sequência: **cada passo existe porque a ordem inversa perde dado ou perde prova.**

```
1. registrar o pedido        INSERT INTO data_erasure_requests (...)
2. expurgar as imagens       scripts/purge_coupon_image.py --user-id <uuid> --apply
3. apagar a pessoa           DELETE FROM users WHERE id = <uuid>
4. registrar o desfecho      UPDATE data_erasure_requests SET executed_at = now(), notes_removed, items_removed
5. (depois, pelo prazo)      scripts/purge_expired.py   -- zera o e-mail em 90 dias
```

**Por que (1) antes de (3).** A linha de `data_erasure_requests` é a **prova** de que a
exclusão aconteceu. Escrita depois do `DELETE`, ela seria a prova de um fato que ninguém
consegue mais conferir — e a própria tabela não tem FK para `users`, de propósito, para
sobreviver ao delete (ADR-0005 §4).

**Por que (2) antes de (3), e por que isso é o passo que mais se esquece.** `staging_receipts`
tem `fk_staging_receipts_user ON DELETE CASCADE`: apagar a pessoa **apaga as linhas** que
guardam `file_path`. Com elas vai embora a única referência para o arquivo no disco, que
continua lá — mostrando CPF, endereço e cesta. É exatamente o resíduo que a ADR-0005 registrou
como pendência mais urgente. Rodar (2) depois de (3) não apaga nada: não há mais caminho para
seguir. Por isso `purge_coupon_image.py --user-id` **não aplica janela**: o gatilho é o pedido
do titular, não o prazo, e o registro em `audit_log` sai com `reason: lgpd_erasure` — distinto
do expurgo por prazo (`lgpd_retention_purge`) — para que o rastro diga *por que* o dado saiu.

**O que (3) remove, e o que sobrevive.** O `DELETE` em cascata remove notas, linhas, staging,
referências de preço e alertas. Sobrevivem, por desenho: o catálogo compartilhado (`products`,
`stores`, `presentations` — não é dado pessoal), a linha em `data_erasure_requests` (a prova)
e `audit_log` (o rastro do que aconteceu). O e-mail do titular sai de `data_erasure_requests`
90 dias depois de `executed_at`, pelo passo (5).

**Verificação mínima depois de executar** (foi assim que se provou que a ordem está certa):

```sql
-- o dado da pessoa saiu
SELECT count(*) FROM purchase_notes WHERE user_id = '<uuid>';       -- 0
SELECT count(*) FROM staging_receipts WHERE user_id = '<uuid>';     -- 0
-- a prova e o rastro ficaram
SELECT count(*) FROM data_erasure_requests WHERE user_id = '<uuid>';-- 1
SELECT count(*) FROM audit_log WHERE record_id = '<nota>';          -- >= 1
-- e o caminho do cupom NAO virou rastro
SELECT count(*) FROM audit_log
 WHERE before_data::text LIKE '%<arquivo>%' OR after_data::text LIKE '%<arquivo>%';  -- 0
```

O `DELETE FROM users` **não** roda limpo se algum dia alguém puser FK de `audit_log.user_id`
para `users(id)` — foi reproduzido antes da correção e está documentado em ADR-0005 §4. A
asserção R3 de `tests/smoke_test.sql` cobre isso a cada execução dos testes.

## 5. Anonimização, bloqueio e correção (art. 18, IV e III)

- **Eliminação** de dado desnecessário é o expurgo por prazo (`retention-policy.md`).
- **Bloqueio** não tem implementação: não existe hoje necessidade de suspender tratamento
  mantendo a guarda. Se existir, precisa de estado explícito na tabela — bloqueio silencioso
  (filtro ausente numa consulta) é indistinguível de dado ativo.
- **Correção** é o mapeamento, não o dado fiscal: `staging_lines.match_note` existe
  justamente para registrar *por que* uma linha foi associada a um produto, e a revisão humana
  é o caminho de corrigir. A descrição vinda da nota fica verbatim.

## 6. O que precisa de decisão (não é lacuna técnica)

1. **Endereço e responsável pelo canal** (§1). Sem isso, o canal é um procedimento sem porta.
2. **Verificação de identidade** de quem pede. É a pergunta que a ADR-0005 já registrava em
   aberto e continua em aberto: pedir CPF para conferir identidade criaria mais dado pessoal do
   que o pedido coleta; não conferir permite que terceiro apague dados alheios. A decisão
   precisa ser escrita antes do canal entrar no ar.
3. **Portabilidade (V)** e **formato de exportação** — não implementados.
4. **Agendamento** do expurgo por prazo: ver `retention-policy.md`.
