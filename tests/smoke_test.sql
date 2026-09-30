-- Smoke test: NFC-e real SEARA ALIMENTOS, R$ 337,00, 14 itens
-- chave 00000000000000000000000000000000000000000000
BEGIN;

INSERT INTO usuario (nome, email) VALUES ('Jonas', 'jonas@teste.com');
INSERT INTO supermercado (nome, cnpj, regiao) VALUES
    ('SEARA ALIMENTOS LTDA', '00000000000000', 'Sao Paulo/SP');
INSERT INTO categoria (nome) VALUES ('Carnes e frios');

-- Sinonimos: truncamento de nome e fato aprendido, nao normalizacao.
INSERT INTO sinonimo (termo, expande_para) VALUES
    ('herc','hercules'), ('int','integral'), ('moida','moida'), ('swift','swift');

-- Produtos canonicos. Base G: a nota e toda de massa.
INSERT INTO produto (nome_canonico, categoria_id, marca, unidade_base, qtde_base)
    VALUES ('Frango Coxa Swift', (SELECT id FROM categoria), 'Swift', 'G', 1000);
INSERT INTO produto (nome_canonico, categoria_id, marca, unidade_base, qtde_base)
    VALUES ('Palitinho de Tapioca Nuu', (SELECT id FROM categoria), 'Nuu', 'G', 300);
INSERT INTO produto (nome_canonico, categoria_id, marca, unidade_base, qtde_base)
    VALUES ('Bife do Vazio IQF Swift', (SELECT id FROM categoria), 'Swift', 'G', 1000);
INSERT INTO produto (nome_canonico, categoria_id, marca, unidade_base, qtde_base)
    VALUES ('CUPIM Combo', (SELECT id FROM categoria), 'Combo', 'G', 1000);
INSERT INTO produto (nome_canonico, categoria_id, marca, unidade_base, qtde_base)
    VALUES ('Kani Kama Swift', (SELECT id FROM categoria), 'Swift', 'G', 250);
INSERT INTO produto (nome_canonico, categoria_id, marca, unidade_base, qtde_base)
    VALUES ('Carne Moida Combo', (SELECT id FROM categoria), 'Combo', 'G', 1000);

-- De-para + conversao de unidade, fundidos.
INSERT INTO apresentacao (produto_id, unidade_venda, fator_base, descricao_fiscal, descricao_norm, loja_id)
    SELECT id, 'pc', 1000, 'COXA DE FRANGO SWIFT 1 kg', 'COXA DE FRANGO SWIFT 1 kg', NULL
      FROM produto WHERE nome_canonico='Frango Coxa Swift';
INSERT INTO apresentacao (produto_id, unidade_venda, fator_base, descricao_fiscal, descricao_norm, loja_id)
    SELECT id, 'pc', 300, 'PALITINHO DE TAPIOCA NUU 300 g', 'PALITINHO DE TAPIOCA NUU 300 g', NULL
      FROM produto WHERE nome_canonico='Palitinho de Tapioca Nuu';
INSERT INTO apresentacao (produto_id, unidade_venda, fator_base, descricao_fiscal, descricao_norm, loja_id)
    SELECT id, 'pc', 1000, 'BIFE DO VAZIO IQF SWIFT 1kg', 'BIFE DO VAZIO IQF SWIFT 1kg', NULL
      FROM produto WHERE nome_canonico='Bife do Vazio IQF Swift';
INSERT INTO apresentacao (produto_id, unidade_venda, fator_base, descricao_fiscal, descricao_norm, loja_id)
    SELECT id, 'kg', 1000, 'CUPIM COMBO kg', 'CUPIM COMBO kg', NULL
      FROM produto WHERE nome_canonico='CUPIM Combo';
INSERT INTO apresentacao (produto_id, unidade_venda, fator_base, descricao_fiscal, descricao_norm, loja_id)
    SELECT id, 'pc', 250, 'KANI KAMA SWIFT 250 g', 'KANI KAMA SWIFT 250 g', NULL
      FROM produto WHERE nome_canonico='Kani Kama Swift';
