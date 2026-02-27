-- =============================================================================
-- PROJETO: Análise Logística - Olist Dataset
-- ARQUIVO: limpeza.sql
-- DESCRIÇÃO: Diagnóstico de qualidade dos dados, tratamento de nulos,
--            resolução de duplicatas e criação da View master de logística
-- AUTOR: Marcus Takeyasu
-- DATA: 2026
--
-- DEPENDÊNCIAS: criando_tabelas.sql deve ter sido executado antes
--
-- ORDEM DE EXECUÇÃO DOS ARQUIVOS:
--   1. criando_tabelas.sql
--   2. limpeza.sql          ← você está aqui
--   3. analise_exploratoria.sql
--   4. insights.sql
--
-- RESULTADO FINAL DESTE ARQUIVO:
--   → VIEW: olist_dataset.v_master_logistica
--   Essa view é a base de todas as queries nas etapas seguintes.
--   Ela já entrega os dados limpos, agregados e com as métricas de
--   SLA, lead time e atraso calculadas e prontas para uso.
-- =============================================================================


-- =============================================================================
-- INSPEÇÃO INICIAL DAS TABELAS
-- Leitura rápida para entender o formato dos dados antes de qualquer tratamento
-- =============================================================================

SELECT * FROM olist_dataset.olist_orders LIMIT 10;
SELECT * FROM olist_dataset.olist_order_items LIMIT 10;
SELECT * FROM olist_dataset.olist_sellers LIMIT 10;
SELECT * FROM olist_dataset.olist_customers LIMIT 10;


-- =============================================================================
-- ETAPA 1: DIAGNÓSTICO DE QUALIDADE DOS DADOS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.1 VERIFICAÇÃO DE NULOS — olist_orders
--
-- TÉCNICA: COUNT(*) - COUNT(coluna) retorna o número de nulos,
-- pois COUNT(coluna) ignora NULLs enquanto COUNT(*) conta tudo.
--
-- COLUNAS CRÍTICAS para cálculo de atraso:
--   • order_purchase_timestamp       → data de compra (início do SLA)
--   • order_delivered_customer_date  → data de entrega real
--   • order_estimated_delivery_date  → prazo prometido ao cliente
-- -----------------------------------------------------------------------------
SELECT 
    COUNT(*) AS total_pedidos,
    COUNT(*) - COUNT(order_id)                      AS nulos_order_id,
    COUNT(*) - COUNT(customer_id)                   AS nulos_customer_id,
    COUNT(*) - COUNT(order_status)                  AS nulos_order_status,
    COUNT(*) - COUNT(order_purchase_timestamp)      AS nulos_order_purchase_timestamp,
    COUNT(*) - COUNT(order_approved_at)             AS nulos_order_approved_at,
    COUNT(*) - COUNT(order_delivered_carrier_date)  AS nulos_order_delivered_carrier_date,
    COUNT(*) - COUNT(order_delivered_customer_date) AS nulos_order_delivered_customer_date,
    COUNT(*) - COUNT(order_estimated_delivery_date) AS nulos_estimated_delivery_date
FROM olist_dataset.olist_orders;

-- RESULTADO ESPERADO E DECISÃO DE TRATAMENTO:
-- Das 3 colunas críticas, apenas order_delivered_customer_date possui nulos.
-- Isso é esperado: pedidos cancelados ou em trânsito não têm data de entrega.
-- ESTRATÉGIA: filtrar apenas order_status = 'delivered' elimina a maior parte
-- dos nulos de forma natural. Os nulos remanescentes (pedidos com status
-- 'delivered' mas sem data de entrega) são erros de sistema e serão
-- excluídos com AND order_delivered_customer_date IS NOT NULL.


-- -----------------------------------------------------------------------------
-- VALIDAÇÃO DO FILTRO: visualizando pedidos entregues após limpeza dos nulos
--
-- Já inclui o cálculo de delta_atraso para validar que a lógica faz sentido:
--   positivo → pedido chegou depois do prazo (atraso)
--   negativo → pedido chegou antes do prazo (adiantado)
-- -----------------------------------------------------------------------------
SELECT
    order_id,
    customer_id,
    order_status,
    order_purchase_timestamp,
    order_delivered_customer_date,
    order_estimated_delivery_date,
    (order_delivered_customer_date - order_estimated_delivery_date) AS delta_atraso
FROM olist_dataset.olist_orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NOT NULL;


-- =============================================================================
-- ETAPA 2: RESOLUÇÃO DE DUPLICATAS — olist_order_items
--
-- PROBLEMA: a tabela olist_order_items tem granularidade de ITEM, não de PEDIDO.
-- Um pedido com 3 itens gera 3 linhas com o mesmo order_id.
-- Um JOIN direto com olist_orders sem agregação prévia multiplicaria as linhas,
-- corrompendo qualquer métrica de valor ou contagem.
--
-- SOLUÇÃO: agregar para granularidade de PEDIDO usando GROUP BY order_id.
--
-- DECISÕES DE AGREGAÇÃO:
--   • shipping_limit_date → MIN: usamos o prazo mais restritivo entre os itens,
--     pois o vendedor precisa postar TODOS os itens dentro desse prazo.
--   • price               → SUM: valor total dos produtos do pedido
--   • freight_value       → SUM: custo total de frete do pedido
--   • order_item_id       → COUNT: quantidade de itens no pedido
-- =============================================================================
SELECT
    order_id,
    MIN(shipping_limit_date)    AS shipping_limit_legal,
    SUM(price)                  AS valor_total_produtos,
    SUM(freight_value)          AS valor_total_frete,
    COUNT(order_item_id)        AS total_itens_pedido
