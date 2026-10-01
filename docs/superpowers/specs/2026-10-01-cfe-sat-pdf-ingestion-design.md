---
title: CF-e-SAT scanned-document intake
project: home_shopper
status: draft-for-user-review
created: 2026-10-01
---

# Design: leitura local de CF-e-SAT por PDF e imagem

## Estado do documento

Este é o desenho aprovado em conversa para revisão escrita. **Ainda não autoriza implementação**: o código começa somente depois da revisão deste arquivo e da aprovação explícita do usuário. A implementação também precisará de um plano aprovado.

## Objetivo

Permitir que a V1 leia **PDFs e imagens digitalizados de CF-e-SAT** de forma local, transforme-os em um candidato estruturado e apresente um relatório para revisão humana. Nenhuma leitura incerta deve chegar à camada confiável ou produzir um preço sem origem verificável.

A finalidade é preservar linhas de compra para comparação futura de preços. O leitor de CF-e-SAT é um adaptador de entrada próprio: o modelo fiscal 59 não deve ser confundido com NFC-e, modelo 65.

## Evidências e restrições

- O repositório está na fase de modelagem. Há schema e testes SQL; não há API nem worker.
- O schema atual já prevê `OCR`, `file_path` e as tabelas de staging. A camada confiável permanece separada.
- Os PDFs de prova fornecidos são escaneados, sem camada de texto. `zbarimg` não encontrou QR neles; o usuário também não identificou QR. Uma varredura OpenCV ampliada do segundo arquivo excedeu o limite de execução e não produziu resultado conclusivo.
- O portal público do SAT apresentou CAPTCHA. A V1 não dependerá de consulta automática por chave nem tentará contornar CAPTCHA.
- O OCR local reconhece cabeçalhos e grande parte das linhas, mas erra ou perde dígitos em campos numéricos. A revisão visual recupera mais informação, porém não é uma fonte automatizada. Um valor que possa ser calculado a partir de quantidade e preço continua desconhecido se não estiver legível na fonte.

## Escopo da V1

### Incluído

- Entrada local: PDF escaneado e imagem raster (PNG/JPEG).
- Inspeção de texto do PDF e tentativa de decodificar QR, se houver. Se nenhum caminho de identificador fornecer o conteúdo, seguir para OCR local.
- OCR local em português, com processamento página a página e recorte da tabela quando necessário.
- Reconhecimento e registro do modelo fiscal CF-e-SAT (59); NFC-e (65) permanece fora deste adaptador.
- Emissão de um candidato JSON privado e de um relatório de validação; o candidato começa em `IN_REVIEW`.
- Validação financeira explícita, sem correção ou preenchimento silencioso de valores.
- Revisão humana antes de qualquer uso em comparação de preços.

### Fora de escopo

- Consultar automaticamente o portal SAT ou resolver CAPTCHA.
- OCR em serviço externo ou envio do documento para terceiros.
- XML/outros formatos de exportação SAT nesta V1.
- Gravação no banco, alteração de schema, API, worker, interface de upload ou promoção à camada confiável.
- Matching automático de produtos, criação de sinônimos ou ajuste de apresentações.
- Alterar o fluxo NFC-e existente.

## Arquitetura proposta

```text
PDF/imagem local
    → validar formato e calcular SHA-256
    → preservar original em armazenamento privado
    → procurar camada de texto / QR disponível
    → OCR local por página e extração de linhas
    → candidato JSON + relatório de validação
    → revisão humana
    → (fora da V1) integração com staging e API
```

### 1. Ingestão e preservação da origem

- Receber um caminho local para um PDF ou uma imagem; validar formato e legibilidade básica.
- Nunca alterar o original. Registrar SHA-256 para reconhecer uma cópia byte a byte do mesmo arquivo; isso não substitui a chave fiscal como identidade da transação.
- Guardar original, candidato e relatório somente em armazenamento privado fora do Git.
- A chave de acesso, quando lida e validada, pode ser mantida no candidato privado como `source_ref`; é dado pessoal e não deve aparecer em logs ou fixtures versionados. O SHA-256 do PDF reconhece apenas uma cópia byte a byte e não substitui a chave fiscal como identidade da transação.
- Não extrair nem persistir CPF do consumidor: esse campo não é necessário para comparar preços.

### 2. Leitura local

- Verificar primeiro se o PDF tem texto utilizável; preservar o texto literal quando existir.
- Tentar decodificar QR localmente se presente, mas não chamar o portal SAT na V1.
- Caso o PDF seja imagem, renderizar as páginas localmente e executar OCR em português. A extração deve preservar referências à página/linha de origem quando possível.
- O reconhecimento de CF-e-SAT deve combinar o cabeçalho do documento com o modelo fiscal da chave quando esta estiver legível. Se esses sinais divergirem, marcar revisão.
- Não usar confiança do OCR como critério suficiente de aceitação; a aritmética e a conferência humana são os gates.

### 3. Contrato do candidato

O candidato JSON representa dados **não confiáveis** e deve conter, no mínimo:

