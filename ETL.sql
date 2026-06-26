-- ETL script: loads data from OLTP into the DWH
-- safe to rerun

create or replace procedure populate_dim_date()
language plpgsql
as $$
declare
    v_start date;
    v_end   date;
begin
    select
        date_trunc('year', least(
            min(s.order_date::date),
            min(r.review_date::date)
        ))::date,
        (date_trunc('year', greatest(
            max(s.order_date::date),
            max(r.review_date::date)
        )) + interval '1 year - 1 day')::date
    into v_start, v_end
    from dw_staging.sales s, dw_staging.reviews r;

    -- fallback to current year if staging is empty
    v_start := coalesce(v_start, date_trunc('year', current_date)::date);
    v_end   := coalesce(v_end,   (date_trunc('year', current_date) + interval '1 year - 1 day')::date);

    insert into dim_date (date_key, full_date, day_of_week, month_name, calendar_quarter, calendar_year)
    select
        to_char(d, 'yyyymmdd')::int,
        d,
        trim(to_char(d, 'Day')),
        trim(to_char(d, 'Month')),
        'Q' || to_char(d, 'Q'),
        extract(year from d)::int
    from generate_series(v_start, v_end, '1 day'::interval) d
    on conflict (date_key) do nothing;
end;
$$;

-- SCD1 on customers, restaurants, cuisines: current values are overwritten
-- dim_geography and dim_order_status are stable lookups: new values appended only
-- soft-deletes: rows absent from staging are marked is_active = false
create or replace procedure sync_dimensions()
language plpgsql
as $$
begin
    -- customers (SCD1)
    insert into dim_customers (email, first_name, last_name, registration_date)
    select email, first_name, last_name, registration_date
    from dw_staging.customers
    on conflict (email) do update set
        first_name = excluded.first_name,
        last_name  = excluded.last_name,
        is_active  = true;

    update dim_customers set is_active = false
    where email not in (select email from dw_staging.customers);

    insert into dim_geography (district, city, country)
    select distinct region_city, 'Vilnius', 'Lithuania'
    from dw_staging.restaurants
    on conflict (district, city, country) do nothing;

    -- restaurants (SCD1)
    insert into dim_restaurants (source_restaurant_code, restaurant_name, restaurant_address, geography_key)
    select
        r.restaurant_code,
        r.restaurant_name,
        r.restaurant_address,
        g.geography_key
    from dw_staging.restaurants r
    join dim_geography g
        on r.region_city = g.district and g.city = 'Vilnius' and g.country = 'Lithuania'
    on conflict (source_restaurant_code) do update set
        restaurant_name    = excluded.restaurant_name,
        restaurant_address = excluded.restaurant_address,
        geography_key      = excluded.geography_key,
        is_active          = true;

    update dim_restaurants set is_active = false
    where source_restaurant_code not in (select restaurant_code from dw_staging.restaurants);

    -- cuisines (SCD1)
    insert into dim_cuisines (cuisine_code, cuisine_name)
    select distinct cuisine_code, cuisine_name
    from dw_staging.menu_items
    on conflict (cuisine_code) do update set
        cuisine_name = excluded.cuisine_name,
        is_active    = true;

    update dim_cuisines set is_active = false
    where cuisine_code not in (select distinct cuisine_code from dw_staging.menu_items);

    insert into dim_order_status (status_code, status_label)
    select distinct order_status, order_status
    from dw_staging.sales
    on conflict (status_code) do nothing;
end;
$$;

-- SCD2: closes the current version when price or name changes, then inserts a new one
-- items removed from OLTP get their current version closed (history preserved)
create or replace procedure update_menu_scd2()
language plpgsql
as $$
begin
    update dim_menu_item_history target
    set valid_to = now(), is_current = false
    from dw_staging.menu_items source
    where target.item_code = source.item_code
        and target.is_current = true
        and (
            target.base_price <> source.base_price
            or target.item_name <> source.item_name
        );

    update dim_menu_item_history
    set valid_to = now(), is_current = false
    where is_current = true
      and item_code not in (select distinct item_code from dw_staging.menu_items);

    -- valid_from: '01/01/1970' for brand-new items (covers all historical orders),
    -- now() for re-versions after a price/name change (orders before the change
    -- are already matched to the previous version that was just closed above)
    insert into dim_menu_item_history (
        item_code, item_name, base_price, restaurant_key, valid_from, valid_to, is_current
    )
    select distinct on (mi.item_code)
        mi.item_code, mi.item_name, mi.base_price, dr.restaurant_key,
        case
            when not exists (
                select 1 from dim_menu_item_history h where h.item_code = mi.item_code
            ) then '1970-01-01'::timestamp
            else now()
        end,
        null, true
    from dw_staging.menu_items mi
    join dim_restaurants dr on mi.restaurant_code = dr.source_restaurant_code
    where not exists (
        select 1
        from dim_menu_item_history existing
        where existing.item_code = mi.item_code
          and existing.is_current = true
    )
    order by mi.item_code;
