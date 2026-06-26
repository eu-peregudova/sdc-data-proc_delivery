-- ============================================================================
-- course phase: modular star schema elt / data warehouse loading
-- ============================================================================
create or replace procedure refresh_dw_staging()
language plpgsql
as $$
begin
    create schema if not exists dw_staging;

    create table dw_staging.customers (
        email varchar(255),
        first_name varchar(100),
        last_name varchar(100),
        registration_date date
    );

    create table dw_staging.restaurants (
        restaurant_code varchar(50),
        restaurant_name varchar(150),
        restaurant_address varchar(255),
        region_city varchar(100)
    );

    create table dw_staging.menu_items (
        item_code varchar(50),
        item_name varchar(150),
        base_price numeric(10,2),
        restaurant_code varchar(50),
        restaurant_name varchar(150),
        cuisine_code varchar(50),
        cuisine_name varchar(100)
    );

    create table dw_staging.sales (
        order_code varchar(50),
        customer_email varchar(255),
        restaurant_code varchar(50),
        item_code varchar(50),
        quantity int,
        historical_unit_price numeric(10,2),
        delivery_fee numeric(10,2),
        driver_tip numeric(10,2),
        order_status varchar(50),
        order_date timestamp
    );

    create table dw_staging.reviews (
        customer_email varchar(255),
        restaurant_code varchar(50),
        rating_score int,
        review_text text,
        review_date timestamp
    );

    truncate dw_staging.customers;
    truncate dw_staging.restaurants;
    truncate dw_staging.menu_items;
    truncate dw_staging.sales;
    truncate dw_staging.reviews;

    insert into dw_staging.customers
    select
        email,
        first_name,
        last_name,
        registration_date
    from oltp_staging.customers;

    insert into dw_staging.restaurants
    select
        restaurant_code,
        restaurant_name,
        restaurant_address,
        split_part(restaurant_address, ',',2)
    from oltp_staging.restaurants;

    insert into dw_staging.menu_items
    select
        mi.item_code,
        mi.item_name,
        mi.base_price,
        r.restaurant_code,
        r.restaurant_name,
        c.cuisine_code,
        c.cuisine_name
    from oltp_staging.menu_items mi
    join oltp_staging.restaurants r
        on mi.restaurant_code = r.restaurant_code
    join oltp_staging.restaurant_cuisines rc
        on r.restaurant_code = rc.restaurant_code
    join oltp_staging.cuisines c
        on rc.cuisine_code = c.cuisine_code;

    insert into dw_staging.sales
    select
        o.order_code,
        o.email,
        m.restaurant_code,
        oi.item_code,
        oi.quantity,
        oi.historical_unit_price,
        o.delivery_fee,
        o.driver_tip,
        o.order_status,
        o.order_date
    from oltp_staging.orders o
    join oltp_staging.order_items oi
        on o.order_code = oi.order_code
    join oltp_staging.menu_items m
        on oi.item_code = m.item_code;

    insert into dw_staging.reviews
    select 
        email,
        restaurant_code,
        rating_score,
        review_text,
        review_date
    from oltp_staging.restaurant_reviews;
end;
$$;

-----------------------------------------
-- ETL
-----------------------------------------

create or replace procedure ensure_tables()
language plpgsql
as $$
begin
    create table if not exists dim_date (
        date_key int primary key,
        full_date date not null,
        day_of_week varchar(15) not null,
        month_name varchar(15) not null,
        calendar_quarter varchar(2) not null,
        calendar_year int not null
    );

    create table if not exists dim_customers (
        customer_key serial primary key,
        email varchar(255) not null unique,
        first_name varchar(100) not null,
        last_name varchar(100) not null,
        registration_date date not null
    );

    create table if not exists dim_cuisines (
        cuisine_key serial primary key,
        cuisine_code varchar(50) not null unique,
        cuisine_name varchar(100) not null
    );

    create table if not exists dim_restaurants (
        restaurant_key serial primary key,
        source_restaurant_code varchar(50) not null unique,
        restaurant_name varchar(150) not null,
        restaurant_address varchar(255) not null,
        region_city varchar(100) not null
    );

    create table if not exists dim_menu_item_history (
        menu_item_key serial primary key,
        item_code varchar(50) not null,
        item_name varchar(150) not null,
        base_price decimal(10,2) not null,
        restaurant_name varchar(150) not null,
        valid_from timestamp not null,
        valid_to timestamp,
        is_current boolean not null default true
    );

    create table if not exists bridge_restaurant_cuisines (
        menu_item_key int not null references dim_menu_item_history(menu_item_key),
        cuisine_key int not null references dim_cuisines(cuisine_key),
        primary key (menu_item_key, cuisine_key)
    );

    create table if not exists fact_sales (
        fact_sales_id serial primary key,
        order_code varchar(50) not null,
        date_key int not null references dim_date(date_key),
        customer_key int not null references dim_customers(customer_key),
        restaurant_key int not null references dim_restaurants(restaurant_key),
        menu_item_key int not null references dim_menu_item_history(menu_item_key),
        quantity_ordered int not null,
        historical_unit_price decimal(10,2) not null,
        line_item_gross_revenue decimal(10,2) not null,
        delivery_fees decimal(10,2),
        driver_tips decimal(10,2),
        order_status varchar(50) not null,
        net_revenue decimal(10,2) not null
    );

    create table if not exists fact_restaurant_ratings (
        fact_rating_id serial primary key,
        date_key int not null references dim_date(date_key),
        restaurant_key int not null references dim_restaurants(restaurant_key),
        total_review_count int not null,
        average_rating_score decimal(3,2) not null,

        constraint uq_restaurant_rating
            unique (date_key, restaurant_key)
    );
