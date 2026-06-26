-- ============================================================================
-- module: cross-database foreign data wrapper (fdw) integration
-- target environment: postgresql analytical data warehouse (olap)
-- design: idempotent, modular, decoupled concerns
-- ============================================================================

-- ----------------------------------------------------------------------------
-- step 1: infrastructure cleanup (tear-down dependencies in reverse order)
-- ----------------------------------------------------------------------------
drop foreign schema if exists oltp_staging cascade;
drop user mapping if exists for current_user server oltp_server;
drop server if exists oltp_server cascade;

-- ----------------------------------------------------------------------------
-- step 2: server and connection initialization
-- ----------------------------------------------------------------------------
create extension if not exists postgres_fdw;

create server oltp_server
    foreign data wrapper postgres_fdw
    options (host 'oltp_db', port '5432', dbname 'delivery_oltp');

-- map current user to remote operational database credentials
create user mapping for current_user
    server oltp_server
    options (user 'postgres', password 'postgres');

-- ----------------------------------------------------------------------------
-- step 3: virtual schema mounting and data import
-- ----------------------------------------------------------------------------
create schema if not exists oltp_staging;

-- import all tables from remote oltp public schema into isolated olap staging schema
import foreign schema public 
    from server oltp_server 
    into oltp_staging;

-- ----------------------------------------------------------------------------
-- step 4: post-mount integration check
-- ----------------------------------------------------------------------------
create or replace procedure verify_fdw_staging_layers()
language plpgsql
as $$
begin
    -- confirm connectivity and foreign table availability
    if not exists (
        select 1 
        from information_schema.tables 
        where table_schema = 'oltp_staging' 
          and table_name = 'orders'
    ) then
        raise exception 'foreign data wrapper sync failed: table oltp_staging.orders not found';
    end if;
end;
$$;

call verify_fdw_staging_layers();