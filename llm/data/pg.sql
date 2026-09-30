-- Sample data for the yt_llm test, loaded on EVERY yaxaha node by up.sh before
-- ytserv starts (psql -v node_index=0|1|2 -v node_uuid=<this node's uuid>).
-- Deterministic: every node computes the same rows, so a question has one
-- answer wherever it is asked.
--
-- Whole on every node (synced, not sharded) - the sql and df targets:
--   shop.customers, shop.orders           questions answered by PostgreSQL
--   shop.products, shop.order_items       named in C llm_df_tables: answered by DataFusion
-- Sharded over the three nodes - no node holds them whole, which is what the
-- routing questions are about. yaxaha has two kinds of shard, and yt_llm treats
-- them differently:
--   pinned (module A shard=owner; outer=pin: the owner column names the node)
--     shop.web_events   also in ClickHouse: answered from there, and it says so
--     shop.clicks       only here: refused - DataFusion over shards is not built
--   ring hash (module A shard=id; outer=reject: owners follow the live ring)
--     shop.sessions     also in ClickHouse: left off yt_llm's lists, so the
--                       ClickHouse copy answers as a table of its own
--     shop.refunds      only here: left off every list, so refused
-- Each node loads its own third (id % 3 = node_index), and a pinned row names
-- this node as its owner: the placement is what the A rows say.

set client_min_messages = warning;
drop schema if exists shop cascade;
create schema shop;

create table shop.customers (
    id         serial primary key,
    name       text not null,
    email      text not null unique,
    country    text not null,
    created_at date not null
);

create table shop.products (
    id       serial primary key,
    name     text not null,
    category text not null,
    price    numeric(10,2) not null
);

create table shop.orders (
    id          serial primary key,
    customer_id int  not null references shop.customers(id),
    order_date  date not null,
    status      text not null check (status in ('new', 'paid', 'shipped', 'delivered', 'cancelled'))
);

create table shop.order_items (
    order_id   int not null references shop.orders(id),
    product_id int not null references shop.products(id),
    quantity   int not null check (quantity > 0),
    unit_price numeric(10,2) not null,
    primary key (order_id, product_id)
);

create table shop.web_events (
    id         bigint primary key,
    owner      uuid not null,
    event_type text not null,
    page       text not null,
    amount     int not null
);

create table shop.clicks (
    id     bigint primary key,
    owner  uuid not null,
    page   text not null,
    button text not null
);

create table shop.sessions (
    id      bigint primary key,
    channel text not null,
    pages   int not null
);

create table shop.refunds (
    id     bigint primary key,
    reason text not null,
    amount numeric(10,2) not null
);

select setseed(0.42);

insert into shop.customers (name, email, country, created_at)
select
    (array['Anna','Boris','Chen','Dana','Emil','Fatima','Georg','Hana','Ivan','Julia'])[1 + (i % 10)]
        || ' ' || (array['Smith','Ivanova','Wang','Garcia','Muller','Khan','Rossi','Novak'])[1 + (i % 8)],
    'customer' || i || '@example.com',
    (array['USA','Canada','Germany','France','Japan','Brazil'])[1 + floor(random() * 6)::int],
    date '2024-01-01' + floor(random() * 700)::int
from generate_series(1, 50) i;

insert into shop.products (name, category, price) values
    ('Laptop Pro 14',       'Electronics', 1499.00),
    ('Wireless Mouse',      'Electronics',   29.90),
    ('USB-C Hub',           'Electronics',   59.00),
    ('Noise-Cancel Headset','Electronics',  249.00),
    ('4K Monitor',          'Electronics',  399.00),
    ('Office Chair',        'Furniture',    289.00),
    ('Standing Desk',       'Furniture',    649.00),
    ('Bookshelf',           'Furniture',    139.00),
    ('Desk Lamp',           'Furniture',     45.50),
    ('Coffee Beans 1kg',    'Grocery',       24.00),
    ('Green Tea 100 bags',  'Grocery',        9.80),
    ('Olive Oil 1L',        'Grocery',       15.40),
    ('Dark Chocolate',      'Grocery',        4.20),
    ('Running Shoes',       'Sports',       119.00),
    ('Yoga Mat',            'Sports',        35.00),
    ('Dumbbell Set',        'Sports',        89.00),
    ('Water Bottle',        'Sports',        18.00),
    ('Novel: The Cluster',  'Books',         21.00),
    ('SQL Cookbook',        'Books',         49.00),
    ('Rust in Action',      'Books',         44.00);

insert into shop.orders (customer_id, order_date, status)
select
    1 + floor(random() * 50)::int,
    date '2025-01-01' + floor(random() * 630)::int,
    (array['new','paid','shipped','delivered','delivered','delivered','cancelled'])[1 + floor(random() * 7)::int]
from generate_series(1, 400);

-- 1..4 distinct products per order; unit_price is the list price, sometimes discounted
insert into shop.order_items (order_id, product_id, quantity, unit_price)
select o.id, p.id, 1 + floor(random() * 3)::int,
       round(p.price * (case when random() < 0.2 then 0.9 else 1 end), 2)
from shop.orders o
cross join lateral (
    select id, price from shop.products
    order by random() + o.id * 0   -- per-order shuffle
    limit 1 + floor(random() * 4)::int
) p;

-- this node's third of the sharded tables; data/ch.sql has the same generators
-- for the two ClickHouse also has (web_events, sessions)
insert into shop.web_events (id, owner, event_type, page, amount)
select g, :'node_uuid',
       (array['view','view','view','click','click','cart','buy'])[g % 7 + 1],
       (array['/home','/search','/product','/cart','/checkout'])[g % 5 + 1],
       (g * 7) % 100
from generate_series(1, 900) g
where g % 3 = :node_index;

insert into shop.clicks (id, owner, page, button)
select g, :'node_uuid',
       (array['/home','/search','/product','/cart','/checkout'])[(g * 3) % 5 + 1],
       (array['buy','buy','add','add','add','share'])[g % 6 + 1]
from generate_series(1, 600) g
where g % 3 = :node_index;

insert into shop.sessions (id, channel, pages)
select g,
       (array['search','search','social','email','direct','direct','ads'])[g % 7 + 1],
       (g * 3) % 20 + 1
from generate_series(1, 600) g
where g % 3 = :node_index;

insert into shop.refunds (id, reason, amount)
select g,
       (array['damaged','late','wrong item','changed mind'])[g % 4 + 1],
       ((g * 13) % 200) + 0.50
from generate_series(1, 300) g
where g % 3 = :node_index;

-- What the model is told besides names and types: ytserv makes a column comment
-- the column's description and a table comment [Reference information].
comment on column shop.products.price is 'list price';
comment on column shop.order_items.unit_price is 'price actually paid per unit';
comment on table shop.order_items is 'revenue = order_items.quantity * order_items.unit_price';
comment on table shop.orders is 'a delivered order has orders.status = ''delivered''';
comment on table shop.web_events is 'events of the web shop: one row per event';
comment on table shop.clicks is 'button clicks on the web shop pages: one row per click';
comment on table shop.sessions is 'visits to the web shop: one row per session, with the channel it came from';
comment on table shop.refunds is 'refunds paid to customers: one row per refund';

analyze shop.customers, shop.products, shop.orders, shop.order_items, shop.web_events, shop.clicks,
        shop.sessions, shop.refunds;

select 'customers' t, count(*) from shop.customers
union all select 'products', count(*) from shop.products
union all select 'orders', count(*) from shop.orders
union all select 'order_items', count(*) from shop.order_items
union all select 'web_events (this node''s third)', count(*) from shop.web_events
union all select 'clicks (this node''s third)', count(*) from shop.clicks
union all select 'sessions (this node''s third)', count(*) from shop.sessions
union all select 'refunds (this node''s third)', count(*) from shop.refunds;
