# Política de retenção e expurgo (LGPD)

Este documento registra **até quando** cada dado pessoal do `home_shopper` vive, por que
esse prazo existe e quem o executa. Ele acompanha o que está no banco: a tabela
`retention_policy` (`db/010_retention_policy.sql`) é a forma executável deste texto, e a view
`v_retention_due` é a fila que dela deriva. Documento e código devem dizer a mesma coisa; se
divergirem, o código é que está rodando — mas a divergência é um defeito nos dois.

**Fontes consultadas** (2026-10-05, texto primário):

- Lei nº 13.709/2018 (LGPD), texto compilado do Planalto.
- Resolução CD/ANPD nº 2, de 27/01/2022, texto consolidado publicado pela ANPD (o próprio
  portal observa que o texto foi alterado pela Resolução CD/ANPD nº 15, de 24/04/2024).

**Estado:** `db/010` e os dois scripts de expurgo estão implementados e cobertos por asserções
(N6 em `tests/smoke_test.sql`). **Não** existe agendamento: o expurgo roda quando alguém o
roda. Ver "O que ainda não existe".

---

## 1. O que a lei fixa — e o que ela não fixa

A LGPD **não fixa prazo de retenção**. Nenhum artigo diz "guarde por N dias". O que ela fixa
é o **término do tratamento** e as **hipóteses de conservação**:

- **Art. 15** — o término do tratamento ocorre quando: (I) a finalidade foi alcançada ou os
  dados deixaram de ser necessários/pertinentes; (II) o período de tratamento acabou;
  (III) o titular se comunicou (inclusive revogando consentimento); ou (IV) a ANPD determinou.
- **Art. 16** — os dados "serão eliminados após o término de seu tratamento", autorizada a
  conservação apenas para: (I) cumprimento de obrigação legal ou regulatória pelo controlador;
  (II) estudo por órgão de pesquisa, com anonimização sempre que possível; (III) transferência
  a terceiro nos termos da lei; ou (IV) **uso exclusivo do controlador, vedado seu acesso por
  terceiro, e desde que anonimizados os dados**.
- **Art. 6, I** — finalidade: propósitos legítimos, específicos, explícitos e informados.
- **Art. 6, III** — necessidade: tratamento limitado ao mínimo necessário à finalidade.
- **Art. 6, VIII** — prevenção: medidas para prevenir danos.
- **Art. 6, X** — responsabilização e prestação de contas: **demonstração** de que a medida
  existe e é eficaz.
- **Art. 37** — o controlador deve manter registro das operações de tratamento.

**Consequência prática, e é o ponto central deste documento:** o prazo é uma **escolha do
controlador**, ancorada em uma hipótese do art. 16, e precisa ser **escrita e justificada**
(art. 6, X e art. 37). Onde este documento diz "90 dias", leia-se *nós decidimos 90 dias, por
esta razão* — nunca *a LGPD exige 90 dias*. Escrever o número como se fosse exigência legal
seria prestar contas de uma regra que não existe.

O que a lei efetivamente obriga aqui, dado o desenho do sistema, é:

1. o tratamento terminar quando a finalidade se esgotar (art. 15, I) — é o caso da imagem do
   cupom assim que a nota entra em `DONE`: a revisão acabou, a finalidade acabou;
2. o que for conservado caber em uma das quatro hipóteses do art. 16;
3. o prazo estar registrado e demonstrável (art. 6, X e art. 37);
4. todo dado pessoal ser eliminado quando o titular pedir, ressalvadas as hipóteses do art. 16
   (art. 18, VI) — ver `titular-rights.md`.

## 2. Regime de agente de tratamento de pequeno porte

O projeto se enquadra como agente de tratamento de pequeno porte e usa o tratamento
diferenciado da Resolução CD/ANPD nº 2/2022. Os dispositivos que mudam o que fazemos:

| Dispositivo | O que permite | Uso neste projeto |
|---|---|---|
| **Art. 9º** | cumprir o registro das operações (art. 37) de **forma simplificada** | `retention_policy`: uma linha por coluna, com finalidade, fundamento e prazo. É o registro, não uma tabela-anexo dele |
| **Art. 11** | **não é obrigatório indicar encarregado** (dispensa do art. 41 da LGPD) | não há encarregado indicado — **mas** o §1º exige canal de comunicação com o titular, e esse canal é obrigatório: ver `titular-rights.md` |
| **Art. 13** | **política simplificada de segurança** da informação | este documento + `docs/adr/0005-privacy-minimisation-and-erasure.md`. A ANPD considera a política simplificada existente para os fins do art. 6, X (§2º) |
| **Art. 14** | **prazo em dobro** no atendimento das solicitações do titular (art. 18, §§3º e 5º), na comunicação de incidente, no fornecimento da declaração clara e completa (art. 19, II) e nos prazos de informação à ANPD | usado no `titular-rights.md`. **Não** se aplica aos prazos deste documento: retenção não é prazo de resposta ao titular |
| **Art. 15** | declaração **simplificada** do art. 19, I em até 15 dias | usado no `titular-rights.md` |
| **Art. 3º** e **art. 4º** | o regime não vale para quem faz **tratamento de alto risco** (larga escala, ou capaz de afetar significativamente direitos fundamentais, combinado com um critério específico) | vigiar o enquadramento: um catálogo global de compras compartilhado entre usuários é justamente o tipo de decisão que precisa ser reavaliada se a escala crescer |

