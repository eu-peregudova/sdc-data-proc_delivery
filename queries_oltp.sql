-- OLTP Queries: delivery_oltp database (port 5432)

-- ─────────────────────────────────────────────────────────────────────────────
-- Query 1: Customer lifetime value
-- Who spends the most? Rank active customers by total spend (food + delivery + tip),
-- broken down by order count and average order size.
-- ─────────────────────────────────────────────────────────────────────────────

select
    c.first_name || ' ' || c.last_name                       as customer,
    c.email,
    count(distinct o.order_code)                             as total_orders,
    sum(oi.quantity * oi.historical_unit_price)              as food_spend,
    sum(o.delivery_fee + o.driver_tip)                       as fees_and_tips,
    sum(oi.quantity * oi.historical_unit_price
        + o.delivery_fee + o.driver_tip)                     as lifetime_spend,
    round(
        sum(oi.quantity * oi.historical_unit_price
            + o.delivery_fee + o.driver_tip)
        / count(distinct o.order_code), 2
    )                                                        as avg_order_value
from customers c
join orders o      on c.email = o.email
join order_items oi on o.order_code = oi.order_code
where o.order_status = 'Delivered'
group by c.email, c.first_name, c.last_name
order by lifetime_spend desc;


-- ─────────────────────────────────────────────────────────────────────────────
-- Query 2: Menu item popularity vs revenue
-- Which items are ordered most often and which generate the most revenue?
-- Includes cuisine tags to spot patterns across food categories.
-- ─────────────────────────────────────────────────────────────────────────────

select
    mi.item_code,
    mi.item_name,
    r.restaurant_name,
    string_agg(distinct c.cuisine_name, ', ' order by c.cuisine_name) as cuisines,
    count(oi.order_code)                                               as times_ordered,
    sum(oi.quantity)                                                   as units_sold,
    sum(oi.quantity * oi.historical_unit_price)                        as total_revenue,
    round(avg(oi.historical_unit_price), 2)                            as avg_sold_price
from menu_items mi
join restaurants r          on mi.restaurant_code = r.restaurant_code
join restaurant_cuisines rc on mi.restaurant_code = rc.restaurant_code
join cuisines c             on rc.cuisine_code    = c.cuisine_code
left join order_items oi    on mi.item_code       = oi.item_code
group by mi.item_code, mi.item_name, r.restaurant_name
order by total_revenue desc nulls last;


-- ─────────────────────────────────────────────────────────────────────────────
-- Query 3: Restaurant performance: orders, revenue, and ratings side by side
-- Combines transactional and review data to give a full picture of each restaurant.
-- Cancelled orders are counted separately to spot fulfilment issues.
-- ─────────────────────────────────────────────────────────────────────────────

select
    r.restaurant_name,
    r.restaurant_address,
    count(distinct o.order_code)
        filter (where o.order_status = 'Delivered')          as delivered_orders,
    count(distinct o.order_code)
        filter (where o.order_status = 'Cancelled')          as cancelled_orders,
    sum(oi.quantity * oi.historical_unit_price)
        filter (where o.order_status = 'Delivered')          as delivered_revenue,
    count(rr.review_date)                                    as review_count,
    round(avg(rr.rating_score), 2)                           as avg_rating
from restaurants r
left join orders o              on r.restaurant_code = o.restaurant_code
left join order_items oi        on o.order_code      = oi.order_code
left join restaurant_reviews rr on r.restaurant_code = rr.restaurant_code
group by r.restaurant_code, r.restaurant_name, r.restaurant_address
order by delivered_revenue desc nulls last;