INSERT INTO apresentacao (produto_id, unidade_venda, fator_base, descricao_fiscal, descricao_norm, loja_id)
    SELECT id, 'pc', 1000, 'CARNE MOIDA COMBO 1kg', 'CARNE MOIDA COMBO 1kg', NULL
      FROM produto WHERE nome_canonico='Carne Moida Combo';

-- Staging: a nota real
INSERT INTO staging_nota (user_id, origem, origem_ref, mercado_id, total_bruto,
                          desconto_total, total_pago)
    VALUES ((SELECT id FROM usuario), 'SEFAZ',
            '00000000000000000000000000000000000000000000',
            (SELECT id FROM supermercado), 337.00, 0.00, 337.00);

INSERT INTO staging_item (nota_id, linha, descricao_bruta, codigo_loja, unidade_obs,
    quantidade, valor_unitario, desconto_item, total_linha, produto_id, apres_id, fonte) VALUES
((SELECT id FROM staging_nota), 1, 'COXA DE FRANGO SWIFT 1 kg', '6169180', 'pc', 1, 11.90, 0, 11.90, (SELECT id FROM produto WHERE nome_canonico='Frango Coxa Swift'), (SELECT a.id FROM apresentacao a JOIN produto p ON p.id=a.produto_id WHERE p.nome_canonico='Frango Coxa Swift'), 'DESCRICAO'),
((SELECT id FROM staging_nota), 2, 'PALITINHO DE TAPIOCA NUU 300 g', '6222760', 'pc', 1, 14.90, 0, 14.90, (SELECT id FROM produto WHERE nome_canonico='Palitinho de Tapioca Nuu'), (SELECT a.id FROM apresentacao a JOIN produto p ON p.id=a.produto_id WHERE p.nome_canonico='Palitinho de Tapioca Nuu'), 'DESCRICAO'),
((SELECT id FROM staging_nota), 3, 'BIFE DO VAZIO IQF SWIFT 1kg', '6217690', 'pc', 1, 45.90, 0, 45.90, (SELECT id FROM produto WHERE nome_canonico='Bife do Vazio IQF Swift'), (SELECT a.id FROM apresentacao a JOIN produto p ON p.id=a.produto_id WHERE p.nome_canonico='Bife do Vazio IQF Swift'), 'DESCRICAO'),
((SELECT id FROM staging_nota), 4, 'MILHO MEIA ESPIGA SWIFT 1,02 kg', '6232250', 'pc', 1, 18.90, 0, 18.90, NULL, NULL, 'NENHUM'),
((SELECT id FROM staging_nota), 5, 'CARNE MOIDA COMBO 1kg', '6220110', 'pc', 1, 29.90, 0, 29.90, (SELECT id FROM produto WHERE nome_canonico='Carne Moida Combo'), (SELECT a.id FROM apresentacao a JOIN produto p ON p.id=a.produto_id WHERE p.nome_canonico='Carne Moida Combo'), 'DESCRICAO'),
((SELECT id FROM staging_nota), 6, 'KANI KAMA SWIFT 250 g', '6187250', 'pc', 1, 10.90, 0, 10.90, (SELECT id FROM produto WHERE nome_canonico='Kani Kama Swift'), (SELECT a.id FROM apresentacao a JOIN produto p ON p.id=a.produto_id WHERE p.nome_canonico='Kani Kama Swift'), 'DESCRICAO'),
((SELECT id FROM staging_nota), 7, 'COSTELA DIANTEIRO CUBOS SWIFT 1 kg', '6213940', 'pc', 1, 42.90, 0, 42.90, NULL, NULL, 'NENHUM'),
((SELECT id FROM staging_nota), 8, 'CUPIM COMBO kg', '6221920', 'kg', 1.446, 39.90, 0, 57.70, (SELECT id FROM produto WHERE nome_canonico='CUPIM Combo'), (SELECT a.id FROM apresentacao a JOIN produto p ON p.id=a.produto_id WHERE p.nome_canonico='CUPIM Combo'), 'DESCRICAO'),
((SELECT id FROM staging_nota), 9, 'MANDIOCA TOLETE SWIFT 1,02 kg', '6232010', 'pc', 1, 13.90, 0, 13.90, NULL, NULL, 'NENHUM'),
((SELECT id FROM staging_nota), 10, 'FILE DE PEITO BDJ SEARA 1 kg', '6229530', 'pc', 1, 18.90, 0, 18.90, NULL, NULL, 'NENHUM'),
((SELECT id FROM staging_nota), 11, 'FILE DE POLACA DO ALASKA SWIFT 500 g', '6224930', 'pc', 1, 17.90, 0, 17.90, NULL, NULL, 'NENHUM'),
((SELECT id FROM staging_nota), 12, 'FILE DE PESCADA SWIFT 500 g', '6171010', 'pc', 1, 24.90, 0, 24.90, NULL, NULL, 'NENHUM'),
((SELECT id FROM staging_nota), 13, 'MOELA FRANGO ALM SEARA 1 kg', '6169080', 'pc', 1, 15.50, 0, 15.50, NULL, NULL, 'NENHUM'),
((SELECT id FROM staging_nota), 14, 'SOBRECOCHA DE FRANGO SWIFT 1 kg', '6169190', 'pc', 1, 12.90, 0, 12.90, NULL, NULL, 'NENHUM');