## 3. A tabela de retenção

Âncora temporal de cada linha: `audit_log.occurred_at`,
`data_erasure_requests.executed_at`, `staging_receipts.updated_at`.

| Dado (tabela.coluna) | Onde | Finalidade (art. 6, I) | Fundamento (art. 7) | Prazo | Término ancorado em | Ação de expurgo |
|---|---|---|---|---|---|---|
| `staging_receipts.file_path` | caminho no banco; **arquivo no disco** | a imagem do cupom é a prova sobre a qual a revisão humana de uma linha ambígua é feita | IX — interesses legítimos | **nota em `DONE`: imediato**; `PENDING`/`IN_REVIEW`/`DISCARDED`: **30 dias** | art. 15, I (a finalidade se esgota quando a revisão termina) | `scripts/purge_coupon_image.py` apaga o arquivo, zera o caminho e registra em `audit_log` |
| `audit_log.before_data` | JSONB | imagem anterior da alteração de uma nota/linha, para suporte e para o rastro da exclusão | IX — interesses legítimos | **90 dias** → o payload é descartado (`NULL`) | art. 16, IV (só se conserva anonimizado) | `scripts/purge_expired.py` |
| `audit_log.after_data` | JSONB | idem, imagem posterior | IX — interesses legítimos | **90 dias** → `NULL` | art. 16, IV | `scripts/purge_expired.py` |
| `data_erasure_requests.email` | banco | contato do titular, para responder ao pedido e identificar o registro da operação | II — obrigação legal (art. 19 e art. 37) | **90 dias após `executed_at`** → `NULL` | art. 16, I (o registro da operação continua; o endereço deixa de ser necessário) | `scripts/purge_expired.py` |
| `purchase_notes.access_key` | banco | identidade natural da NFC-e: comparar preços entre lojas e manter a reingestão idempotente | V — execução de contrato | **sem prazo fixo** — revisão registrada (`expires_at`) | art. 15, I: enquanto a comparação for a finalidade, o dado é necessário | **não é expurgado automaticamente** |
| `line_items.unit_price` | banco | a linha comprada: o que, quanto e por quanto — é o histórico de compras sobre o qual a comparação existe | V — execução de contrato | **sem prazo fixo** — revisão registrada | art. 15, I | **não é expurgado automaticamente** |
| `users.email` | banco | contato da conta e identificador de login | V — execução de contrato | **sem prazo fixo** — enquanto a conta existir; revisão registrada | art. 15, I | **não é expurgado automaticamente**; sai na exclusão da conta (art. 18, VI), com a prova em `data_erasure_requests` |

Notas que a tabela não comporta:

- **Por que a imagem do cupom tem dois prazos.** É o dado mais perigoso do sistema: mostra CPF,
  endereço e cesta, e é **pixel** — nenhuma consulta encontra o CPF dentro dele (ADR-0005 §2).
  Enquanto a nota está em revisão, apagá-la impede a própria revisão. Quando a nota entra em
  `DONE`, a finalidade acabou e não há razão para conservar: a linha "30 dias" não é uma
  carência, é o caso `IN_REVIEW`. Em `v_retention_due` isso é explícito — `DONE` vence com
  `due_at = updated_at`, sem espera.
- **Por que o payload de auditoria é descartado, e não a linha.** O art. 16, IV autoriza
  conservar para uso exclusivo do controlador **desde que anonimizado**. Entre apagar o rastro
  inteiro e manter o rastro sem o dado pessoal, a segunda opção é a que a lei descreve:
  `table_name`, `operation`, `record_id` e `occurred_at` continuam provando que algo aconteceu.
  Um rastro que é uma segunda cópia dos dados pessoais não é auditoria, é uma segunda violação.
- **Por que três alvos ficam em "sem prazo fixo".** Inventar um prazo para o histórico de
  compras produziria uma obrigação que o produto não pode cumprir: apagar a nota depois de N
  dias quebra a comparação entre lojas, que é a razão de existir do sistema. A resposta honesta
  é a que o art. 15, I autoriza — o dado é necessário enquanto a finalidade viver — com
  **revisão registrada** em `expires_at`, para que a decisão volte a ser examinada em vez de
  virar permanência por esquecimento. `ck_retention_policy_review` recusa uma política sem
  prazo e sem data de revisão.
