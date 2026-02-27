-- =============================================================================
-- PROJETO: Análise Logística - Olist Dataset
-- ARQUIVO: analise_exploratoria.sql
-- DESCRIÇÃO: Análise Exploratória de Dados (EDA) sobre o desempenho logístico.
--            Investiga a distribuição do SLA prometido, lead time real,
--            taxa de atraso por região/estado, responsabilidade pelo atraso
--            (vendedor vs transportadora) e outliers.
-- AUTOR: Marcus Takeyasu
-- DATA: 2026
--
-- DEPENDÊNCIAS: limpeza.sql deve ter sido executado antes
--   → VIEW:              olist_dataset.v_master_logistica
--
-- ORDEM DE EXECUÇÃO DOS ARQUIVOS:
--   1. criando_tabelas.sql
--   2. limpeza.sql
--   3. analise_exploratoria.sql   ← você está aqui
--   4. insights.sql
--
-- RESULTADO FINAL DESTE ARQUIVO:
--   → MATERIALIZED VIEW: olist_dataset.mv_outliers_logistica
--   Catálogo de pedidos atrasados classificados como outlier crítico ou
--   atraso normal, segmentados por estado, usando o método IQR por estado.
-- =============================================================================


-- Inspeção rápida da view master para confirmar estrutura antes das análises
SELECT * FROM olist_dataset.v_master_logistica LIMIT 10;


-- =============================================================================
-- BLOCO 1: DISTRIBUIÇÃO ESTATÍSTICA DO SLA PROMETIDO
--
-- OBJETIVO: Entender como a Olist calibra os prazos prometidos ao cliente.
-- Usamos 5-number summary + média e desvio padrão para identificar
-- se a distribuição é simétrica ou assimétrica (presença de outliers).
--
-- RESULTADO ENCONTRADO:
--   Média: ~24,3 dias | Máximo: 156 dias
--   O máximo muito acima da média indica assimetria à direita — há pedidos
--   com SLA absurdamente alto puxando a média. A mediana é mais representativa.
-- =============================================================================
SELECT
    MIN(sla_prometido)                                              AS minimo,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY sla_prometido)    AS q1,
    PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY sla_prometido)    AS mediana,
    ROUND(AVG(sla_prometido), 2)                                    AS media,
    ROUND(STDDEV(sla_prometido), 2)                                 AS desvio_padrao,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY sla_prometido)    AS q3,
    MAX(sla_prometido)                                              AS maximo
FROM olist_dataset.v_master_logistica;


-- =============================================================================
-- BLOCO 2: DISTRIBUIÇÃO GEOGRÁFICA DOS VENDEDORES
--
-- OBJETIVO: Mapear de onde os pedidos estão saindo.
-- Concentração de vendedores em SP/Sudeste pode explicar prazos maiores
-- para regiões distantes (Norte e Nordeste), já que os produtos precisam
-- cruzar o país para chegar ao cliente.
--
-- TÉCNICA: ROLLUP no GROUP BY gera uma linha de subtotal geral automaticamente,
-- sem precisar de UNION ALL com uma query separada.
-- =============================================================================

-- Distribuição por região (com total geral via ROLLUP)
SELECT
    CASE
        WHEN seller_state IN ('AC', 'AP', 'AM', 'PA', 'RO', 'RR', 'TO') THEN 'Norte'
        WHEN seller_state IN ('AL', 'BA', 'CE', 'MA', 'PB', 'PE', 'PI', 'RN', 'SE') THEN 'Nordeste'
        WHEN seller_state IN ('GO', 'MT', 'MS', 'DF') THEN 'Centro-Oeste'
        WHEN seller_state IN ('ES', 'MG', 'RJ', 'SP') THEN 'Sudeste'
        WHEN seller_state IN ('PR', 'RS', 'SC') THEN 'Sul'
        ELSE 'Erro'
    END AS regiao,
    COUNT(*) AS total_vendedores
FROM olist_dataset.v_master_logistica
GROUP BY ROLLUP (regiao)
ORDER BY total_vendedores;

-- Distribuição por estado (granularidade mais fina)
SELECT
    seller_state,
    COUNT(*) AS total_pedidos
FROM olist_dataset.v_master_logistica
GROUP BY seller_state;