- `document_type: "CFE_SAT"` (classificado pelo cabeçalho) e `fiscal_model: 59` (confirmado pela chave quando legível);
- `source`, com valor `OCR` para a rota de imagem/OCR;
- identificadores e metadados lidos: emissor, CNPJ, chave, número, série, data/hora — cada campo pode ser `null` se não for legível;
- `reported_item_count` quando o documento o imprimir, `extracted_line_count` calculado pelo parser, total bruto, desconto, valor a pagar, valor pago, troco e tributos, mantendo a semântica de cada rótulo;
- `items[]`: número da linha, descrição bruta, código do emissor, unidade, quantidade, preço unitário e total da linha; campos ilegíveis ficam `null`;
- localização de origem da linha (página e, se disponível, retângulo do recorte);
- `status: IN_REVIEW`, erros e resultados dos checks.

O JSON não deve conter o texto OCR completo da página, que pode incluir informações desnecessárias do consumidor. A fonte primária para revisão continua sendo o PDF original.

## Validação e revisão

Valores monetários são processados com `Decimal`, nunca `float`. O relatório deve verificar separadamente:

1. Se o documento declarar quantidade de itens/linhas, comparar com `extracted_line_count`; se não declarar, verificar numeração contígua e marcar a contagem como estrutural, não como dado da fonte.
2. Soma de `line_total` igual a `total_gross` **antes de desconto**.
3. Em cada linha com todos os campos legíveis, `quantity × unit_price`, arredondado a centavos com `ROUND_HALF_UP`, igual a `line_total`.
4. `total_gross − discount_total == amount_payable` quando esses três valores forem explicitamente identificáveis.
5. `amount_paid` lido separadamente; tributos são informativos e não entram na soma da compra.

Se um campo requerido estiver ausente, uma linha falhar ou um total divergir, o candidato permanece `IN_REVIEW`; o relatório aponta página/linha e valor esperado observado, sem preencher o campo. A aritmética pode diagnosticar uma divergência, mas **não pode ser usada para inventar o valor ilegível**.

A V1 nunca promove automaticamente um candidato. A revisão humana deve confirmar os campos e o checksum completo antes de qualquer integração futura. A comparação de identidade do produto continua fora do leitor fiscal.

## Limite entre V1 e o banco

A V1 é um parser local reutilizável e uma CLI de diagnóstico que grava apenas o candidato e o relatório no diretório privado escolhido. Ela não abre conexão com PostgreSQL nem grava compras.

Na futura integração com `staging_receipts`/`staging_lines`, o schema precisará representar `fiscal_model` e `reported_item_count` nullable (nem todo emissor imprime a contagem). `extracted_line_count` é derivado do parser. Campos OCR incertos também precisarão permanecer nulos no staging; os campos correspondentes da camada confiável (`line_items`) continuarão estritos. Os triggers de checksum devem tratar qualquer linha incompleta como pendente, nunca como soma completa. Essas migrações não fazem parte desta V1.

## Privacidade e retenção

- PDFs e candidatos contêm dados de compra; ambos ficam em diretório privado fora do Git. Nenhum conteúdo de PDF vai para `BYTEA`.
- A V1 não envia arquivos a serviços externos e não registra chaves ou dados OCR em logs.
- Os candidatos reais de teste permanecem no scratch privado; testes versionados usam fixtures sintéticos/anonimizados, nunca os PDFs, chaves ou CPF reais.
- O CLI não apaga automaticamente o original nem o candidato; eles permanecem em armazenamento privado até remoção explícita. TTL/expurgo automático não faz parte da V1. A integração de produção precisa implementar a exclusão conjunta conforme ADR-0005.

## Testes e critérios de aceite

### Testes automatizados versionáveis

- Testar parsing de formatos/valores sintéticos anonimizados, campos `null`, arredondamento `ROUND_HALF_UP`, soma de linhas, desconto e valor pago.
- Testar que uma linha incompleta ou divergente produz `IN_REVIEW` e nunca passa o checksum.
- Testar que o CLI não faz chamadas de rede, não conecta ao banco e não modifica o arquivo original.
- Testar que a chave só é considerada válida se tiver 44 dígitos e DV correto; isso não recupera dígitos ausentes.

### Teste local de integração

- Executar nos dois PDFs fornecidos, mantidos fora do Git.
- O resultado aceitável é um candidato estruturado com linhas preservadas e incertezas explícitas. Para as amostras atuais, o status esperado é `IN_REVIEW`, pois ao menos um total de linha não pôde ser lido sem inferência.
- Não marcar o documento como completo apenas porque uma soma calculada a partir de outros campos coincide com o total impresso.

### Critério de conclusão da V1

A V1 está pronta quando um operador consegue executar o CLI sobre PDF/imagem local, encontrar o JSON candidato e o relatório no caminho privado indicado, identificar campos incertos por página/linha, e confirmar que o original não foi alterado. O resultado do CLI é um candidato para revisão, não uma compra importada.

## Consequências

**Positivas**

- Adiciona suporte CF-e-SAT sem confundir o modelo 59 com NFC-e.
- Reutiliza o princípio de staging e de revisão humana sem prometer uma consulta pública automática bloqueada por CAPTCHA.
- Preserva incerteza e valores-fonte; o leitor não fabrica números para fechar totais.
- A V1 é exercitável sem antecipar a API, worker ou escrita no banco.

**Custos e limitações**

- OCR continuará exigindo revisão em imagens degradadas e em layouts novos.
- O candidato local ainda contém dados pessoais e exige armazenamento e limpeza cuidadosos.
- A V1 não alimenta o banco nem as comparações automaticamente.
- A integração futura exige rever schema, triggers, lifecycle dos arquivos, idempotência e isolamento por usuário.