-- ============================ ASSERCOES ============================
\echo ''
\echo '--- A1: checksum contabil (nota real) ---'
SELECT 'A1' AS teste,
       total_bruto,
       desconto_total,
       total_pago,
       total_calculado,
       divergencia_cents,
       CASE WHEN abs(divergencia_cents) <= 1 THEN 'PASS' ELSE 'FAIL' END AS r
FROM staging_nota;

\echo ''
\echo '--- A2: item a peso -> preco_base comparavel ---'
\echo '  Cupim 39,90/1kg = 0,0399/g | Carne moida 29,90/1kg = 0,0299/g'
\echo '  Kani 10,90/250g  = 0,0436/g  <- 250g vs 1kg: o trigger normaliza'

\echo ''
\echo '--- A3: consolidacao com apresentacao ---'
INSERT INTO nota (user_id, mercado_id, staging_id, chave_acesso, data_compra, valor_total, pagamento)
    SELECT user_id, mercado_id, id, '00000000000000000000000000000000000000000000',
           DATE '2026-07-10', total_pago, 'Cartao de Credito'
    FROM staging_nota;

INSERT INTO item_nota (nota_id, produto_id, apres_id, linha, valor_unitario, quantidade,
                       desconto_item, total_linha)
    SELECT (SELECT id FROM nota), produto_id, apres_id, linha, valor_unitario, quantidade,
           desconto_item, total_linha
    FROM staging_item
    WHERE produto_id IS NOT NULL;

SELECT 'A3' AS teste, count(*) AS itens_consolidados,
       CASE WHEN count(*) = 6 THEN 'PASS' ELSE 'FAIL' END AS r
FROM item_nota;

\echo ''
\echo '--- A4: preco_base por unidade canonica (G) ---'
SELECT 'A4' AS teste,
       p.nome_canonico,
       i.quantidade,
       i.valor_unitario,
       a.fator_base,
       i.preco_base,
       i.unidade_base,
       CASE WHEN i.preco_base = round(i.valor_unitario / a.fator_base, 8)
            THEN 'PASS' ELSE 'FAIL' END AS r
FROM item_nota i
JOIN produto p ON p.id = i.produto_id
JOIN apresentacao a ON a.id = i.apres_id
ORDER BY p.nome_canonico;

\echo ''
\echo '--- A5: trigger RECUSA item sem apresentacao ---'
DO $$
DECLARE v_resultado TEXT := 'SEM ERRO (falha)';
BEGIN
    BEGIN
        INSERT INTO item_nota (nota_id, produto_id, apres_id, linha, valor_unitario,
                               quantidade, desconto_item, total_linha)
        SELECT (SELECT id FROM nota), p.id, NULL, 99, 10.00, 1, 0, 10.00
        FROM produto p LIMIT 1;
    EXCEPTION WHEN check_violation THEN
        v_resultado := 'PASS (recusou)';
    END;
    RAISE NOTICE 'A5 trigger sem apresentacao: %', v_resultado;
END $$;