-- =============================================================================
-- BLOCO 3: ANÁLISE DOS EXTREMOS DE SLA — MUITO CURTO E MUITO LONGO
--
-- OBJETIVO: Identificar dois comportamentos problemáticos opostos na calibração
-- do SLA: prometer rápido demais (e atrasar) vs. prometer lento demais (e
-- desestimular a compra por prazo alto mesmo entregando antes).
-- =============================================================================

-- 3.1 SLA CURTO (≤ 5 dias): pedidos de entrega rápida — estado a estado
-- Verificando quais rotas recebem esse prazo agressivo
SELECT
    seller_state,
    customer_state,
    order_estimated_delivery_date,
    order_delivered_customer_date,
    (order_delivered_customer_date::date - order_estimated_delivery_date::date) AS dias_atraso
FROM olist_dataset.v_master_logistica
WHERE sla_prometido <= 5;

-- 3.2 TAXA DE ATRASO para SLA ≤ 5 dias
-- RESULTADO ENCONTRADO: ~20% desses pedidos atrasam.
-- Conclusão: para entregas rápidas, a Olist promete algo que a operação
-- não consegue cumprir consistentemente.
SELECT
    COUNT(*) AS total_pedidos,
    SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END) AS pedidos_atrasados,
    ROUND(SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END) * 100.0 / COUNT(*)) || '%' AS percentual_atraso
FROM olist_dataset.v_master_logistica
WHERE sla_prometido <= 5;

-- 3.3 TAXA DE ATRASO para SLA ≥ 50 dias
-- RESULTADO ENCONTRADO: taxa de atraso muito baixa — os pedidos chegam bem antes.
-- Conclusão: a margem de SLA está superdimensionada para esses casos.
-- Reduzir o SLA prometido para esses pedidos pode aumentar a conversão,
-- pois o cliente verá um prazo mais atrativo sem aumentar o risco de atraso.
SELECT
    COUNT(*) AS total_pedidos,
    SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END) AS pedidos_atrasados,
    ROUND(SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END) * 100.0 / COUNT(*)) || '%' AS percentual_atraso
FROM olist_dataset.v_master_logistica
WHERE sla_prometido >= 50;

-- 3.4 Detalhamento das rotas com SLA ≥ 50 dias
SELECT
    seller_state,
    customer_state,
    order_estimated_delivery_date,
    order_delivered_customer_date,
    (order_delivered_customer_date::date - order_estimated_delivery_date::date) AS dias_atraso
FROM olist_dataset.v_master_logistica
WHERE sla_prometido >= 50;


-- =============================================================================
-- BLOCO 4: DISTRIBUIÇÃO ESTATÍSTICA DO LEAD TIME REAL
--
-- OBJETIVO: Entender como a operação performa na prática, independente do
-- prazo prometido. Comparar com o SLA para identificar o gap entre
-- expectativa (prometido) e realidade (entregue).
--
-- RESULTADO ENCONTRADO:
--   Mediana: ~12 dias | Máximo: 156 dias
--   Padrão similar ao SLA: máximo muito alto, assimetria à direita.
-- =============================================================================
SELECT
    MIN(lead_time_real)                                             AS minimo,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY lead_time_real)   AS q1,
    PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY lead_time_real)   AS mediana,
    ROUND(AVG(lead_time_real), 2)                                   AS media,
    ROUND(STDDEV(lead_time_real), 2)                                AS desvio_padrao,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY lead_time_real)   AS q3,
    MAX(lead_time_real)                                             AS maximo
FROM olist_dataset.v_master_logistica;


-- =============================================================================
-- BLOCO 5: PERFORMANCE LOGÍSTICA POR REGIÃO E ESTADO
--
-- OBJETIVO: Identificar onde estão os gargalos geográficos.
-- Três perguntas guiam essa análise:
--   1. Onde está o volume? (share_pedidos)
--      → Se SP tem 40% dos pedidos, qualquer melhoria lá impacta o resultado global.
--   2. Onde o SLA é descalibrado? (percentual_atraso)
--      → Alta taxa de atraso = prazo prometido incompatível com a operação real.
--   3. Onde a operação é lenta? (tempo_medio_entrega)
--      → Comparar estados vizinhos (ex: RJ vs SP) isola se o problema é
--        estrutural do estado ou específico de uma rota.
--
-- TÉCNICA: SUM(COUNT(*)) OVER() calcula o total geral como window function,
-- permitindo calcular o share de cada linha sem subquery extra.
-- =============================================================================

