-- =============================================================================
-- PROJETO: Análise Logística - Olist Dataset
-- ARQUIVO: insights.sql
-- DESCRIÇÃO: Deep dive nos 4 gaps logísticos identificados na EDA.
--            Cada gap é investigado com queries específicas, chegando em
--            recomendações concretas e quantificadas para o negócio.
-- AUTOR: Marcus Takeyasu
-- DATA: 2026
--
-- DEPENDÊNCIAS: analise_exploratoria.sql deve ter sido executado antes
--   → VIEW:              olist_dataset.v_master_logistica
--   → MATERIALIZED VIEW: olist_dataset.mv_outliers_logistica
--
-- ORDEM DE EXECUÇÃO DOS ARQUIVOS:
--   1. criando_tabelas.sql
--   2. limpeza.sql
--   3. analise_exploratoria.sql
--   4. insights.sql              ← você está aqui
--
-- =============================================================================
-- SUMÁRIO DOS 4 GAPS INVESTIGADOS
-- =============================================================================
--
--  GAP 1 │ NORDESTE (~10% do volume) → 12% de atraso
--        │ Investigação: quem é o responsável — vendedor ou transportadora?
--        │ Achado: 95% dos atrasos são da transportadora
--        │ Recomendação: ajuste de SLA + descentralização de estoque
--
--  GAP 2 │ RIO DE JANEIRO (~12% do volume) → 12% de atraso
--        │ Investigação: por que RJ atrasa mais que SP sendo estado vizinho?
--        │ Achado: a transportadora leva o dobro do tempo para circular no RJ
--        │ Recomendação: renegociar SLA ou transportadora para rota SP→RJ
--
--  GAP 3 │ MALHA LOGÍSTICA NACIONAL
--        │ Investigação: a transportadora é mesmo o principal gargalo global?
--        │ Achado: sim — tempo de trânsito real supera o estimado em todos
--        │         os estados com alto volume de atrasos
--        │ Recomendação: renegociar contratos de frete com dados em mãos
--
--  GAP 4 │ EFEITO FIM DE SEMANA
--        │ Investigação: pedidos feitos perto do fim de semana atrasam mais?
--        │ Achado: sim — vendedores demoram mais para postar sexta/sábado/domingo
--        │ Recomendação: incentivo para postagem rápida + SLA dinâmico por dia
--
-- =============================================================================

SELECT * FROM olist_dataset.v_master_logistica LIMIT 10;


-- =============================================================================
-- GAP 1: NORDESTE — QUEM É O RESPONSÁVEL PELOS ATRASOS?
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.1 Atribuição de responsabilidade: Vendedor vs Transportadora (só Nordeste)
--
-- Mesma lógica de atribuição do arquivo analise_exploratoria.sql (Bloco 8),
-- agora filtrada exclusivamente para os estados do Nordeste.
--
-- RESULTADO ESPERADO: ~95% dos atrasos no Nordeste são da transportadora,
-- não dos vendedores — o que direciona a solução para a malha de frete,
-- não para treinamento de lojistas.
-- -----------------------------------------------------------------------------
SELECT
    COUNT(*)                                                                        AS total_pedidos,
    SUM(CASE WHEN lead_time_real > sla_prometido
        THEN 1 ELSE 0 END)                                                          AS pedidos_atrasados,

    SUM(CASE WHEN lead_time_real > sla_prometido
             AND order_delivered_carrier_date > shipping_limit_legal
        THEN 1 ELSE 0 END)                                                          AS atraso_vendedor,

    SUM(CASE WHEN lead_time_real > sla_prometido
             AND (order_estimated_delivery_date - shipping_limit_legal)
                 < (order_delivered_customer_date - order_delivered_carrier_date)
        THEN 1 ELSE 0 END)                                                          AS atraso_transportadora,

    SUM(CASE WHEN lead_time_real > sla_prometido
             AND order_delivered_carrier_date > shipping_limit_legal
             AND (order_estimated_delivery_date - shipping_limit_legal)
                 < (order_delivered_customer_date - order_delivered_carrier_date)
        THEN 1 ELSE 0 END)                                                          AS atraso_ambos
FROM olist_dataset.v_master_logistica
WHERE customer_state IN ('AL', 'BA', 'CE', 'MA', 'PB', 'PE', 'PI', 'RN', 'SE');


