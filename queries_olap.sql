-- OLAP Queries: delivery_olap database (port 5433)

-- ─────────────────────────────────────────────────────────────────────────────
-- Query 1: Monthly revenue breakdown by cuisine type
-- Uses the bridge table to fan revenue out across cuisine tags.
-- Answers: which cuisine categories drive the most revenue each month?
-- ─────────────────────────────────────────────────────────────────────────────

select
    d.calendar_year,
    d.month_name,
    dc.cuisine_name,
    count(distinct fs.order_code)          as orders,
    sum(fs.quantity_ordered)               as units_sold,
    sum(fs.line_item_gross_revenue)        as gross_revenue,
    sum(fs.net_revenue)                    as net_revenue
from fact_sales fs
join dim_date d           on fs.date_key        = d.date_key
join dim_restaurants dr   on fs.restaurant_key  = dr.restaurant_key
join bridge_restaurant_cuisines brc on dr.restaurant_key = brc.restaurant_key
join dim_cuisines dc      on brc.cuisine_key    = dc.cuisine_key
join dim_order_status dos on fs.order_status_key = dos.order_status_key
where dos.status_code = 'Delivered'
group by d.calendar_year, d.month_name, d.date_key / 100, dc.cuisine_name
order by d.calendar_year, d.date_key / 100, net_revenue desc;


-- ─────────────────────────────────────────────────────────────────────────────
-- Query 2: Revenue and ratings by city district
-- Walks the snowflake chain: fact_sales → dim_restaurants → dim_geography.
-- Answers: which Vilnius neighbourhood generates the most revenue and has
-- the best-rated restaurants?
-- ─────────────────────────────────────────────────────────────────────────────

select
    dg.district,
    count(distinct dr.restaurant_key)              as restaurant_count,
    sum(fs.net_revenue)                            as total_net_revenue,
    round(avg(fs.net_revenue), 2)                  as avg_order_net_revenue,
    round(avg(frr.average_rating_score), 2)        as avg_district_rating,
    sum(frr.total_review_count)                    as total_reviews
from dim_geography dg
join dim_restaurants dr   on dg.geography_key   = dr.geography_key
join fact_sales fs        on dr.restaurant_key  = fs.restaurant_key
left join fact_restaurant_ratings frr on dr.restaurant_key = frr.restaurant_key
join dim_order_status dos on fs.order_status_key = dos.order_status_key
where dos.status_code = 'Delivered'
group by dg.district
order by total_net_revenue desc;


-- ─────────────────────────────────────────────────────────────────────────────
-- Query 3: SCD2 price change impact on sales volume
-- For menu items that have more than one version in dim_menu_item_history,
-- compares units sold and revenue before and after each price change.
-- Answers: did orders go up or down after a price was updated?
-- ─────────────────────────────────────────────────────────────────────────────

with versions as (
    select
        item_code,
        item_name,
        base_price,
        menu_item_key,
        valid_from,
        valid_to,
        is_current,
        count(*) over (partition by item_code) as version_count
    from dim_menu_item_history
)
select
    v.item_code,
    v.item_name,
    v.base_price                                      as price_in_this_version,
    v.valid_from,
    coalesce(v.valid_to::text, 'current')             as valid_to,
    v.version_count,
    coalesce(sum(fs.quantity_ordered), 0)             as units_sold,
    coalesce(sum(fs.line_item_gross_revenue), 0)      as gross_revenue
from versions v
left join fact_sales fs on v.menu_item_key = fs.menu_item_key
where v.version_count > 1
group by v.item_code, v.item_name, v.base_price, v.menu_item_key,
         v.valid_from, v.valid_to, v.version_count
order by v.item_code, v.valid_from;
