-- OLTP script: creates schema, stages CSVs, inserts normalized data
-- safe to rerun

-- teardown helper: not called by the pipeline
create or replace procedure drop_oltp_schema()
language plpgsql
as $$
begin
    drop table if exists restaurant_reviews cascade;
    drop table if exists basket_items cascade;
    drop table if exists order_items cascade;
    drop table if exists orders cascade;
    drop table if exists menu_items cascade;
    drop table if exists restaurant_cuisines cascade;
    drop table if exists customers cascade;
    drop table if exists restaurants cascade;
    drop table if exists cuisines cascade;

    drop table if exists staging_customers cascade;
    drop table if exists staging_menu_source cascade;
    drop table if exists staging_orders_source cascade;
    drop table if exists staging_baskets_source cascade;
    drop table if exists staging_reviews_source cascade;
end;
$$;

create or replace procedure create_oltp_schema()
language plpgsql
as $$
begin
    create table if not exists cuisines (
        cuisine_code varchar(50) primary key,
        cuisine_name varchar(100) not null unique,
        is_active    boolean not null default true
    );

    create table if not exists restaurants (
        restaurant_code    varchar(50) primary key,
        restaurant_name    varchar(150) not null,
        restaurant_address varchar(255) not null,
        is_active          boolean not null default true
    );

    create table if not exists restaurant_cuisines (
        restaurant_code varchar(50) references restaurants(restaurant_code) on delete cascade,
        cuisine_code varchar(50) references cuisines(cuisine_code) on delete cascade,
        primary key (restaurant_code, cuisine_code)
    );

    create table if not exists customers (
        email             varchar(255) primary key,
        first_name        varchar(100) not null,
        last_name         varchar(100) not null,
        password_hash     varchar(255) not null,
        registration_date date not null default current_date,
        is_active         boolean not null default true
    );

    create table if not exists menu_items (
        item_code       varchar(50) primary key,
        restaurant_code varchar(50) not null references restaurants(restaurant_code) on delete restrict,
        item_name       varchar(150) not null,
        base_price      numeric(10, 2) not null check (base_price >= 0),
        is_active       boolean not null default true
    );

    create table if not exists basket_items (
        email varchar(255) references customers(email) on delete cascade,
        item_code varchar(50) references menu_items(item_code) on delete cascade,
        quantity int not null check (quantity > 0),
        added_at timestamp not null default current_timestamp,
        primary key (email, item_code)
    );

    create table if not exists orders (
        order_code varchar(50) primary key,
        restaurant_code varchar(50) not null references restaurants(restaurant_code) on delete cascade,
        email varchar(255) not null references customers(email) on delete restrict,
        delivery_address varchar(255) not null,
        order_date timestamp not null,
        order_status varchar(50) not null,
        delivery_fee numeric(10, 2) not null check (delivery_fee >= 0),
        driver_tip numeric(10, 2) not null check (driver_tip >= 0)
    );

    create table if not exists order_items (
        order_code varchar(50) references orders(order_code) on delete cascade,
        item_code varchar(50) references menu_items(item_code) on delete restrict,
        quantity int not null check (quantity > 0),
        historical_unit_price numeric(10, 2) not null check (historical_unit_price >= 0),
        primary key (order_code, item_code)
    );

    create table if not exists restaurant_reviews (
        email varchar(255) references customers(email) on delete cascade,
        restaurant_code varchar(50) references restaurants(restaurant_code) on delete cascade,
        rating_score int not null check (rating_score between 1 and 5),
        review_text text,
        review_date timestamp not null,
        primary key (email, restaurant_code, review_date)
    );

    -- backfill is_active on tables that may have been created without it
    alter table if exists cuisines    add column if not exists is_active boolean not null default true;
    alter table if exists restaurants add column if not exists is_active boolean not null default true;
    alter table if exists customers   add column if not exists is_active boolean not null default true;
    alter table if exists menu_items  add column if not exists is_active boolean not null default true;

    -- staging tables: no constraints, raw csv data only
    create table if not exists staging_customers (
        email varchar(255), first_name varchar(100), last_name varchar(100),
        password_hash varchar(255), registration_date date
    );

    create table if not exists staging_menu_source (
        item_code varchar(50), item_name varchar(150), base_price numeric(10,2),
        restaurant_code varchar(50), restaurant_name varchar(150), restaurant_address varchar(255),
        cuisine_code varchar(50), cuisine_name varchar(100)
    );

    create table if not exists staging_orders_source (
        order_code varchar(50), customer_email varchar(255), delivery_address varchar(255),
        order_date timestamp, order_status varchar(50), item_code varchar(50),
        quantity int, historical_unit_price numeric(10,2), delivery_fee numeric(10,2), driver_tip numeric(10,2)
    );

    create table if not exists staging_baskets_source (
        customer_email varchar(255), item_code varchar(50), quantity int, added_at timestamp
    );

    create table if not exists staging_reviews_source (
        customer_email varchar(255), restaurant_code varchar(50), rating_score int,
        review_text text, review_date timestamp
    );