end;
$$;

create or replace procedure sync_bridge_restaurant_cuisines()
language plpgsql
as $$
begin
    insert into bridge_restaurant_cuisines (restaurant_key, cuisine_key)
    select distinct
        dr.restaurant_key,
        dc.cuisine_key
    from dw_staging.menu_items mi
    join dim_restaurants dr on mi.restaurant_code = dr.source_restaurant_code
    join dim_cuisines dc on mi.cuisine_code = dc.cuisine_code
    on conflict (restaurant_key, cuisine_key) do nothing;
end;
$$;

-- delivery_fee and driver_tip are order-level costs; allocated to each line item
-- proportionally by its share of the order's gross revenue
create or replace procedure load_fact_sales()
language plpgsql
as $$
begin
    with order_totals as (
        select
            order_code,
            sum(quantity * historical_unit_price) as total_order_gross
        from dw_staging.sales
        group by order_code
    )
    insert into fact_sales (
        order_code, date_key, customer_key, restaurant_key, menu_item_key,
        order_status_key, quantity_ordered,
        historical_unit_price, line_item_gross_revenue, delivery_fees,
        driver_tips, net_revenue
    )
    select
        s.order_code,
        d.date_key,
        c.customer_key,
        r.restaurant_key,
        m.menu_item_key,
        os.order_status_key,
        s.quantity,
        s.historical_unit_price,
        (s.quantity * s.historical_unit_price)                                                           as line_item_gross_revenue,
        round(s.delivery_fee * (s.quantity * s.historical_unit_price) / ot.total_order_gross, 2)         as delivery_fees,
        round(s.driver_tip   * (s.quantity * s.historical_unit_price) / ot.total_order_gross, 2)         as driver_tips,
        (s.quantity * s.historical_unit_price)
            + round(s.delivery_fee * (s.quantity * s.historical_unit_price) / ot.total_order_gross, 2)
            + round(s.driver_tip   * (s.quantity * s.historical_unit_price) / ot.total_order_gross, 2)   as net_revenue
    from dw_staging.sales s
    join order_totals ot on s.order_code = ot.order_code
    join dim_customers c on s.customer_email = c.email
    join dim_restaurants r on s.restaurant_code = r.source_restaurant_code
    -- temporal join: pick the SCD2 version that was active when the order was placed
    join dim_menu_item_history m on s.item_code = m.item_code
         and s.order_date >= m.valid_from
         and (m.valid_to is null or s.order_date < m.valid_to)
    join dim_date d on cast(s.order_date as date) = d.full_date
    join dim_order_status os on s.order_status = os.status_code
    where not exists (
        select 1
        from fact_sales existing_fact
        where existing_fact.order_code    = s.order_code
          and existing_fact.menu_item_key = m.menu_item_key
    );
end;
$$;

-- aggregates reviews per (date, restaurant): recalculates totals on rerun
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
        count(*)                      as total_review_count,
        round(avg(r.rating_score), 2) as average_rating_score
    from dw_staging.reviews r
    join dim_date d        on cast(r.review_date as date) = d.full_date
    join dim_restaurants dr on r.restaurant_code = dr.source_restaurant_code
    group by d.date_key, dr.restaurant_key
    on conflict (date_key, restaurant_key) do update set
        total_review_count   = excluded.total_review_count,
        average_rating_score = excluded.average_rating_score;
end;
$$;

create or replace procedure run_etls()
language plpgsql
as $$
begin
    call refresh_dw_staging();
    call ensure_tables();
    call populate_dim_date();
    call sync_dimensions();
    call update_menu_scd2();
    call sync_bridge_restaurant_cuisines();
    call load_fact_sales();
    call load_fact_restaurant_ratings();
end;
$$;

call run_etls();
