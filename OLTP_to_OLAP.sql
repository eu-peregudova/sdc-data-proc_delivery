-- OLTP to OLAP script: sets up a postgres_fdw link.
-- safe to rerun
-- mandatory to run once before executing OLAP.sql or ETL.sql.


drop schema if exists oltp_staging cascade;
drop user mapping if exists for current_user server oltp_server;
drop server if exists oltp_server cascade;

create extension if not exists postgres_fdw;

create server oltp_server
    foreign data wrapper postgres_fdw
    options (host 'oltp_db', port '5432', dbname 'delivery_oltp');

create user mapping for current_user
    server oltp_server
    options (user 'postgres', password 'postgres');

create schema if not exists oltp_staging;

import foreign schema public
    from server oltp_server
    into oltp_staging;

create or replace procedure verify_fdw_staging_layers()
language plpgsql
as $$
begin
    if not exists (
        select 1
        from information_schema.tables
        where table_schema = 'oltp_staging'
          and table_name = 'orders'
    ) then
        raise exception 'FDW setup failed: oltp_staging.orders not found';
    end if;
end;
$$;

call verify_fdw_staging_layers();
