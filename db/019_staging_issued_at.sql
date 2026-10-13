-- =============================================================================
-- home_shopper -- staging_receipts.issued_at: a data declarada pela nota
-- PostgreSQL 16
--
-- Item 5 da fila pós-auditoria (2026-10-12). Pré-requisito da consolidação.
--
-- POR QUE ESTA COLUNA EXISTE
--   `purchase_notes.purchase_date` é `NOT NULL` (db/002): a camada confiável não
--   aceita compra sem data conhecida. O staging nunca carregou a data declarada
--   pela nota, então a informação existia na fonte, era recebida pela ingestão e
--   se perdia antes de chegar à consolidação -- que não tinha o que gravar.
--
-- POR QUE É NULLABLE, E POR QUE NÃO É `created_at`
--   Ausência é um estado honesto: `NULL` significa "a nota não declarou data, ou
--   declarou em formato ilegível". É isso que faz a nota aparecer incompleta para
--   a consolidação (a ADR-0002 permite bloquear por falta de data ou de
--   estabelecimento), em vez de inventar um dia.
--   `created_at`/`updated_at` registram OUTRO fato -- quando a nota chegou ao
--   sistema. Copiar o horário do upload para a data da compra gravaria dado falso
--   e contaminaria a comparação de preços, que é indexada por data da compra.
--
-- CONVENÇÃO DE LEITURA (não muda aqui)
--   A única regra de parsing do projeto é `load_receipts.iso_date`: aceita
--   `purchase_date` (YYYY-MM-DD) e `emission` (DD/MM/YYYY HH:MM:SS) e devolve a
--   data ISO. A ingestão lê aliases (`issued_at`, `emission`, `purchase_date`) e
--   usa ESSA função -- nada de uma segunda regra para a mesma data.
--
-- O QUE ESTA COLUNA NÃO FAZ
--   Não deriva a data do AAMM da chave de acesso. Para as 15 notas históricas
--   isso foi uma preparação de dados pontual (internal task / db/017), não uma regra do
--   pipeline: a derivação só dá mês/ano, e escolher o dia seria invenção. Onde a
--   nota não declara a data, a pendência é resolvida na revisão humana.
--
-- POR QUE UM ARQUIVO NOVO
--   001..018 estão aplicados e publicados; editá-los faria o banco canônico e um
--   banco novo divergirem (mesma razão registrada em db/009).
--
-- EFEITO
--   `ADD COLUMN IF NOT EXISTS`: idempotente. Linhas existentes ficam `NULL`
--   (desconhecido) -- nada é inferido, nada é retro-preenchido.
-- =============================================================================

BEGIN;

ALTER TABLE staging_receipts
    ADD COLUMN IF NOT EXISTS issued_at DATE;

COMMENT ON COLUMN staging_receipts.issued_at IS
    'Data de emissão declarada pela nota (issued_at/emission). NULL = não declarada ou ilegível. '
    'Não é o momento do upload -- para isso existe created_at.';

COMMIT;
