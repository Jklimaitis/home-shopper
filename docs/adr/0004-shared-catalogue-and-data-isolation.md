---
status: draft
numero: 4
criado: 2026-09-30
---

# ADR-0004: Catálogo compartilhado entre usuários e isolamento de dados de compra

> **Por que este número:** `db/001_schema.sql` e `.env.example` já referenciam
> "ADR-004" para justificar duas coisas — por que o catálogo de produtos é global e por que
> os cupons ficam fora do banco. Nenhum documento com esse número existia. Este rascunho
> cobre as duas. Se ao revisar você preferir números diferentes, basta renumerar e
> atualizar os dois ponteiros no código.

## Contexto

O home_shopper tem duas naturezas de dado que costumam ser tratadas como uma só:

| Dado | Exemplo | É pessoal? | Compartilhável? |
|---|---|---|---|
| Identidade de produto | "Leite integral Italac 1 L" | Não | Sim — todo mundo compra o mesmo leite |
| Identidade de loja | "Supermarket A, CNPJ 00.000.000/0000-00" | Não | Sim |
| **Compra** | "a shopper bought 3 items at the supermarket on 10/07" | **Sim** | **Não** |
| Chave de acesso | 44 dígitos da NFC-e | **Sim** (porta de entrada) | **Não** |
| Foto do cupom | imagem com CPF e endereço | **Sim** | **Não** |

A tentação de colocar tudo em tabelas por usuário resolve um problema que não existe
(`products` duplicado por usuário) e cria um problema real: se "leite Italac 1 L" for criado
novamente por outro usuário, são duas identidades para o mesmo fato, e a comparação entre
lojas passa a comparar coisas que não são iguais.

A tensão real é outra: **o que é compartilhado pode vazar o que é individual.** Se o catálogo
global carrega o texto exato que veio do cupom de alguém, ele publica a descrição da
compra de uma pessoa junto com a identidade do produto.

## Decisão registrada

### 1. O catálogo é global. As compras são isoladas por `user_id`

`products`, `categories`, `stores` e `presentations` **não têm `user_id`**. São partilhados
por todos os usuários por desenho.

`staging_receipts`, `purchase_notes`, `line_items`, `price_refs` e `price_alerts` **têm
`user_id` NOT NULL** e são isolados. Toda consulta de negócio filtra por `user_id`; não é
opcional, é a condição de acesso.

O teste que justifica a separação: `price_refs` sem `user_id` colapsaria duas compras do
mesmo item na mesma loja e no mesmo dia na mesma chave única, e uma pessoa veria o preço da
outra. O `user_id` não é metadado de auditoria aqui — é parte da identidade do fato.

### 2. O texto do cupom que identifica o produto é requisito, não sujeira

Para que o catálogo seja reutilizável, ele precisa guardar a forma como cada loja escreve o
item. É exatamente `presentations.description_raw` + `description_norm` + `match_key`.

O risco é concreto: a descrição pode carregar informação da compra. `BIFE DO VAZIO IQF SWIFT
1kg` não revela nada sobre quem comprou; uma descrição com número de lote, promoção
personalizada ou nome do operador **sim**.

**Limite:** a descrição de **produto** é global e compartilhável; a descrição que carrega
contexto de compra — lote, preço negociado, cupom individual, nome do operador, promoção
personalizada — não entra no catálogo. Quando a única forma de identificar o produto exigir
esse contexto, a linha vai para revisão manual e a identidade fica pendente. A escolha é
favorável à revisão: um item sem identidade é um item que não compara, não um item que
publica dado de terceiro.

### 3. Dado de empresa é público; dado de pessoa não é

O **CNPJ** do estabelecimento identifica pessoa jurídica. O cadastro é público, o número
está impresso no cupom e na fachada, e qualquer um consulta na Receita sem autenticação.
Sanitizá-lo não protege ninguém — o mesmo número é recuperável em segundos. Por isso CNPJ de
loja **não** é dado sensível e não é bloqueado pelo guard do repositório. Um `stores` com as
redes reais é o que dá credibilidade ao projeto.

O mesmo raciocínio **não** se aplica a um CNPJ de MEI em que o proprietário é o próprio
titular: nesse caso o CNPJ funciona como identificador individual.

Já a **chave de acesso** é dado pessoal. Quem a possui consulta a nota na SEFAZ sem
autenticar e obtém CPF, endereço e histórico de compras. O guard bloqueia a chave — **e
também na forma formatada com hífens**, que é como ela sai do app da SEFAZ. A chave embute o
CNPJ do emitente (posições 7–20), mas continua bloqueada porque carrega o dado do consumidor.

### 4. Nenhum BLOB: cupom e foto vivem no disco, o banco guarda o caminho

`staging_receipts.file_path` é `TEXT`. Zero bytes de imagem no banco.

Três razões, nenhuma estética:

1. **Postgres não é armazenamento de objetos.** Serving, CDN, upload multipart e
   redimensionamento não são o que ele faz bem.
2. **A imagem é o dado mais perigoso do projeto.** O cupom mostra CPF, endereço, itens e
   valores. Uma foto no banco é dado pessoal em formato que ninguém consegue auditar
   procurando um CPF, porque é pixels.
3. **Exclusão LGPD fica auditável.** Deletar o arquivo é verificável; apagar bytes dentro de
   um `BYTEA` e depois provar que foram apagados, não.

`.env.example` já aponta para este documento na seção de armazenamento. `STORAGE_DIR` e
`MAX_UPLOAD_MB` existem, e `uploads/`, `cupom*.jpg`, `storage/` e `media/` estão no
`.gitignore`.

