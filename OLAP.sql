-- OLAP script: pulls fresh data from OLTP via FDW into local dw_staging tables
-- safe to rerun

-- creates all dw_staging tables if they don't exist yet
create or replace procedure refresh_dw_staging()
language plpgsql
as $$
begin
    create schema if not exists dw_staging;

    create table if not exists dw_staging.customers (
        email varchar(255),
        first_name varchar(100),
        last_name varchar(100),
        registration_date date
    );

    create table if not exists dw_staging.restaurants (
        restaurant_code varchar(50),
        restaurant_name varchar(150),
        restaurant_address varchar(255),
        region_city varchar(100)
    );

    create table if not exists dw_staging.menu_items (
        item_code varchar(50),
        item_name varchar(150),
        base_price numeric(10, 2),
        restaurant_code varchar(50),
        restaurant_name varchar(150),
        cuisine_code varchar(50),
        cuisine_name varchar(100)
    );

    create table if not exists dw_staging.sales (
        order_code varchar(50),
        customer_email varchar(255),
        restaurant_code varchar(50),
        item_code varchar(50),
        quantity int,
        historical_unit_price numeric(10, 2),
        delivery_fee numeric(10, 2),
        driver_tip numeric(10, 2),
        order_status varchar(50),
        order_date timestamp
    );

    create table if not exists dw_staging.reviews (
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

    insert into
        dw_staging.customers
    select
        email,
        first_name,
        last_name,
        registration_date
    from oltp_staging.customers where is_active = true;

    insert into
        dw_staging.restaurants
    select
        restaurant_code,
        restaurant_name,
        restaurant_address,
        trim(split_part(restaurant_address, ',', 2))
    from oltp_staging.restaurants where is_active = true;

    -- fan out menu items across cuisines (many-to-many join); inactive items excluded
    -- so their absence drives SCD2 retirement in update_menu_scd2()
    insert into
        dw_staging.menu_items
    select
        mi.item_code,
        mi.item_name,
        mi.base_price,
        r.restaurant_code,
        r.restaurant_name,
        c.cuisine_code,
        c.cuisine_name
    from oltp_staging.menu_items mi
        join oltp_staging.restaurants r on mi.restaurant_code = r.restaurant_code
        join oltp_staging.restaurant_cuisines rc on r.restaurant_code = rc.restaurant_code
        join oltp_staging.cuisines c on rc.cuisine_code = c.cuisine_code
    where mi.is_active = true and r.is_active = true;

    insert into
        dw_staging.sales
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
        join oltp_staging.order_items oi on o.order_code = oi.order_code
        join oltp_staging.menu_items m on oi.item_code = m.item_code;

    insert into
        dw_staging.reviews
    select
        email,
        restaurant_code,
        rating_score,
        review_text,
        review_date
    from oltp_staging.restaurant_reviews;
end;
$$;

-- creates all DWH tables if they don't exist yet
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
        registration_date date not null,
        is_active boolean not null default true
    );
    alter table if exists dim_customers add column if not exists is_active boolean not null default true;

    create table if not exists dim_cuisines (
        cuisine_key serial primary key,
        cuisine_code varchar(50)  not null unique,
        cuisine_name varchar(100) not null,
        is_active boolean not null default true
    );
    alter table if exists dim_cuisines add column if not exists is_active boolean not null default true;

    create table if not exists dim_geography (
        geography_key serial primary key,
        district varchar(100) not null,
        city varchar(100) not null default 'Vilnius',
        country varchar(100) not null default 'Lithuania',
        constraint uq_geography unique (district, city, country)
    );

    create table if not exists dim_restaurants (
        restaurant_key serial primary key,
        source_restaurant_code varchar(50)  not null unique,
        restaurant_name varchar(150) not null,
        restaurant_address varchar(255) not null,
        geography_key int not null references dim_geography(geography_key),
        is_active boolean not null default true
    );
    alter table if exists dim_restaurants add column if not exists is_active boolean not null default true;

    -- SCD2: each price or name change creates a new version row
    create table if not exists dim_menu_item_history (
        menu_item_key serial primary key,
        item_code varchar(50) not null,
        item_name varchar(150) not null,
        base_price decimal(10,2) not null,
        restaurant_key int not null references dim_restaurants(restaurant_key),
        valid_from timestamp not null,
        valid_to timestamp,
        is_current boolean not null default true
    );

    -- bridge table: many-to-many between restaurants and cuisines
    create table if not exists bridge_restaurant_cuisines (
        restaurant_key int not null references dim_restaurants(restaurant_key),
        cuisine_key int not null references dim_cuisines(cuisine_key),
        
        primary key (restaurant_key, cuisine_key)
    );

    create table if not exists dim_order_status (
        order_status_key serial primary key,
        status_code varchar(50) not null unique,
        status_label varchar(100) not null
    );

    create table if not exists fact_sales (
        fact_sales_id serial primary key,
        order_code varchar(50) not null,
        date_key int not null references dim_date(date_key),
        customer_key int not null references dim_customers(customer_key),
        restaurant_key int not null references dim_restaurants(restaurant_key),
        menu_item_key int not null references dim_menu_item_history(menu_item_key),
        order_status_key int not null references dim_order_status(order_status_key),
        quantity_ordered int not null,
        historical_unit_price   decimal(10,2) not null,
        line_item_gross_revenue decimal(10,2) not null,
        delivery_fees decimal(10,2),
        driver_tips decimal(10,2),
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

call refresh_dw_staging();
call ensure_tables();