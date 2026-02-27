-- =============================================================================
-- PROJETO: Análise Logística - Olist Dataset
-- ARQUIVO: criando_tabelas.sql
-- DESCRIÇÃO: Criação das tabelas base do modelo relacional para análise logística
-- AUTOR: Marcus Takeyasu
-- DATA: 2026
-- 
-- DEPENDÊNCIAS: Schema 'olist_dataset' deve existir antes da execução
--   → CREATE SCHEMA IF NOT EXISTS olist_dataset;
--
-- ORDEM DE EXECUÇÃO DOS ARQUIVOS:
--   1. criando_tabelas.sql  ← você está aqui
--   2. limpeza.sql
--   3. analise_exploratoria.sql
--   4. insights.sql
--
-- FONTE DOS DADOS: Olist E-commerce Dataset (Kaggle)
--   https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce
-- =============================================================================


-- -----------------------------------------------------------------------------
-- TABELA: olist_sellers
-- Contém os dados cadastrais dos vendedores (lojistas) que operam na plataforma.
-- Utilizada para identificar a origem geográfica dos pedidos e avaliar
-- a responsabilidade do vendedor no processo logístico.
-- -----------------------------------------------------------------------------
CREATE TABLE olist_dataset.olist_sellers (
    seller_id               UUID PRIMARY KEY,       -- Identificador único do vendedor
    seller_zip_code_prefix  INTEGER,                -- Prefixo do CEP (5 dígitos) do vendedor
    seller_city             VARCHAR(100),           -- Cidade do vendedor
    seller_state            CHAR(2)                 -- UF do vendedor (ex: 'SP', 'RJ')
);


-- -----------------------------------------------------------------------------
-- TABELA: olist_customers
-- Contém os dados dos clientes que realizaram pedidos na plataforma.
--
-- ATENÇÃO: customer_id é único por pedido, não por pessoa física.
-- Para identificar um cliente único use customer_unique_id.
-- Um mesmo cliente pode ter múltiplos customer_id se fez mais de um pedido.
-- -----------------------------------------------------------------------------
CREATE TABLE olist_dataset.olist_customers (
    customer_id             UUID PRIMARY KEY,       -- ID do cliente vinculado ao pedido (não é único por pessoa)
    customer_unique_id      UUID,                   -- ID real do cliente (único por pessoa física)
    customer_zip_code_prefix INTEGER,              -- Prefixo do CEP (5 dígitos) do cliente
    customer_city           VARCHAR(100),           -- Cidade do cliente
    customer_state          CHAR(2)                 -- UF do cliente (ex: 'SP', 'RJ')
);


-- -----------------------------------------------------------------------------
-- TABELA: olist_orders
-- Tabela central do modelo. Cada linha representa um pedido único.
-- Concentra os principais timestamps do ciclo de vida do pedido,
-- que são a base para o cálculo de SLA e lead time nas análises seguintes.
--
-- TIMESTAMPS DO CICLO DO PEDIDO (em ordem cronológica esperada):
--   order_purchase_timestamp       → Cliente finalizou a compra
--   order_approved_at              → Pagamento aprovado
--   order_delivered_carrier_date   → Vendedor postou na transportadora
--   order_delivered_customer_date  → Cliente recebeu o produto (real)
--   order_estimated_delivery_date  → Prazo prometido ao cliente (SLA)
--
-- NOTA: order_delivered_customer_date pode ser nulo para pedidos não entregues
-- (cancelados, em trânsito, etc). O tratamento desses nulos está em limpeza.sql
-- -----------------------------------------------------------------------------
CREATE TABLE olist_dataset.olist_orders (
    order_id                        UUID PRIMARY KEY,   -- Identificador único do pedido
    customer_id                     UUID,               -- FK para olist_customers
    order_status                    VARCHAR(20),        -- Status atual: delivered, canceled, shipped, etc.
    order_purchase_timestamp        TIMESTAMP,          -- Data/hora da compra pelo cliente
    order_approved_at               TIMESTAMP,          -- Data/hora da aprovação do pagamento
    order_delivered_carrier_date    TIMESTAMP,          -- Data/hora em que o vendedor postou na transportadora
    order_delivered_customer_date   TIMESTAMP,          -- Data/hora em que o cliente recebeu (real)
    order_estimated_delivery_date   TIMESTAMP,          -- Data de entrega prometida ao cliente (SLA contratado)

    CONSTRAINT fk_orders_customers FOREIGN KEY (customer_id) 
        REFERENCES olist_dataset.olist_customers (customer_id)
);


-- -----------------------------------------------------------------------------
-- TABELA: olist_order_items
-- Contém os itens individuais de cada pedido.
-- Um pedido pode ter múltiplos itens, gerando múltiplas linhas com o mesmo order_id.
-- 
-- CHAVE PRIMÁRIA COMPOSTA: (order_id + order_item_id)
--   → order_item_id é um sequencial por pedido (1, 2, 3...), não global.
--
-- IMPACTO NA ANÁLISE: essa granularidade exige agregação em limpeza.sql
-- antes de qualquer join com olist_orders, para evitar duplicação de pedidos.
-- A lógica de consolidação (SUM de preços, MIN de prazo) está documentada em limpeza.sql.
-- -----------------------------------------------------------------------------
CREATE TABLE olist_dataset.olist_order_items (
    order_id            UUID,               -- FK para olist_orders
    order_item_id       INTEGER,            -- Sequencial do item dentro do pedido (começa em 1)
    product_id          UUID,               -- Identificador do produto
    seller_id           UUID,               -- FK para olist_sellers (vendedor responsável pelo item)
    shipping_limit_date TIMESTAMP,          -- Prazo limite para o vendedor postar o item na transportadora
    price               DECIMAL(10, 2),     -- Preço unitário do produto (sem frete)
    freight_value       DECIMAL(10, 2),     -- Valor do frete para este item

    PRIMARY KEY (order_id, order_item_id),

    CONSTRAINT fk_items_orders FOREIGN KEY (order_id) 
        REFERENCES olist_dataset.olist_orders (order_id),

    CONSTRAINT fk_items_sellers FOREIGN KEY (seller_id) 
        REFERENCES olist_dataset.olist_sellers (seller_id)
);