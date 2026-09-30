
-- -----------------------------------------------------------------------------
-- INDICES
-- -----------------------------------------------------------------------------

-- Cadastros
CREATE INDEX idx_produto_categoria ON produto (categoria_id);
CREATE INDEX idx_produto_marca ON produto (marca) WHERE marca IS NOT NULL;
-- EAN e raros (0 de 14 na nota real), mas quando existe e a chave mais forte.
CREATE UNIQUE INDEX uq_produto_ean ON produto (ean) WHERE ean IS NOT NULL;
-- Busca por nome na UI e no matching.
CREATE INDEX idx_produto_nome ON produto USING gin (nome_canonico gin_trgm_ops);

-- Sinonimos: o caminho quente da busca.
CREATE UNIQUE INDEX uq_sinonimo ON sinonimo (termo, escopo);
CREATE INDEX idx_sinonimo_expande ON sinonimo (expande_para);

-- De-para
CREATE INDEX idx_apres_chave ON apresentacao (chave);
CREATE INDEX idx_apres_produto ON apresentacao (produto_id);
CREATE INDEX idx_apres_prod_unid ON apresentacao (produto_id, unidade_venda);

-- Staging
CREATE INDEX idx_stg_nota_user_status ON staging_nota (user_id, status);
-- Idempotencia: reprocessar a mesma origem nao duplica staging.
CREATE UNIQUE INDEX uq_stg_nota_origem ON staging_nota (user_id, origem, ref_norm)
    WHERE ref_norm <> '';
CREATE INDEX idx_stg_item_nota ON staging_item (nota_id);
-- Fila de revisao humana: itens que nao casaram com nenhum produto.
CREATE INDEX idx_stg_item_sem_match ON staging_item (produto_id)
    WHERE produto_id IS NULL;
CREATE INDEX idx_stg_item_apres ON staging_item (apres_id);

-- Transacoes
CREATE INDEX idx_nota_user_data ON nota (user_id, data_compra DESC);
CREATE INDEX idx_nota_mercado_data ON nota (mercado_id, data_compra DESC);
CREATE UNIQUE INDEX uq_nota_chave ON nota (user_id, chave_acesso)
    WHERE chave_acesso IS NOT NULL;
CREATE INDEX idx_item_nota_nota ON item_nota (nota_id);
CREATE INDEX idx_item_nota_produto ON item_nota (produto_id);
CREATE INDEX idx_item_nota_apres ON item_nota (apres_id);

-- Analise
CREATE INDEX idx_preco_ref_prod_data ON preco_ref (produto_id, data_ref DESC);
CREATE INDEX idx_preco_ref_merc_data ON preco_ref (mercado_id, data_ref DESC);
CREATE INDEX idx_preco_ref_lookup ON preco_ref (produto_id, mercado_id, data_ref DESC);
CREATE INDEX idx_alerta_user_lido ON alerta_preco (user_id, lido, gerado_em DESC);
CREATE INDEX idx_auditoria_user_em ON auditoria (user_id, em DESC);

-- -----------------------------------------------------------------------------
-- VIEWS
-- -----------------------------------------------------------------------------

-- Preco de referencia mais recente por PRODUTO E POR REDE.
--
-- O max() precisa ser por (produto_id, mercado_id). Filtrando so por
-- produto, a view devolvia 1 linha por produto e as redes com preco
-- nunca apareciam juntas -- isto e, a comparacao entre redes, que da
-- nome ao projeto, nao existia em lugar nenhum.
CREATE VIEW v_preco_atual AS
SELECT
    pr.produto_id,
    p.nome_canonico,
    p.marca,
    c.nome AS categoria,
    pr.mercado_id,
    m.nome AS supermercado,
    pr.data_ref,
    p.unidade_base,
    pr.preco_base,
    pr.min_30d,
    pr.max_30d,
    pr.var_pct_30d
FROM preco_ref pr
JOIN produto p        ON p.id = pr.produto_id
JOIN supermercado m   ON m.id = pr.mercado_id
LEFT JOIN categoria c ON c.id = p.categoria_id
WHERE pr.data_ref = (
    SELECT max(pr2.data_ref)
      FROM preco_ref pr2
     WHERE pr2.produto_id = pr.produto_id
       AND pr2.mercado_id = pr.mercado_id
);