-- -----------------------------------------------------------------------------
-- 1.2 O atraso no Nordeste é por distância ou por SLA mal calibrado?
--
-- LÓGICA: filtramos apenas os pedidos que já atrasaram (lead_time_real > sla_prometido)
-- e comparamos a média do SLA prometido com o lead time real por região.
-- Se o lead_time_real do Nordeste for próximo ao das outras regiões mas o
-- sla_prometido for menor, o problema é de calibração do prazo.
-- Se o lead_time_real for muito maior, o problema é estrutural da malha.
-- -----------------------------------------------------------------------------
SELECT
    CASE 
        WHEN customer_state IN ('AC', 'AP', 'AM', 'PA', 'RO', 'RR', 'TO') THEN 'Norte'
        WHEN customer_state IN ('AL', 'BA', 'CE', 'MA', 'PB', 'PE', 'PI', 'RN', 'SE') THEN 'Nordeste'
        WHEN customer_state IN ('GO', 'MT', 'MS', 'DF') THEN 'Centro-Oeste'
        WHEN customer_state IN ('ES', 'MG', 'RJ', 'SP') THEN 'Sudeste'
        WHEN customer_state IN ('PR', 'RS', 'SC') THEN 'Sul'
        ELSE 'Erro'
    END AS regiao,
    COUNT(*)                            AS total_pedidos,
    ROUND(AVG(sla_prometido), 2)        AS media_sla_prometido,
    ROUND(AVG(lead_time_real), 2)       AS media_lead_time_real
FROM olist_dataset.v_master_logistica
WHERE lead_time_real > sla_prometido  -- Apenas pedidos que já atrasaram
GROUP BY regiao;

-- RECOMENDAÇÕES PARA O GAP 1:
--
-- 1. AJUSTE DE SLA (curto prazo):
--    Aumentar o SLA prometido para o Nordeste em pelo menos 7 a 10 dias,
--    alinhando a expectativa do cliente à realidade da malha atual.
--    Impacto quantificado: ver simulação no bloco de impacto financeiro.
--
-- 2. DESCENTRALIZAÇÃO DE ESTOQUE / FULFILLMENT (médio/longo prazo):
--    Atrair vendedores da própria região Nordeste ou criar centros de
--    distribuição regionais, eliminando a necessidade de cruzar o país
--    para cada entrega. Essa é a solução estrutural para o problema.