-- 5.1 Por região (visão macro)
SELECT
    CASE 
        WHEN customer_state IN ('AC', 'AP', 'AM', 'PA', 'RO', 'RR', 'TO') THEN 'Norte'
        WHEN customer_state IN ('AL', 'BA', 'CE', 'MA', 'PB', 'PE', 'PI', 'RN', 'SE') THEN 'Nordeste'
        WHEN customer_state IN ('GO', 'MT', 'MS', 'DF') THEN 'Centro-Oeste'
        WHEN customer_state IN ('ES', 'MG', 'RJ', 'SP') THEN 'Sudeste'
        WHEN customer_state IN ('PR', 'RS', 'SC') THEN 'Sul'
        ELSE 'Erro'
    END AS regiao,
    ROUND(AVG(lead_time_real), 2)   AS tempo_medio_entrega,
    ROUND(AVG(sla_prometido), 2)    AS media_sla_prometido,
    COUNT(*)                        AS qtd_pedido,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) || '%' AS share_pedidos,
    SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END) AS pedidos_atrasados,
    ROUND(SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) || '%' AS percentual_atraso
FROM olist_dataset.v_master_logistica
GROUP BY regiao
ORDER BY ROUND(SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) DESC;

-- 5.2 Por estado (granularidade para identificar casos específicos como RJ)
SELECT
    customer_state,
    ROUND(AVG(lead_time_real), 2)   AS tempo_medio_entrega,
    ROUND(AVG(sla_prometido), 2)    AS media_sla_prometido,
    COUNT(*)                        AS qtd_pedido,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) || '%' AS share_pedidos,
    SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END) AS pedidos_atrasados,
    ROUND(SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) || '%' AS percentual_atraso
FROM olist_dataset.v_master_logistica
GROUP BY customer_state
ORDER BY ROUND(SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) DESC;


-- =============================================================================
-- BLOCO 6: SLA HIT RATE — MÉTRICA GLOBAL DE PONTUALIDADE
--
-- OBJETIVO: Calcular o indicador-chave de performance logística:
-- qual percentual dos pedidos foi entregue dentro do prazo prometido.
-- Esse número é o KPI central do projeto e o ponto de partida para
-- qualquer negociação com transportadoras ou ajuste de SLA.
-- =============================================================================
SELECT
    COUNT(*) AS total_pedidos,
    SUM(CASE WHEN lead_time_real <= sla_prometido THEN 1 ELSE 0 END) AS no_prazo,
    SUM(CASE WHEN lead_time_real > sla_prometido  THEN 1 ELSE 0 END) AS atrasado,
    ROUND(SUM(CASE WHEN lead_time_real <= sla_prometido THEN 1 ELSE 0 END)::numeric / COUNT(*) * 100, 2) || '%' AS sla_hit_rate,
    ROUND(SUM(CASE WHEN lead_time_real > sla_prometido  THEN 1 ELSE 0 END)::numeric / COUNT(*) * 100, 2) || '%' AS atraso_rate
FROM olist_dataset.v_master_logistica;


-- =============================================================================
-- BLOCO 7: CLASSIFICAÇÃO DE SEVERIDADE DOS ATRASOS
--
-- OBJETIVO: Ir além do binário "atrasou / não atrasou" e segmentar os atrasos
-- por gravidade para priorizar ações corretivas.
--
-- FAIXAS DEFINIDAS:
--   Leve    (≤ 3 dias) → tolerável, baixo impacto na experiência do cliente
--   Moderado (4-7 dias) → visível, risco de reclamação ou avaliação negativa
--   Crítico  (> 7 dias) → alto impacto, provável contato com suporte e churn
--
-- TÉCNICA: GROUP BY 1 referencia a primeira coluna do SELECT (o CASE),
-- evitando repetir toda a expressão no GROUP BY.
-- =============================================================================
SELECT
    CASE 
        WHEN (lead_time_real <= sla_prometido)          THEN '0. No prazo'
        WHEN (lead_time_real - sla_prometido) <= 3      THEN '1. Atraso Leve (Até 3 dias)'
        WHEN (lead_time_real - sla_prometido) <= 7      THEN '2. Atraso Moderado (4-7 dias)'
        ELSE                                                 '3. Atraso Crítico (> 7 dias)'
    END AS faixa_atraso,
    COUNT(*) AS qtd_atrasos,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) || '%' AS percentual
