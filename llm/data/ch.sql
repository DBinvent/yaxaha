-- ClickHouse side of the yt_llm test, run once on ch1 by up.sh (the DDL goes to
-- all three nodes ON CLUSTER yt; rows go through the Distributed tables, so every
-- table is spread over the three shards). @CH_RO_PASSWORD@ is filled in by up.sh.
--
-- Each table is <name>_local (MergeTree) on every node plus <name>, a Distributed
-- table over them - the layout the lab uses. llm2 reads the Distributed ones.
--   analytics.page_views  only in ClickHouse: the ch target
--   shop.web_events       ALL rows of two PostgreSQL tables sharded over the yaxaha
--   shop.sessions         nodes (same generators as data/pg.sql): the routing targets

CREATE DATABASE IF NOT EXISTS analytics ON CLUSTER yt;
CREATE DATABASE IF NOT EXISTS shop ON CLUSTER yt;

CREATE TABLE IF NOT EXISTS analytics.page_views_local ON CLUSTER yt (
    ts          DateTime COMMENT 'when the page was viewed',
    country     String   COMMENT 'visitor country',
    device      String   COMMENT 'desktop, mobile or tablet',
    page        String   COMMENT 'page path',
    duration_ms UInt32   COMMENT 'time on the page, milliseconds'
) ENGINE = MergeTree ORDER BY (country, ts)
COMMENT 'page views of the web shop, one row per view';

CREATE TABLE IF NOT EXISTS analytics.page_views ON CLUSTER yt AS analytics.page_views_local
ENGINE = Distributed(yt, analytics, page_views_local, cityHash64(ts))
COMMENT 'page views of the web shop, one row per view';

CREATE TABLE IF NOT EXISTS shop.web_events_local ON CLUSTER yt (
    id         UInt64 COMMENT 'event id',
    event_type String COMMENT 'view, click, cart or buy',
    page       String COMMENT 'page path',
    amount     UInt32 COMMENT 'amount of the event'
) ENGINE = MergeTree ORDER BY id
COMMENT 'events of the web shop: one row per event';

CREATE TABLE IF NOT EXISTS shop.web_events ON CLUSTER yt AS shop.web_events_local
ENGINE = Distributed(yt, shop, web_events_local, cityHash64(id))
COMMENT 'events of the web shop: one row per event';

CREATE TABLE IF NOT EXISTS shop.sessions_local ON CLUSTER yt (
    id      UInt64 COMMENT 'session id',
    channel String COMMENT 'the channel the visit came from',
    pages   UInt32 COMMENT 'pages viewed in the session'
) ENGINE = MergeTree ORDER BY id
COMMENT 'visits to the web shop: one row per session, with the channel it came from';

CREATE TABLE IF NOT EXISTS shop.sessions ON CLUSTER yt AS shop.sessions_local
ENGINE = Distributed(yt, shop, sessions_local, cityHash64(id))
COMMENT 'visits to the web shop: one row per session, with the channel it came from';

TRUNCATE TABLE analytics.page_views_local ON CLUSTER yt;
TRUNCATE TABLE shop.web_events_local ON CLUSTER yt;
TRUNCATE TABLE shop.sessions_local ON CLUSTER yt;

INSERT INTO analytics.page_views
SELECT toDateTime('2026-09-01 00:00:00') + number * 60,
       ['USA','USA','USA','Canada','Germany','Germany','France','Japan','Japan','Brazil','Brazil'][number % 11 + 1],
       ['desktop','mobile','tablet'][intDiv(number, 7) % 3 + 1],
       ['/home','/search','/product','/cart','/checkout'][number % 5 + 1],
       (number * 37) % 5000
  FROM numbers(30000)
SETTINGS distributed_foreground_insert = 1;

-- the same rows data/pg.sql spreads over the three yaxaha nodes, all of them
INSERT INTO shop.web_events
SELECT number,
       ['view','view','view','click','click','cart','buy'][number % 7 + 1],
       ['/home','/search','/product','/cart','/checkout'][number % 5 + 1],
       (number * 7) % 100
  FROM numbers(1, 900)
SETTINGS distributed_foreground_insert = 1;

INSERT INTO shop.sessions
SELECT number,
       ['search','search','social','email','direct','direct','ads'][number % 7 + 1],
       (number * 3) % 20 + 1
  FROM numbers(1, 600)
SETTINGS distributed_foreground_insert = 1;

-- llm2 reads as this user (module K row clickhouse); ytserv also sets readonly=1
-- on every query it runs
CREATE USER IF NOT EXISTS llm_ro ON CLUSTER yt IDENTIFIED WITH sha256_password BY '@CH_RO_PASSWORD@';
GRANT ON CLUSTER yt SELECT ON analytics.* TO llm_ro;
GRANT ON CLUSTER yt SELECT ON shop.* TO llm_ro;

SELECT 'analytics.page_views', count() FROM analytics.page_views
UNION ALL SELECT 'shop.web_events', count() FROM shop.web_events
UNION ALL SELECT 'shop.sessions', count() FROM shop.sessions;