-- =============================================================================
-- GAP 2: RIO DE JANEIRO — POR QUE ATRASA MAIS QUE SP SENDO VIZINHO?
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2.1 Deep dive SP → RJ vs SP → SP: isolando a variável de origem
--
-- MÉTODO: fixamos seller_state = 'SP' para garantir que ambas as rotas
-- partem do mesmo ponto. Isso elimina o vendedor como variável de confusão
-- e isola o desempenho da transportadora como único fator diferencial.
--
-- MÉTRICAS ANALISADAS:
--   tempo_transporte_medio    → tempo real que a transportadora levou após receber
--   prazo_transporte_prometido → tempo que a Olist prometeu para o trecho da transportadora
--   pct_atraso_transportadora → % de vezes que a transportadora perdeu o prazo
--
-- RESULTADO ESPERADO:
--   O tempo_transporte_medio para RJ deve ser significativamente maior
--   (muitas vezes o dobro ou triplo) do que para SP, mesmo com ~400km
--   de distância entre as capitais.
--   Conclusão: o problema não é o vendedor do RJ — é a transportadora,
--   que não consegue circular no estado com a mesma fluidez que em SP.
-- -----------------------------------------------------------------------------
SELECT 
    customer_state,
    COUNT(*) AS total_pedidos,
    ROUND(AVG(order_delivered_customer_date::date - order_delivered_carrier_date::date), 2) AS tempo_transporte_medio,
    ROUND(AVG(order_estimated_delivery_date::date - order_delivered_carrier_date::date), 2) AS prazo_transporte_prometido,
    ROUND(SUM(CASE WHEN (order_delivered_customer_date::date - order_delivered_carrier_date::date) > 
                        (order_estimated_delivery_date::date - shipping_limit_legal::date) 
              THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) || '%'                             AS pct_atraso_transportadora
FROM olist_dataset.v_master_logistica
WHERE seller_state = 'SP'                        -- Origem fixa para comparação justa
  AND customer_state IN ('SP', 'RJ')             -- Comparando destinos vizinhos
GROUP BY customer_state;

-- RECOMENDAÇÃO PARA O GAP 2:
--   O problema do RJ é estrutural da transportadora nessa rota, não dos vendedores.
--   Ações possíveis:
--   - Aumentar o SLA prometido especificamente para a rota SP → RJ
--   - Avaliar transportadoras alternativas com melhor cobertura no estado do RJ
--     (o problema pode estar relacionado à segurança viária ou à
--     capilaridade da malha de last-mile no estado)


-- =============================================================================
-- GAP 3: MALHA LOGÍSTICA NACIONAL — A TRANSPORTADORA É O PRINCIPAL GARGALO?
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3.1 Performance da transportadora por estado: tempo real vs estimado
--
-- OBJETIVO: Confirmar em escala nacional que o gargalo é a transportadora,
-- não os vendedores. Mostra os estados onde o tempo de trânsito real mais
-- se distancia do estimado — candidatos prioritários para renegociação.
--
-- FILTRO HAVING COUNT(*) > 50: exclui estados com volume muito baixo,
-- onde a média seria instável e pouco confiável para tomada de decisão.
-- =============================================================================
SELECT 
    customer_state,
    ROUND(AVG(order_delivered_customer_date::date - order_delivered_carrier_date::date), 2) AS tempo_transito_real,
    ROUND(AVG(order_estimated_delivery_date::date - order_delivered_carrier_date::date), 2) AS tempo_transito_estimado,
    COUNT(*) AS volume_pedidos
FROM olist_dataset.v_master_logistica
WHERE lead_time_real > sla_prometido   -- Focando apenas nos pedidos que já atrasaram
GROUP BY customer_state
HAVING COUNT(*) > 50                   -- Mínimo de volume para a média ser confiável
ORDER BY tempo_transito_real DESC;

-- RECOMENDAÇÃO PARA O GAP 3:
--   A transportadora é a principal responsável pelos atrasos da Olist.
--   Este relatório serve como insumo direto para renegociação contratual:
--   - Apresentar os estados com maior gap (real vs estimado) como evidência
--   - Exigir SLAs de trânsito mais realistas por rota
--   - Considerar multi-carrier: usar transportadoras diferentes por região
--     conforme a cobertura e performance de cada uma


-- =============================================================================
-- GAP 4: EFEITO FIM DE SEMANA — PEDIDOS DE SEXTA/SÁBADO ATRASAM MAIS?
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 4.1 Taxa de atraso por dia da semana
--
-- HIPÓTESE: vendedores não operam aos fins de semana, então pedidos feitos
-- na sexta, sábado ou domingo só são postados na segunda-feira, atrasando
-- o início do ciclo logístico e aumentando o risco de perder o SLA.
-- -----------------------------------------------------------------------------
SELECT
    TO_CHAR(order_purchase_timestamp, 'TMDay') AS dia_semana,
    COUNT(order_id)                             AS total_pedidos,
    SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END) AS pedidos_atrasados,
    ROUND(SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END) * 100.0 / COUNT(order_id), 2) || '%' AS percentual_atraso
FROM olist_dataset.v_master_logistica
GROUP BY dia_semana
ORDER BY 1;

-- -----------------------------------------------------------------------------
-- 4.2 Decomposição do tempo por dia: postagem (vendedor) vs transporte (carrier)
--
-- Separando os dois componentes do lead time para confirmar em qual etapa
-- o atraso se concentra nos pedidos feitos próximos ao fim de semana:
--   media_dias_postagem   = purchase → carrier  (responsabilidade do vendedor)
--   media_dias_transporte = carrier  → customer (responsabilidade da transportadora)
--
-- Se media_dias_postagem subir nos fins de semana mas media_dias_transporte
-- permanecer estável, confirma-se que o gargalo é o vendedor, não a transportadora.
-- -----------------------------------------------------------------------------
SELECT 
    EXTRACT(DOW FROM order_purchase_timestamp)                                              AS dia_num,
    TO_CHAR(order_purchase_timestamp, 'TMDay')                                              AS dia_semana,
    COUNT(*)                                                                                AS total_pedidos,
    ROUND(AVG(order_delivered_carrier_date::date  - order_purchase_timestamp::date), 2)    AS media_dias_postagem,
    ROUND(AVG(order_delivered_customer_date::date - order_delivered_carrier_date::date), 2) AS media_dias_transporte
FROM olist_dataset.v_master_logistica
GROUP BY 1, 2
ORDER BY 1;