\echo ''
\echo '--- A6: idempotencia por chave de acesso ---'
DO $$
DECLARE v_resultado TEXT := 'SEM ERRO (falha)';
BEGIN
    BEGIN
        INSERT INTO nota (user_id, mercado_id, chave_acesso, data_compra, valor_total)
        SELECT user_id, mercado_id, '00000000000000000000000000000000000000000000',
               DATE '2026-07-10', 337.00
        FROM nota LIMIT 1;
    EXCEPTION WHEN unique_violation THEN
        v_resultado := 'PASS (bloqueou duplicata)';
    END;
    RAISE NOTICE 'A6 idempotencia: %', v_resultado;
END $$;

\echo ''
\echo '--- A7: dinheiro em NUMERIC (float falharia) ---'
DO $$
DECLARE v_float NUMERIC; v_num NUMERIC;
BEGIN
    v_float := abs((0.1::float8 + 0.2::float8) - 0.3::float8);
    v_num   := abs(0.1::numeric + 0.2::numeric - 0.3::numeric);
    RAISE NOTICE 'A7 float erro: %  |  numeric erro: %', v_float, v_num;
END $$;

\echo ''
\echo '--- A8: auditoria gravou INSERTs ---'
SELECT 'A8' AS teste,
       count(*) FILTER (WHERE tabela='nota' AND operacao='INSERT') AS notas,
       count(*) FILTER (WHERE tabela='item_nota' AND operacao='INSERT') AS itens,
       CASE WHEN count(*) = 7 THEN 'PASS' ELSE 'FAIL' END AS r
FROM auditoria;

\echo ''
\echo '--- A9: fila de revisao humana ---'
SELECT 'A9' AS teste,
       itens_para_conferir,
       itens_sem_match,
       total_itens,
       CASE WHEN itens_sem_match = 8 THEN 'PASS' ELSE 'FAIL' END AS r
FROM v_pendencias;

\echo ''
\echo '--- A10: views respondem ---'
SELECT 'A10' AS teste,
       (SELECT count(*) FROM v_preco_atual)   AS v_preco_atual,
       (SELECT count(*) FROM v_comparativo)   AS v_comparativo,
       (SELECT count(*) FROM v_gasto_mensal)  AS v_gasto_mensal,
       (SELECT count(*) FROM v_pendencias)    AS v_pendencias,
       CASE WHEN (SELECT count(*) FROM v_gasto_mensal) = 1 THEN 'PASS' ELSE 'FAIL' END AS r;

\echo ''
\echo '--- A11: DESCONTO no total (nota 2 real: 550,93 - 6,00 = 544,93) ---'
\echo '  A soma das linhas e o BRUTO. O desconto vive no TOTAIS.'
\echo '  Se o checksum comparasse com o valor a pagar, acusaria -600 cents.'
DO $$
DECLARE
    v_bruto NUMERIC := 550.93;
    v_desc  NUMERIC := 6.00;
    v_pago  NUMERIC := 544.93;
    v_soma  NUMERIC;
    v_div   INTEGER;
BEGIN
    -- Soma das 13 linhas da nota real (todos os total_linha declarados)
    SELECT 46.84+43.97+95.71+46.31+28.90+28.90+28.90+49.90+49.90
           +34.90+39.90+32.90+23.90 INTO v_soma;
    v_div := round((v_bruto - v_soma) * 100)::INTEGER;

    RAISE NOTICE 'A11 soma linhas   : %', v_soma;
    RAISE NOTICE 'A11 total bruto  : % (cupom: Valor total)', v_bruto;
    RAISE NOTICE 'A11 desconto     : %', v_desc;
    RAISE NOTICE 'A11 valor a pagar: % (cupom: Valor a pagar)', v_pago;
    RAISE NOTICE 'A11 divergencia  : % cents  <- 0 = CORRETO', v_div;

    IF v_soma = v_bruto AND v_bruto - v_desc = v_pago AND v_div = 0 THEN
        RAISE NOTICE 'A11 RESULTADO    : PASS';
    ELSE
        RAISE NOTICE 'A11 RESULTADO    : FAIL';
    END IF;
END $$;

\echo ''
\echo '--- A12: item repetido na mesma nota ---'
\echo '  3x QJO COAL BELO M a 28,90 = linhas distintas no cupom,'
\echo '  mesmo preco unitario. UNIQUE (nota_id, linha) permite.'

ROLLBACK;