FROM olist_dataset.v_master_logistica
GROUP BY 1
ORDER BY 1;


-- =============================================================================
-- BLOCO 8: DIAGNÓSTICO DE RESPONSABILIDADE — VENDEDOR VS TRANSPORTADORA
--
-- OBJETIVO: Identificar quem é o responsável pelos atrasos para direcionar
-- a ação corretiva correta. Há três cenários possíveis:
--
-- LÓGICA DE ATRIBUIÇÃO:
--   • Atraso do VENDEDOR:
--     O vendedor postou o produto DEPOIS do prazo limite (shipping_limit_legal).
--     → order_delivered_carrier_date > shipping_limit_legal
--
--   • Atraso da TRANSPORTADORA:
--     O tempo que a transportadora levou após receber o produto foi maior
--     do que o tempo que ela tinha disponível segundo o SLA.
--     → (estimated_delivery - shipping_limit) < (delivered_customer - delivered_carrier)
--
--   • Atraso de AMBOS: os dois critérios acima são verdadeiros simultaneamente.
--
-- INTERPRETAÇÃO DOS RESULTADOS:
--   Se atraso_vendedor for dominante    → treinamento e/ou penalização dos lojistas
--   Se atraso_transportadora for dominante → renegociação de contratos de frete
--                                            ou aumento do SLA prometido no site
--   Se atraso_ambos for alto            → sistema de cálculo de prazo descalibrado
--                                         para certas rotas
-- =============================================================================
SELECT
    COUNT(*)                                                                        AS total_pedidos,
    SUM(CASE WHEN lead_time_real > sla_prometido
        THEN 1 ELSE 0 END)                                                          AS pedidos_atrasados,

    -- Vendedor postou após o prazo limite
    SUM(CASE WHEN lead_time_real > sla_prometido
             AND order_delivered_carrier_date > shipping_limit_legal
        THEN 1 ELSE 0 END)                                                          AS atraso_vendedor,

    -- Transportadora demorou mais do que tinha disponível no SLA
    SUM(CASE WHEN lead_time_real > sla_prometido
             AND (order_estimated_delivery_date - shipping_limit_legal) 
                 < (order_delivered_customer_date - order_delivered_carrier_date)
        THEN 1 ELSE 0 END)                                                          AS atraso_transportadora,

    -- Ambos falharam simultaneamente
    SUM(CASE WHEN lead_time_real > sla_prometido
             AND order_delivered_carrier_date > shipping_limit_legal
             AND (order_estimated_delivery_date - shipping_limit_legal) 
                 < (order_delivered_customer_date - order_delivered_carrier_date)
        THEN 1 ELSE 0 END)                                                          AS atraso_ambos
FROM olist_dataset.v_master_logistica;


-- =============================================================================
-- BLOCO 9: ANÁLISE TEMPORAL — VOLUME E ATRASO POR DIA DA SEMANA
--
-- OBJETIVO: Verificar se o dia da compra influencia o risco de atraso.
-- A hipótese é que pedidos feitos próximos ao fim de semana demoram mais
-- para ser postados, pois vendedores não operam aos sábados e domingos.
--
-- DUAS PERSPECTIVAS:
--   9.1 Taxa de atraso por dia → qual dia de compra gera mais atrasos
--   9.2 Decomposição do tempo  → separar o tempo de postagem (vendedor)
--       do tempo de transporte (transportadora) por dia da semana
-- =============================================================================

-- 9.1 Taxa de atraso por dia da semana
SELECT
    TO_CHAR(order_purchase_timestamp, 'TMDay') AS dia_semana,
    COUNT(order_id) AS total_pedidos,
    SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END) AS pedidos_atrasados,
    ROUND(SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END) * 100.0 / COUNT(order_id), 2) || '%' AS percentual_atraso
FROM olist_dataset.v_master_logistica
GROUP BY dia_semana
ORDER BY 1;

