---
status: draft
numero: 5
criado: 2026-09-30
---

# ADR-0005: Minimização, retenção e exclusão de dados sob a LGPD

Este documento cobre a camada de privacidade. Ele se apoia no
[ADR-0004](0004-shared-catalogue-and-data-isolation.md) (o que é compartilhado e o que é
pessoal) e descreve o que a LGPD exige e o que o schema já faz — além do que ainda não faz.

**Atenção ao estado atual:** a exclusão de dados está implementada e testada (asserção R3). A
**retenção e o expurgo** não existem. Este documento é majoritariamente proposta, e a
diferença está marcada em cada seção.

## Contexto

Uma compra é dado pessoal. Uma foto de cupom é dado pessoal em formato que não se audita
procurando CPF, porque é pixel. Uma chave de acesso é pior: é um identificador que dá acesso
ao histórico inteiro de compras de uma pessoa na autoridade fiscal, sem autenticação.

O risco aqui não é só o banco. É o **ciclo de vida inteiro**: o que entra, quanto tempo
fica, o que sai quando a pessoa pede para sair, e o que continua existindo como rastro.

O projeto tem duas obrigações que apontam em direções opostas e precisam ser atendidas ao
mesmo tempo:

1. **Apagar** os dados de uma pessoa a pedido (LGPD art. 18, direito de eliminação).
2. **Preservar** o rastro de que a eliminação aconteceu, e o catálogo compartilhado que
   outra pessoa construiu.

## Decisão registrada

### 1. A chave de acesso nunca é persistida em claro

`purchase_notes.access_key` existe e é `CHAR(44)` com índice único parcial — é o que garante
idempotência de reprocessamento. Mas **nenhum repositório, fixture ou log versionado pode
contê-la**.

A chave é a porta de entrada: quem a possui consulta a nota na SEFAZ sem autenticar e obtém
CPF, endereço e histórico. Isso a torna dado pessoal, não id interno.

O guard do repositório bloqueia a chave **nas duas formas** — 44 dígitos seguidos e o formato
oficial com hífens, `NN-NNNN-<14 dígitos>-NN-NNN-NNNNNNNNN-NNNNNNNNN-N`, que é como sai do
app da SEFAZ. A forma formatada só era capturada por acaso, porque o grupo de 14 dígitos
do CNPJ do emitente disparava o padrão de CNPJ; ao remover esse padrão, o buraco apareceu e
foi corrigido com um padrão explícito.

*Estado: implementado e testado.*

### 2. Imagem de cupom no disco, nunca no banco

`staging_receipts.file_path` é `TEXT`. Nenhum `BYTEA` no schema.

O cupom mostra CPF, endereço, itens e valores. Guardá-lo como bytes no Postgres o tornaria o
dado mais difícil de auditar e o mais difícil de apagar com prova. No disco, a exclusão é
verificável: o arquivo deixa de existir, e isso se prova.

`uploads/`, `cupom*.jpg`, `storage/` e `media/` estão no `.gitignore`. `STORAGE_DIR` e
`MAX_UPLOAD_MB` estão no `.env.example`.

*Estado: implementado no schema. **Retenção e expurgo do arquivo: não existem.** Ver
pendência 2.*

### 3. Exclusão LGPD: ordem, cascata e o que sobrevive

A ordem é deliberada:

```sql
INSERT INTO data_erasure_requests (...);   -- 1. a prova, ANTES do delete
DELETE FROM users WHERE id = ...;          -- 2. o dado
```

O `DELETE` em cascada remove notas, linhas, staging, referências de preço e alertas.

**Sobrevivem por desenho:**

- o catálogo (`products`, `stores`, `presentations`, `categories`) — não é dado pessoal, e
  apagá-lo destruiria a identidade compartilhada que outras pessoas construíram;
- `data_erasure_requests` — é a prova, escrita antes;
- `audit_log` — o rastro do que aconteceu.

*Estado: implementado e coberto pela asserção R3 (dados removidos, rastro preservado).*

### 4. `audit_log` e `data_erasure_requests` não têm FK para `users`

Os dois campos `user_id` existem, sem restrição de integridade referencial, por um motivo
técnico que só aparece em execução:

Com FK, `DELETE FROM users` **aborta**. O `CASCADE` de `purchase_notes`/`line_items` dispara
o trigger de auditoria **dentro da mesma transação que ainda não removeu a linha do usuário**.
A mensagem é `insert or update on table "audit_log" violates foreign key constraint`, e a
exclusão LGPD fica impossível de executar.

Isto foi **reproduzido antes da correção**, não deduzido. O campo é metadado de autor, não
dado de negócio, e um registro de que algo aconteceu precisa sobreviver a quem o fez.

*Estado: implementado e testado.*

### 5. O guard é o controle técnico, e ele é verificado

O guard (`scripts/guard_dados_sensiveis.py`) roda no pre-commit e na CI. Um guard que
depende de alguém lembrar de rodar não é um controle.