### 5. Audit log e pedidos de exclusão sobrevivem ao usuário

Dois registros não têm FK para `users`, de propósito:

- `audit_log.user_id` — é **metadado de autor**, não dado de negócio, e um registro de que
  algo aconteceu precisa sobreviver a quem o fez. Com FK, apagar o usuário aborta: o
  `CASCADE` dispara o trigger de auditoria **dentro** da transação que ainda não removeu o
  usuário. Reproduzido antes da correção: `insert or update on table "audit_log" violates
  foreign key constraint`. A exclusão LGPD ficaria impossível de executar.
- `data_erasure_requests` — é a prova da exclusão, escrita **antes** do `DELETE`. O registro
  documenta um evento que o próprio evento apaga.

O `DELETE FROM users` em cascada leva notas, staging e alertas. O catálogo
(`products`, `stores`, `presentations`) **sobrevive**: não é dado pessoal, e apagá-lo
destruiria a identidade compartilhada de todo mundo.

## Alternativas consideradas

### Catálogo privado por usuário

Cada pessoa teria seu próprio `products`. Descartado: duplicaria a identidade do mesmo item
em N cadastros, e a comparação entre lojas — que é o projeto inteiro — passaria a
depender de um mapeamento entre catálogos privados que ninguém mantém. O problema que
resolveria (vazamento) é melhor resolvido no ponto 2.

### Catálogo global, mas com o texto bruto do cupom

Permitiria casar por string sem revisão. Descartado: carrega contexto de compra para um
dado compartilhado, e reintroduz o vazamento que o isolamento impedia.

### BLOB no banco, com filtro por `user_id`

Não vazaria entre usuários. Descartado: torna a auditoria de dado pessoal insolúvel (é
pixel), sobrecarrega o Postgres com o que ele não faz bem, e não oferece caminho de
exclusão auditável.

### Foto do cupom só em memória, nunca persistida

Elimina o risco por completo. Descartado: sem o cupom, a revisão de uma linha ambígua não
tem como conferir a origem, e o usuário perde a capacidade de auditar o que o sistema
entendeu.

### Manter o guard bloqueando CNPJ por precaução

Nenhuma proteção real: o número é público. Descarado como custo sem benefício — a única
coanca real era evitar revisão, e ela custou um buraco: a chave de acesso formatada com
hífens só era capturada porque o grupo de 14 dígitos do CNPJ disparava o padrão de CNPJ.
**A proteção do CNPJ nunca sustentou a da chave; era coincidência estrutural.**

## Consequências

**Positivas**

- O catálogo cresce com o uso de qualquer pessoa, e a comparação entre lojas funciona sem
  mapeamento privado.
- `user_id` como parte da chave de `price_refs` impede vazamento de preço entre contas.
- Nenhum pixel no banco: a exclusão LGPD é verificável.
- O guard protege a pessoa física (CPF, chave) e deixa o dado público legível.

**Negativas e riscos**

- **Qualquer consulta nova precisa lembrar do filtro por `user_id`.** Não há proteção de
  banco contra isso: o isolamento é disciplina de aplicação, e views como `v_best_price`
  recebem `user_id` como coluna justamente paraRemindar quem escreve a próxima. Uma view
  nova sem essa coluna reintroduz o vazamento. *Isto é o risco real desta ADR e o primeiro
  a resolver na próxima revisão.*
- O texto de identificação do produto é o ponto de maior tensão: é ele que torna o catálogo
  reutilizável e, ao mesmo tempo, o campo onde um dado de compra poderia vazar. A fronteira
  descrita no ponto 2 é uma regra de revisão humana, não uma restrição do banco.
- A foto do cupom no disco exige política de retenção, backup e expurgo que ainda não
  existe: um arquivo de cupom não é apagado por `DELETE FROM users`, e o banco não sabe
  que ele existe.
- `audit_log` acumula `before_data`/`after_data` em JSONB e pode reter dado que a LGPD
  mandaria apagar. Não há política de expurgo definida.

## Estado no código

Implementado e coberto por teste:

- `products`, `categories`, `stores`, `presentations` sem `user_id`; as cinco tabelas de
  negócio com `user_id NOT NULL`.
- `uk_price_refs_user_product_store_date` inclui `user_id` na chave.
- `file_path TEXT` em `staging_receipts`; nenhum tipo BLOB no schema.
- `audit_log` e `data_erasure_requests` sem FK para `users`.
- Asserção R3: exclusão LGPD remove os dados e **preserva** o rastro de auditoria, exatamente
  como este documento descreve.
- Guard: CPF e chave de acesso bloqueados nas duas formas; CNPJ de pessoa jurídica passa.

## O que este documento não decide

- Política de retenção e expurgo dos arquivos de cupom no disco (fora do banco).
- Expurgo de `before_data`/`after_data` em `audit_log` ao longo do tempo.
- Autorização e escopo de escrita no catálogo global: quem pode criar produto, apresentação
  ou sinônimo, e se a criação por um usuário é aceita por todos os outros.
- Procedimento de correção de um item global já errado, e como evitar que um erro de um
  usuário contamine a comparação dos outros.
- Se o catálogo será público para consulta, somente leitura, ou jamais exposto.

## Pontos pendentes de revisão

- Reforçar o isolamento por `user_id` de forma verificável (teste que falhe quando uma view
  nova não recebe `user_id`), em vez de depender de disciplina.
- Definir retenção e expurgo de imagens de cupom.
- Definir expurgo de payload de auditoria.
- Autorização para escrita no catálogo compartilhado e revisão entre usuários.
- Procedimento para item global que se revela errado.
