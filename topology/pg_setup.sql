-- What the fixture needs on top of CREATE EXTENSION yaxaha. yt_setup() and the
-- views yt_tables_cfg / yt_help_with_defaults used to be copied here; they come
-- with the extension now (the [setup] section of yaxaha--0.5.sql).

-- [P6b] [skv 6.4] The join-approval gate.
--
-- On a real node `yxctl --batch` installs this (JoinGateAction). This fixture
-- bakes the extension into the image and writes config rows by hand, so that
-- action never runs -- and 98_skv_join.sh asserts this trigger refuses an
-- unarmed `ok`, and lets `yxctl --skv-approve` write one once the leader armed
-- the join. Without it that test would fail for a reason unrelated to the thing
-- under test.
--
-- Kept byte-identical to yxctl/src/actions/join_gate.rs::join_gate_sql (for
-- public.yt_config); yxctl's test the_topology_fixture_carries_the_same_sql
-- compares the two when this checkout is a sibling of yt-pgxt. Two
-- details are load-bearing:
--   * BEFORE, because PostgreSQL ignores an AFTER row trigger's return value
--     and this has to inspect NEW.
--   * yt_info(text) returns JSON -- a ONE-ELEMENT ARRAY, not a record set
--     (ytpgc/yaxaha--0.5.sql:25) -- so `as x(name,value,module)` errors here.
create or replace function yt_join_gate() returns trigger as $yt_join_gate$
declare v jsonb;
begin
    if new.value = 'ok' then
        if inet_client_addr() is not null then
            raise exception 'yt_join: an approval must come from a local connection';
        end if;
        v := (yt_info('J:' || new.name) -> 0 ->> 'value')::jsonb;
        if not coalesce((v->>'ok')::bool, false) then
            raise exception 'yt_join: %', coalesce(v->>'reason', 'refused');
        end if;
    end if;
    return new;
end $yt_join_gate$ language plpgsql;

drop trigger if exists yt_join_gate on public.yt_config;
create trigger yt_join_gate before update on public.yt_config
    for each row when (new.module = 'J')
    execute function yt_join_gate();