-- RECOMENDAÇÃO PARA O GAP 4:
--   1. SLA DINÂMICO POR DIA DA SEMANA: pedidos feitos na sexta/sábado/domingo
--      deveriam receber automaticamente +1 ou +2 dias no SLA prometido,
--      já absorvendo o tempo de não operação do vendedor.
--   2. INCENTIVO À POSTAGEM RÁPIDA: criar um programa de pontuação ou bonificação
--      para vendedores que postam dentro de 24h — reduzindo o impacto do fim
--      de semana e melhorando o SLA hit rate global.


-- =============================================================================
-- RANKING DE VENDEDORES COM MAIOR TAXA DE ATRASO POR CULPA PRÓPRIA
--
-- OBJETIVO: Identificar os vendedores que sistematicamente postam após o
-- prazo limite (shipping_limit_legal), independente da transportadora.
-- São os candidatos prioritários para ações de treinamento ou penalização.
--
-- FILTRO HAVING COUNT(*) > 10: excluímos vendedores com volume muito baixo
-- para evitar que um vendedor com 2 pedidos e 2 atrasos apareça no topo com
-- 100% de taxa — o ranking precisa ser estatisticamente representativo.
--
-- TÉCNICA: DENSE_RANK não pula posições em caso de empate (diferente de RANK),
-- o que é mais adequado para rankings de performance onde empates são comuns.
-- =============================================================================
SELECT
    DENSE_RANK() OVER (
        ORDER BY ROUND(
            SUM(CASE WHEN lead_time_real > sla_prometido AND order_delivered_carrier_date > shipping_limit_legal 
                THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) DESC
    )                                                                               AS ranking,
    seller_id,
    COUNT(*)                                                                        AS total_pedidos,
    SUM(CASE WHEN lead_time_real > sla_prometido
             AND order_delivered_carrier_date > shipping_limit_legal
        THEN 1 ELSE 0 END)                                                          AS total_atrasados,
    ROUND(SUM(CASE WHEN lead_time_real > sla_prometido
                   AND order_delivered_carrier_date > shipping_limit_legal
              THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2)                            AS taxa_atraso_percentual
FROM olist_dataset.v_master_logistica
GROUP BY seller_id
HAVING COUNT(*) > 10                  -- Mínimo de volume para ranking confiável
ORDER BY taxa_atraso_percentual DESC
LIMIT 10;


-- =============================================================================
-- IMPACTO FINANCEIRO DOS ATRASOS — GMV EM RISCO
--
-- OBJETIVO: Traduzir os atrasos em valor de negócio, dando dimensão financeira
-- aos gaps identificados. Isso transforma o projeto de análise técnica em
-- argumento para tomada de decisão executiva.
--
-- MÉTRICAS:
--   gmv_total         → faturamento total do período por região/estado
--   gmv_atrasado      → parcela do GMV vinculada a pedidos que atrasaram
--   pct_gmv_atrasado  → % do faturamento que estava "em risco" de churn/reclamação
--   frete_sob_atraso  → custo de frete nos pedidos atrasados (potencial de cupom/reembolso)
--   peso_frete_no_atraso → % que o frete representa no ticket dos pedidos atrasados
--                          quanto maior, mais o cliente "sentiu" o custo do atraso
--
-- NOTA METODOLÓGICA: peso_frete_no_atraso usa AVG do percentual por pedido.
-- Isso pode ser sensível a outliers de ticket. Uma alternativa mais robusta
-- seria SUM(frete_atrasado) / SUM(gmv_atrasado + frete_atrasado).
-- =============================================================================

-- Por região (visão estratégica)
SELECT 
    CASE 
        WHEN customer_state IN ('AC', 'AP', 'AM', 'PA', 'RO', 'RR', 'TO') THEN 'Norte'
        WHEN customer_state IN ('AL', 'BA', 'CE', 'MA', 'PB', 'PE', 'PI', 'RN', 'SE') THEN 'Nordeste'
        WHEN customer_state IN ('GO', 'MT', 'MS', 'DF') THEN 'Centro-Oeste'
        WHEN customer_state IN ('ES', 'MG', 'RJ', 'SP') THEN 'Sudeste'
        WHEN customer_state IN ('PR', 'RS', 'SC') THEN 'Sul'
        ELSE 'Erro'
    END AS regiao,
    COUNT(*)                                                                            AS total_pedidos_estado,
    SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END)                    AS total_pedidos_atrasados,
    ROUND(SUM(valor_total_produtos), 2)                                                 AS gmv_total,
    ROUND(SUM(CASE WHEN lead_time_real > sla_prometido THEN valor_total_produtos ELSE 0 END), 2) AS gmv_atrasado,
    ROUND(
        (SUM(CASE WHEN lead_time_real > sla_prometido THEN valor_total_produtos ELSE 0 END) * 100.0) /
        SUM(valor_total_produtos), 2
    ) || '%'                                                                            AS pct_gmv_atrasado,
    ROUND(SUM(CASE WHEN lead_time_real > sla_prometido THEN valor_total_frete ELSE 0 END), 2) AS frete_sob_atraso,
    ROUND(AVG(CASE WHEN lead_time_real > sla_prometido 
              THEN (valor_total_frete / (valor_total_produtos + valor_total_frete)) * 100 END), 2) || '%' AS peso_frete_no_atraso
FROM olist_dataset.v_master_logistica
GROUP BY regiao
ORDER BY gmv_atrasado DESC;

-- Por estado (top 10 por GMV atrasado — priorização tática)
SELECT 
    customer_state,
    COUNT(*)                                                                            AS total_pedidos_estado,
    SUM(CASE WHEN lead_time_real > sla_prometido THEN 1 ELSE 0 END)                    AS total_pedidos_atrasados,
    ROUND(SUM(valor_total_produtos), 2)                                                 AS gmv_total,
    ROUND(SUM(CASE WHEN lead_time_real > sla_prometido THEN valor_total_produtos ELSE 0 END), 2) AS gmv_atrasado,
    ROUND(
        (SUM(CASE WHEN lead_time_real > sla_prometido THEN valor_total_produtos ELSE 0 END) * 100.0) /
        SUM(valor_total_produtos), 2
    ) || '%'                                                                            AS pct_gmv_atrasado,
    ROUND(SUM(CASE WHEN lead_time_real > sla_prometido THEN valor_total_frete ELSE 0 END), 2) AS frete_sob_atraso,
    ROUND(AVG(CASE WHEN lead_time_real > sla_prometido 
              THEN (valor_total_frete / (valor_total_produtos + valor_total_frete)) * 100 END), 2) || '%' AS peso_frete_no_atraso
FROM olist_dataset.v_master_logistica
GROUP BY customer_state
ORDER BY gmv_atrasado DESC
LIMIT 10;


-- =============================================================================
-- SIMULAÇÃO: IMPACTO DO AJUSTE DE +7 DIAS NO SLA DO NORDESTE
--
-- OBJETIVO: Quantificar o ganho esperado na SLA hit rate se o prazo prometido
-- ao cliente no Nordeste for aumentado em 7 dias — tornando a recomendação
-- do GAP 1 uma proposta com número, não apenas uma sugestão qualitativa.
--
-- LÓGICA DA SIMULAÇÃO:
--   Com os dados históricos, recalculamos quantos pedidos que hoje são
--   classificados como "atrasados" passariam a ser "no prazo" se o SLA
--   fosse 7 dias maior. O lead_time_real não muda — apenas o threshold muda.
--
-- LIMITAÇÃO: a simulação assume que o comportamento dos clientes e
-- da transportadora não muda com o novo SLA. Na prática, um SLA mais alto
-- pode reduzir a taxa de conversão (clientes desistindo por prazo longo).
-- O resultado deve ser interpretado como o ganho máximo potencial.
--
-- RESULTADO ENCONTRADO: ganho de +6,17 p.p. no hit rate do Nordeste.
-- =============================================================================
WITH simulacao_nordeste AS (
    SELECT 
        customer_state,
        lead_time_real,
        sla_prometido,
        (sla_prometido + 7) AS sla_simulado       -- Hipótese: +7 dias no prazo prometido
    FROM olist_dataset.v_master_logistica
    WHERE customer_state IN ('AL', 'BA', 'CE', 'MA', 'PB', 'PE', 'PI', 'RN', 'SE')
)
SELECT 
    'Nordeste'                                                                      AS regiao,
    COUNT(*)                                                                        AS total_pedidos,
    ROUND(SUM(CASE WHEN lead_time_real <= sla_prometido THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) || '%' AS hit_rate_atual,
    ROUND(SUM(CASE WHEN lead_time_real <= sla_simulado  THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) || '%' AS hit_rate_simulado,
    ROUND(
        (SUM(CASE WHEN lead_time_real <= sla_simulado  THEN 1 ELSE 0 END) * 100.0 / COUNT(*)) -
        (SUM(CASE WHEN lead_time_real <= sla_prometido THEN 1 ELSE 0 END) * 100.0 / COUNT(*)), 2
    ) || ' p.p.'                                                                    AS ganho_eficiencia_percebida
FROM simulacao_nordeste;