FROM olist_dataset.olist_order_items
GROUP BY order_id;


-- =============================================================================
-- ETAPA 3: CRIAÇÃO DA VIEW MASTER — v_master_logistica
--
-- Esta view é o produto final da etapa de limpeza e a base de todo o projeto.
-- Ela une, trata e enriquece os dados em uma única estrutura reutilizável,
-- evitando que toda query de análise precise repetir a mesma lógica de limpeza.
--
-- ESTRUTURA INTERNA (CTEs):
--   1. pedidos_limpos   → filtra apenas pedidos entregues sem nulos críticos
--   2. ranking_itens    → identifica o item principal de cada pedido
--   3. item_principal   → extrai seller_id e product_id do item principal
--   4. itens_agrupados  → consolida os itens para granularidade de pedido
--
-- MÉTRICAS DERIVADAS CALCULADAS NA VIEW:
--   • sla_prometido   = estimated_delivery - purchase (prazo que prometemos)
--   • lead_time_real  = delivered_customer - purchase (tempo que realmente levou)
--   • dias_atraso     = delivered_customer - estimated_delivery
--                       positivo = atrasado | negativo = adiantado | zero = no prazo
-- =============================================================================
CREATE OR REPLACE VIEW olist_dataset.v_master_logistica AS

WITH pedidos_limpos AS (
    -- Filtra apenas pedidos com entrega confirmada e sem inconsistências de data.
    -- Esses são os únicos pedidos onde o cálculo de SLA e atraso faz sentido.
    SELECT
        order_id,
        customer_id,
        order_delivered_carrier_date,
        order_purchase_timestamp,
        order_delivered_customer_date,
        order_estimated_delivery_date
    FROM olist_dataset.olist_orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
),

ranking_itens AS (
    -- Cria um ranking dos itens dentro de cada pedido para identificar o "item principal".
    -- CRITÉRIO: item mais caro tem rank 1. Em caso de empate no preço,
    -- desempata pelo prazo de postagem mais urgente (shipping_limit_date ASC).
    -- Essa escolha garante que o seller_id e product_id representem
    -- o item de maior valor do pedido — o mais relevante para análise.
    SELECT 
        order_id,
        seller_id,
        product_id,
        ROW_NUMBER() OVER(
            PARTITION BY order_id 
            ORDER BY price DESC, shipping_limit_date ASC
        ) AS rank_item
    FROM olist_dataset.olist_order_items
),

item_principal AS (
    -- Extrai apenas o item de maior rank (rank = 1) de cada pedido.
    -- Usado para trazer seller_id e product_id sem duplicar linhas.
    SELECT order_id, seller_id, product_id
    FROM ranking_itens 
    WHERE rank_item = 1
),

itens_agrupados AS (
    -- Consolida os itens para granularidade de pedido (1 linha por order_id).
    -- Veja a seção 1.2 acima para a justificativa de cada função de agregação.
    SELECT
        order_id,
        MIN(shipping_limit_date)    AS shipping_limit_legal,
        SUM(price)                  AS valor_total_produtos,
        SUM(freight_value)          AS valor_total_frete,
        COUNT(order_item_id)        AS total_itens_pedido
    FROM olist_dataset.olist_order_items
    GROUP BY order_id
)

-- JOIN FINAL: une todas as CTEs e enriquece com dados de cliente, vendedor e produto.
-- LEFT JOIN em olist_products pois nem todos os produtos têm peso cadastrado.
SELECT
    pl.*,
    ip.seller_id,
    ip.product_id, 
    p.product_weight_g,                                                                                
    s.seller_state,
    ia.shipping_limit_legal,
    ia.valor_total_produtos,
    ia.valor_total_frete,
    ia.total_itens_pedido,
    c.customer_state,

    -- Métricas derivadas de tempo (em dias inteiros)
    (pl.order_estimated_delivery_date::date - pl.order_purchase_timestamp::date)    AS sla_prometido,   -- Prazo prometido ao cliente
    (pl.order_delivered_customer_date::date - pl.order_purchase_timestamp::date)    AS lead_time_real,  -- Tempo real de entrega
    (pl.order_delivered_customer_date::date - pl.order_estimated_delivery_date::date) AS dias_atraso    -- Desvio do prazo: + atraso | - adiantado

FROM pedidos_limpos pl 
JOIN itens_agrupados ia  ON pl.order_id = ia.order_id 
JOIN item_principal ip   ON pl.order_id = ip.order_id 
JOIN olist_dataset.olist_customers c ON c.customer_id = pl.customer_id
JOIN olist_dataset.olist_sellers s   ON s.seller_id = ip.seller_id
LEFT JOIN olist_dataset.olist_products p ON p.product_id = ip.product_id;