end;
$$;

-- ----------------------------------------------------------------------------
-- step 1: populate calendar dimension matrix
-- ----------------------------------------------------------------------------
create or replace procedure populate_dim_date()
language plpgsql
as $$
begin
    insert into dim_date (date_key, full_date, day_of_week, month_name, calendar_quarter, calendar_year)
    select 
        to_char(datum, 'yyyymmdd')::int as date_key,
        datum as full_date,
        trim(to_char(datum,'Day')),
        trim(to_char(datum,'Month')),
        'q' || to_char(datum, 'q') as calendar_quarter,
        extract(year from datum)::int as calendar_year
    from generate_series('2026-01-01'::date, '2026-12-31'::date, '1 day'::interval) datum
    on conflict (date_key) do nothing;
end;
$$;

-- ----------------------------------------------------------------------------
-- step 2: synchronize flat dimensions (customers & restaurants)
-- ----------------------------------------------------------------------------
create or replace procedure sync_dimensions()
language plpgsql
as $$
begin
    insert into dim_customers (email, first_name, last_name, registration_date)
    select 
        email, first_name, last_name, registration_date
    from dw_staging.customers
    on conflict (email) do nothing;

    insert into dim_restaurants (source_restaurant_code, restaurant_name, restaurant_address, region_city)
    select 
        restaurant_code, restaurant_name, restaurant_address, split_part(restaurant_address, ',', 2) 
    from dw_staging.restaurants
    on conflict (source_restaurant_code) do nothing;
end;
$$;

-- ----------------------------------------------------------------------------
-- step 3: slowly changing dimensions (scd type 2) on menu items
-- ----------------------------------------------------------------------------
create or replace procedure update_menu_scd2()
language plpgsql
as $$
begin
    -- close out previous version for records where base price has drifted
    update dim_menu_item_history target
    set valid_to = now(), is_current = false
    from dw_staging.menu_items source
    where target.item_code = source.item_code
        and target.is_current = true
        and (
            target.base_price <> source.base_price
            or target.item_name <> source.item_name
    );

    -- insert new version record for new or modified menu items
    insert into dim_menu_item_history (
        item_code, item_name, base_price, restaurant_name, valid_from, valid_to, is_current
    )
    select 
        mi.item_code, mi.item_name, mi.base_price, mi.restaurant_name, now(), null, true
    from dw_staging.menu_items mi
    where not exists (
        select 1 
        from dim_menu_item_history existing
        where existing.item_code = mi.item_code 
          and existing.is_current = true
    );
end;
$$;

-- ----------------------------------------------------------------------------
-- step 4: load fact table utilizing pro-rata weight distribution (cte approach)
-- ----------------------------------------------------------------------------
create or replace procedure load_fact_sales()
language plpgsql
as $$
begin
    with order_totals as (
        select 
            order_code, 
            sum(quantity * historical_unit_price) as total_order_gross
        from oltp_staging.order_items
        group by order_code
    )
    insert into fact_sales (
        order_code, date_key, customer_key, restaurant_key, menu_item_key, quantity_ordered, 
        historical_unit_price, line_item_gross_revenue, delivery_fees, 
        driver_tips, order_status, net_revenue
    )
    select 
        s.order_code,
        d.date_key,
        c.customer_key,
        r.restaurant_key,
        m.menu_item_key,
        s.quantity,
        s.historical_unit_price,
        (s.quantity * s.historical_unit_price) as line_item_gross_revenue,
        s.delivery_fee,
        s.driver_tip,
        s.order_status,
        (s.quantity * s.historical_unit_price) + s.delivery_fee
    from dw_staging.sales s
    join dim_customers c on s.customer_email = c.email
    join dim_restaurants r on s.restaurant_code = r.source_restaurant_code
    join dim_menu_item_history m on s.item_code = m.item_code 
         and s.order_date >= m.valid_from 
         and (m.valid_to is null or s.order_date < m.valid_to)
    join dim_date d on cast(s.order_date as date) = d.full_date
    where not exists (
        select 1 
        from fact_sales existing_fact
        where existing_fact.date_key = d.date_key
          and existing_fact.customer_key = c.customer_key
          and existing_fact.restaurant_key = r.restaurant_key
          and existing_fact.menu_item_key = m.menu_item_key
          and existing_fact.quantity_ordered = s.quantity
          and existing_fact.order_code = s.order_code
    );
end;
$$;

-- ----------------------------------------------------------------------------
-- step 5: load restaurant ratings fact table
-- ----------------------------------------------------------------------------
create or replace procedure load_fact_restaurant_ratings()
language plpgsql
as $$
begin
    insert into fact_restaurant_ratings (
        date_key,
        restaurant_key,
        total_review_count,
        average_rating_score
    )
    select
        d.date_key,
        dr.restaurant_key,
        count(*) as total_review_count,
        round(avg(r.rating_score), 2) as average_rating_score
    from dw_staging.reviews r
    join dim_date d
        on cast(r.review_date as date)=d.full_date
    join dim_restaurants dr
        on r.restaurant_code = dr.source_restaurant_code
    group by
        d.date_key,
        dr.restaurant_key
    on conflict (date_key, restaurant_key) do nothing;
end;
$$;

-- ----------------------------------------------------------------------------
-- orchestrator procedure (etl pipeline execution)
-- ----------------------------------------------------------------------------
create or replace procedure run_etls()
language plpgsql
as $$
begin
    call refresh_dw_staging();
    call ensure_tables();
    call populate_dim_date();
    call sync_dimensions();
    call update_menu_scd2();
    call load_fact_sales();
    call load_fact_restaurant_ratings();
end;
$$;

call run_etls();