- **`data_erasure_requests.email` era `NOT NULL`.** Passou a aceitar `NULL` em `db/010`: sem
  isso a janela registrada seria inexequível. `ck_data_erasure_email` proíbe a string vazia —
  apagar um endereço não é preencher um campo com espaço.

## 4. Como o prazo é executado

O registro governa o expurgo; nada tem janela escrita em código.

```
retention_policy ──► v_retention_due ──► purge_expired.py       (payload de auditoria, e-mail)
                                    └──► purge_coupon_image.py  (imagem no disco)
```

- **`v_retention_due`** (`db/010`) filtra por prazo vencido com `retention_days IS NOT NULL`.
  É o que impede o vazamento mais provável deste desenho: uma política sem prazo entrar na
  fila de expurgo e apagar dado que ainda serve à finalidade. A granularidade é
  (política, registro, coluna).
- **`scripts/purge_expired.py`** — dry-run por padrão; `--apply` executa. Idempotente: a
  segunda execução não altera nada e **não** reescreve `last_purged_at` (a coluna só muda
  quando algo foi realmente expurgado). Ao final de `--apply` ele reconsulta a fila e falha se
  sobrou algo que deveria ter expurgado — a prova de que o comando e a view concordam.
- **`scripts/purge_coupon_image.py`** — apaga o arquivo, zera `file_path` e grava o evento em
  `audit_log` **sem o caminho e sem o conteúdo**. Tem uma guarda de contenção: o caminho vem de
  uma coluna do banco, e apagar caminho arbitrário a partir de dado é transformar dado em
  comando. Alvo que resolve para fora da raiz de armazenamento é **recusado** (nada apagado,
  caminho **não** zerado, exit code 1).
- **`audit_log` do expurgo guarda o fato, não o alvo**: `{"reason": "lgpd_retention_purge",
  "file_path": "redacted", "file_existed": true}`. Registrar ali o caminho do cupom recriaria
  o dado que o expurgo acabou de remover, num lugar que ninguém consulta para conferir.

### A lacuna do disco (ADR-0004 §4), declarada

O banco **não sabe** se o arquivo existe. O expurgo da imagem é: (1) apagar o arquivo;
(2) zerar o caminho; (3) registrar. Se o processo morrer entre (1) e (2), o caminho aponta para
um arquivo que não existe — a próxima execução vê o arquivo ausente, registra
`file_existed: false` e zera o caminho. É visível e auto-corrigível. A exclusão LGPD da imagem
só está **completa quando as duas coisas batem**: caminho zerado no banco e arquivo fora do
disco. Enquanto não baterem, há resíduo, e resíduo é o que este trabalho veio eliminar.

## 5. O que ainda não existe

Declarado para não ser confundido com implementado:

1. **Agendamento.** Nada roda sozinho. O expurgo é um comando que alguém executa; enquanto
   ninguém executar, a política está escrita e não cumprida.
2. **Ciclo de vida da conta.** `users.email` "enquanto houver conta ativa" pressupõe um
   caminho de encerramento de conta que ainda não existe. A exclusão de hoje é a do art. 18, VI
   (a pedido do titular).
3. **Verificação dos prazos com o volume real.** 90 dias para o payload foi escolhido sem
   medição do volume de `audit_log`; a revisão anual registrada é o lugar de corrigir isso.
4. **Encarregado.** A dispensa do art. 11 da Resolução não dispensa o canal (§1º). O canal
   existe como procedimento em `titular-rights.md`; o endereço e o responsável por respondê-lo
   são decisão do Jonas.

## 6. Como alterar a política

Alterar prazo é alterar **dados do registro**, não código:

```sql
UPDATE retention_policy
   SET retention_days = <novo>, purpose = '<nova justificativa>'
 WHERE table_name = '<tabela>' AND column_name = '<coluna>';
```

Três coisas o banco recusa, e a recusa é a garantia de que o registro continua auditável:
prazo zero ou negativo (`ck_retention_policy_days`), fundamento fora das quatro hipóteses
usadas aqui (`ck_retention_policy_basis`) e política sem prazo e sem data de revisão
(`ck_retention_policy_review`). Além disso, `tr_retention_policy_target` recusa uma política
que nomeie uma coluna que não existe: um registro que pode apontar para o nada não é registro.

Uma coluna pessoal nova **não entra em produção sem linha nesta tabela** — é o que faz o
art. 6, X ser verificável por consulta em vez de por confiança.