-- 9.2 Decomposição do lead time: postagem (vendedor) vs transporte (transportadora)
-- media_dias_postagem  = purchase → carrier (responsabilidade do vendedor)
-- media_dias_transporte = carrier → customer (responsabilidade da transportadora)
-- A soma dos dois deve aproximar o lead_time_real total
SELECT 
    EXTRACT(DOW FROM order_purchase_timestamp)          AS dia_num,
    TO_CHAR(order_purchase_timestamp, 'TMDay')          AS dia_semana,
    COUNT(*)                                            AS total_pedidos,
    ROUND(AVG(order_delivered_carrier_date::date  - order_purchase_timestamp::date), 2)        AS media_dias_postagem,
    ROUND(AVG(order_delivered_customer_date::date - order_delivered_carrier_date::date), 2)    AS media_dias_transporte
FROM olist_dataset.v_master_logistica
GROUP BY 1, 2
ORDER BY 1;


-- =============================================================================
-- BLOCO 10: TRATAMENTO DE OUTLIERS — MATERIALIZED VIEW
--
-- OBJETIVO: Identificar e classificar pedidos com atrasos estatisticamente
-- anormais para isolar casos extremos que distorcem médias e métricas globais.
--
-- MÉTODO: IQR por estado (Interquartile Range)
--   Limite máximo = Q3 + 1.5 * (Q3 - Q1)
--   Pedidos acima desse limite são classificados como "Outlier Crítico".
--
-- POR QUE POR ESTADO?
--   Usar um único IQR global seria injusto: um atraso de 15 dias é normal
--   para o Amazonas mas anômalo para São Paulo. Calcular por estado garante
--   que o threshold reflita a realidade operacional de cada região.
--
-- POR QUE MATERIALIZED VIEW?
--   O cálculo de percentis por estado é custoso. A Materialized View persiste
--   o resultado em disco, tornando consultas subsequentes muito mais rápidas.
--   Deve ser atualizada com REFRESH MATERIALIZED VIEW quando os dados mudarem.
-- =============================================================================
CREATE MATERIALIZED VIEW olist_dataset.mv_outliers_logistica AS
WITH percentis_por_estado AS (
    SELECT 
        customer_state,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY dias_atraso) AS q3_estado,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY dias_atraso) AS q1_estado
    FROM olist_dataset.v_master_logistica
    GROUP BY customer_state
)
SELECT 
    v.order_id,
    v.customer_state,
    v.sla_prometido,
    v.lead_time_real,
    v.dias_atraso,
    -- Limite calculado pelo método IQR adaptado por estado
    (p.q3_estado + 1.5 * (p.q3_estado - p.q1_estado))  AS limite_maximo,
    CASE 
        WHEN v.dias_atraso > (p.q3_estado + 1.5 * (p.q3_estado - p.q1_estado)) THEN 'Outlier Crítico'
        ELSE 'Atraso "normal"'
    END AS status_entrega
FROM olist_dataset.v_master_logistica v
JOIN percentis_por_estado p ON v.customer_state = p.customer_state
WHERE dias_atraso > 0  -- Foco apenas em pedidos que atrasaram
ORDER BY v.customer_state, v.lead_time_real DESC;


-- =============================================================================
-- BLOCO 11: CORRELAÇÃO ENTRE PESO DO PRODUTO E TAXA DE ATRASO
--
-- OBJETIVO: Verificar se produtos mais pesados têm maior probabilidade de atraso.
-- A hipótese é que produtos pesados exigem manuseio especial ou têm
-- restrições logísticas que aumentam o tempo de trânsito.
--
-- NOTA: product_weight_g pode ser nulo (LEFT JOIN com olist_products na view).
-- Pedidos com peso nulo ficam fora de todas as faixas e são excluídos
-- implicitamente pelo CASE WHEN — vale monitorar o volume desse grupo.
-- =============================================================================
SELECT
    CASE 
        WHEN product_weight_g <= 1000  THEN '1. Leve (até 1kg)'
        WHEN product_weight_g <= 5000  THEN '2. Médio (1kg - 5kg)'
        WHEN product_weight_g <= 20000 THEN '3. Pesado (5kg - 20kg)'
        ELSE                                '4. Muito pesado (> 20kg)'
    END AS categoria_peso,
    COUNT(order_id) AS total_pedidos,
    SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END) AS total_pedidos_atrasados,
    ROUND(SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END) * 100.0 / COUNT(order_id), 2) || '%' AS percentual_atraso
FROM olist_dataset.v_master_logistica
GROUP BY categoria_peso;