-- Melhor e pior preco por produto entre as redes que o usuario visitou.
-- Derivado de v_preco_atual, entao herda o filtro por (produto, rede).
-- Precisa existir separada: a view acima responde "quanto custa em cada
-- rede", esta responde "onde comprar mais barato".
CREATE VIEW v_melhor_preco AS
SELECT
    produto_id,
    nome_canonico,
    marca,
    categoria,
    unidade_base,
    count(*) AS redes,
    min(preco_base) AS melhor_preco,
    max(preco_base) AS pior_preco,
    round(
        (max(preco_base) - min(preco_base))
        / nullif(min(preco_base), 0) * 100, 2
    ) AS dispersao_pct,
    (array_agg(mercado_id ORDER BY preco_base))[1] AS melhor_mercado_id,
    (array_agg(supermercado ORDER BY preco_base))[1] AS melhor_supermercado
FROM v_preco_atual
GROUP BY produto_id, nome_canonico, marca, categoria, unidade_base
HAVING count(*) > 1;

-- Comparativo de cesta equivalente: o MESMO produto canonico visto em mais
-- de uma rede nos ultimos 30 dias. Sem preco_base, isto seria ruido.
CREATE VIEW v_comparativo AS
SELECT
    p.id AS produto_id,
    p.nome_canonico,
    p.unidade_base,
    count(DISTINCT pr.mercado_id) AS redes,
    min(pr.preco_base) AS melhor_preco,
    max(pr.preco_base) AS pior_preco,
    round(
        (max(pr.preco_base) - min(pr.preco_base))
        / nullif(min(pr.preco_base), 0) * 100, 2
    ) AS dispersao_pct
FROM preco_ref pr
JOIN produto p ON p.id = pr.produto_id
WHERE pr.data_ref >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY p.id, p.nome_canonico, p.unidade_base
HAVING count(DISTINCT pr.mercado_id) > 1;

-- Gasto mensal: a inflacao pessoal.
CREATE VIEW v_gasto_mensal AS
SELECT
    n.user_id,
    n.mercado_id,
    m.nome AS supermercado,
    date_trunc('month', n.data_compra)::DATE AS mes,
    sum(n.valor_total) AS total_gasto,
    count(*) AS qtd_notas
FROM nota n
JOIN supermercado m ON m.id = n.mercado_id
GROUP BY n.user_id, n.mercado_id, m.nome,
         date_trunc('month', n.data_compra);

-- Fila de trabalho da tela de conferencia: o que precisa de olho humano.
-- Prioriza divergencia contabil (valor fechado errado) acima de item sem match.
CREATE VIEW v_pendencias AS
SELECT
    sn.id AS staging_id,
    sn.user_id,
    sn.origem,
    sn.status,
    sn.total_bruto,
    sn.desconto_total,
    sn.total_pago,
    sn.total_calculado,
    sn.divergencia_cents,
    m.nome AS supermercado,
    count(si.id) FILTER (WHERE si.produto_id IS NULL AND NOT si.descartado)
        AS itens_sem_match,
    count(si.id) FILTER (WHERE NOT si.conferido AND NOT si.descartado)
        AS itens_para_conferir,
    count(si.id) AS total_itens
FROM staging_nota sn
LEFT JOIN supermercado m ON m.id = sn.mercado_id
-- LEFT JOIN, nao JOIN: uma nota sem nenhum item (falha de ingestao, ou
-- upload que o parser nao conseguiu abrir) precisa aparecer na fila. Com
-- JOIN interno ela some -- e a nota que o usuario precisa para entender
-- o que houve e a unica que o sistema esconderia dele.
LEFT JOIN staging_item si ON si.nota_id = sn.id
WHERE sn.status IN ('PENDENTE', 'EM_REVISAO')
GROUP BY sn.id, sn.user_id, sn.origem, sn.status, sn.total_bruto,
         sn.desconto_total, sn.total_pago, sn.total_calculado,
         sn.divergencia_cents, m.nome
ORDER BY abs(sn.divergencia_cents) DESC NULLS LAST,
         count(si.id) FILTER (WHERE si.produto_id IS NULL) DESC;

COMMIT;