O que é bloqueado: chave de acesso (44 dígitos, com e sem hífens) e CPF (11 dígitos, com e
sem formatação). Sequências de zeros — o formato anônimo dos fixtures — passam.

O que **não** é bloqueado: **CNPJ de pessoa jurídica**. Identifica empresa, não pessoa. O
cadastro é público, o número está no cupom e na fachada, e sanitizá-lo não protege ninguém:
o mesmo número é recuperável em segundos. A ressalva é CNPJ de MEI em que o proprietário é o
próprio titular — nesse caso funciona como identificador individual.

*Estado: implementado, com 14 casos verificados.*

### 6. Localização dos dados de teste: fora do repositório

Os dados reais das 11 notas (descrições, quantidades, preços) vivem em
`<internal>, fora do git, e não têm identidade do comprador — a chave de acesso e
o CPF foram removidos e substituídos por zeros preservando o formato. As asserções testam a
lógica, não o dado.

*Estado: implementado. **Verificação de que o formato foi preservado: existe, mas manual.***

## Alternativas consideradas

### Guard que bloqueia CNPJ por precaução

Nenhuma proteção real — o número é público e recuperável. O único efeito foi exigir revisão
de fixtures legítimos e, pior, dar **falsa sensação de proteção**: a chave formatada com
hífens era capturada só porque o padrão de CNPJ coincidia com um dos seus grupos. A proteção
do CNPJ nunca sustentou a da chave; era coincidência estrutural.

### Guard só no pre-commit, sem CI

Pre-commit é contornável com `--no-verify`. A CI é o que torna o erro visível a quem não
está no developer's máquina.

### Foto do cupom como `BYTEA`

Não vaza entre usuários. Descartado: transforma dado pessoal em pixel (não auditável
procurando CPF), sobrecarrega o Postgres com o que ele não faz bem, e não dá caminho de
exclusão com prova.

### Nunca persistir a foto do cupom

Elimina o risco por completo. Descartado: sem o cupom, a revisão de uma linha ambígua não tem
como conferir a origem, e o usuário não consegue auditar o que o sistema entendeu.

### Guardar snapshots completos para auditoria

Facilita o suporte e a depuração. Descartado: `before_data`/`after_data` em JSONB pode
reter exatamente o que a LGPD mandou apagar. Um rastro de auditoria que é um segundo banco de
dados pessoais não é auditoria, é uma segunda violação.

### Apagar o catálogo junto com o usuário

Simetria aparente, resultado errado. O catálogo não é dado pessoal, e apagá-lo quebraria a
identidade de produtos que **outras** pessoas registraram.

## Consequências

**Positivas**

- A exclusão LGPD executa de verdade — ordem correta, sem FK que a aborta — e é testada.
- A chave de acesso nunca toca o repositório, e o guard cobre a forma como ela chega.
- Dado de empresa legível; dado de pessoa bloqueado. A regra é distinguível de um olhar.
- Nenhum pixel no banco, então a exclusão é verificável.

**Negativas e riscos**

- **A foto do cupom no disco sobrevive ao `DELETE FROM users`.** O banco não sabe que o
  arquivo existe, e o cascade não o apaga. Enquanto não houver expurgo, uma exclusão LGPD
  **deixa residuo em disco**. Isto é uma lacuna conhecida, não uma escolha aceitável — é a
  pendência mais urgente desta ADR.
- `audit_log` acumula JSONB e pode reter dado que deveria ter sumido. Precisa de expurgo
  periódico.
- `data_erasure_requests.email` guarda o e-mail depois da exclusão. É necessário para
  responder ao titular, mas é dado pessoal sobrevivente e precisa de prazo de retenção.
- O guard cobre extensões de texto e um conjunto de formatos. Uma imagem de cupom com CPF
  visível **não** é detectada — o `.gitignore` cobre por nome, o que é frágil.
- A verificação de que o formato anônimo foi preservado é manual, não automatizada.

## O que este documento não decide

- Prazo de retenção da foto de cupom e do e-mail em `data_erasure_requests`.
- Como o expurgo do disco se coordena com a exclusão no banco (e o que acontece se o arquivo
  sumir antes do registro, ou o registro sem o arquivo).
- Quem pode solicitar a exclusão e como a identidade do titular é verificada.
- Se o catálogo será exposto publicamente, e se um pedido de exclusão pode exigir apagar
  um item global compartilhado.
- Política de retenção de `audit_log` e de `before_data`/`after_data`.

## Pontos pendentes de revisão

- **Expurgo de imagem de cupom do disco, e sua versão no registro de exclusão.** Prioridade
  máxima: hoje a exclusão deixa resíduo.
- Prazo de retenção do e-mail em `data_erasure_requests`.
- Expurgo de payload de auditoria.
- Extensão do guard: verificar por CPF em imagem é inviável, mas nomear o arquivo de cupom
  de forma previsível reduz o risco de bypass.
- Automatizar a verificação de que o fixture anônimo preserva o formato.