end;
$$;

-- note: file paths are mounted via docker compose (see compose.yml)
create or replace procedure stage_csv_data()
language plpgsql
as $$
begin
    truncate table staging_customers, staging_menu_source, staging_orders_source, staging_baskets_source, staging_reviews_source;

    copy staging_customers from '/mnt/data/customers.csv' delimiter ',' csv header;
    copy staging_menu_source from '/mnt/data/menu_source.csv' delimiter ',' csv header;
    copy staging_orders_source from '/mnt/data/orders_source.csv' delimiter ',' csv header;
    copy staging_baskets_source from '/mnt/data/baskets_source.csv' delimiter ',' csv header;
    copy staging_reviews_source from '/mnt/data/reviews_source.csv' delimiter ',' csv header;
end;
$$;

-- dimensions: changes are propagated, re-appearing rows reactivated
-- facts: append-only, existing rows are never touched
-- soft-deletes: dimension rows absent from staging are marked is_active = false
create or replace procedure load_oltp_dimensions_and_facts()
language plpgsql
as $$
begin
    -- dimensions
    insert into cuisines (cuisine_code, cuisine_name)
    select distinct cuisine_code, cuisine_name
    from staging_menu_source
    on conflict (cuisine_code) do update set
        cuisine_name = excluded.cuisine_name,
        is_active    = true;

    insert into restaurants (restaurant_code, restaurant_name, restaurant_address)
    select distinct restaurant_code, restaurant_name, restaurant_address
    from staging_menu_source
    on conflict (restaurant_code) do update set
        restaurant_name    = excluded.restaurant_name,
        restaurant_address = excluded.restaurant_address,
        is_active          = true;

    insert into restaurant_cuisines (restaurant_code, cuisine_code)
    select distinct restaurant_code, cuisine_code
    from staging_menu_source
    on conflict (restaurant_code, cuisine_code) do nothing;

    insert into customers (email, first_name, last_name, password_hash, registration_date)
    select distinct email, first_name, last_name, password_hash, registration_date
    from staging_customers
    on conflict (email) do update set
        first_name    = excluded.first_name,
        last_name     = excluded.last_name,
        password_hash = excluded.password_hash,
        is_active     = true;

    insert into menu_items (item_code, restaurant_code, item_name, base_price)
    select distinct item_code, restaurant_code, item_name, base_price
    from staging_menu_source
    on conflict (item_code) do update set
        item_name       = excluded.item_name,
        base_price      = excluded.base_price,
        restaurant_code = excluded.restaurant_code,
        is_active       = true;

    -- facts (append-only)
    insert into basket_items (email, item_code, quantity, added_at)
    select distinct customer_email, item_code, quantity, added_at
    from staging_baskets_source
    on conflict (email, item_code) do nothing;

    insert into orders (order_code, restaurant_code, email, delivery_address, order_date, order_status, delivery_fee, driver_tip)
    select order_code, restaurant_code, customer_email, delivery_address, order_date, order_status, delivery_fee, driver_tip
    from (
        select distinct on (sos.order_code)
            sos.order_code,
            sm.restaurant_code,
            sos.customer_email,
            sos.delivery_address,
            sos.order_date,
            sos.order_status,
            sos.delivery_fee,
            sos.driver_tip
        from staging_orders_source sos
        join staging_menu_source sm on sos.item_code = sm.item_code
        order by sos.order_code
    ) sub
    on conflict (order_code) do nothing;

    insert into order_items (order_code, item_code, quantity, historical_unit_price)
    select distinct order_code, item_code, quantity, historical_unit_price
    from staging_orders_source
    on conflict (order_code, item_code) do nothing;

    insert into restaurant_reviews (email, restaurant_code, rating_score, review_text, review_date)
    select distinct customer_email, restaurant_code, rating_score, review_text, review_date
    from staging_reviews_source
    on conflict (email, restaurant_code, review_date) do nothing;

    -- soft-deletes
    update cuisines set is_active = false
    where cuisine_code not in (select distinct cuisine_code from staging_menu_source);

    update restaurants set is_active = false
    where restaurant_code not in (select distinct restaurant_code from staging_menu_source);

    update menu_items set is_active = false
    where item_code not in (select distinct item_code from staging_menu_source);

    update customers set is_active = false
    where email not in (select distinct email from staging_customers);
end;
$$;

create or replace procedure run_oltp_pipeline()
language plpgsql
as $$
begin
    call create_oltp_schema();
    call stage_csv_data();
    call load_oltp_dimensions_and_facts();
end;
$$;

-- mandatory to call every time there was changes in csv
call run_oltp_pipeline();
