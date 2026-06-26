Test 1: Initial state baseline
No changes. Just verify the load worked.

-- OLTP counts
select 'cuisines'            as tbl, count(*) from cuisines
union all select 'restaurants',               count(*) from restaurants
union all select 'customers',                 count(*) from customers
union all select 'menu_items',                count(*) from menu_items
union all select 'orders',                    count(*) from orders
union all select 'order_items',               count(*) from order_items;
-- expected: 9, 5, 8, 10, 14, 24

-- OLAP counts
select 'fact_sales'              as tbl, count(*) from fact_sales
union all select 'fact_ratings',           count(*) from fact_restaurant_ratings
union all select 'dim_menu_item_history',  count(*) from dim_menu_item_history;
-- expected: 24 fact_sales rows, 8 rating rows, 10 menu item versions
Test 2: Idempotency
Run the full pipeline twice without any data changes. Nothing should change.

-- capture counts before
select count(*) from fact_sales;         -- note this number
select count(*) from dim_menu_item_history;
Run: call run_oltp_pipeline(); then call run_etls();

-- counts should be identical after rerun
select count(*) from fact_sales;
select count(*) from dim_menu_item_history;
Test 3: Price change triggers SCD2
Edit menu_source.csv: change ITEM001 (Margherita Pizza) price from 14.99 to 16.99 on all rows where Item_Code = ITEM001.

Run: call run_oltp_pipeline(); then call run_etls();

-- should see 2 versions of ITEM001: one closed, one current
select item_code, item_name, base_price, valid_from, valid_to, is_current
from dim_menu_item_history
where item_code = 'ITEM001'
order by valid_from;
-- expected: row 1: base_price=14.99, valid_to IS NOT NULL, is_current=false
--           row 2: base_price=16.99, valid_to IS NULL,     is_current=true

-- old orders (ORD9901, ORD9904, ORD9909) must still reference the OLD version (14.99)
select fs.order_code, m.base_price as dim_price, fs.historical_unit_price
from fact_sales fs
join dim_menu_item_history m on fs.menu_item_key = m.menu_item_key
where m.item_code = 'ITEM001'
order by fs.order_code;
-- expected: dim_price = 14.99 for all existing orders
Test 4: New order flows end-to-end
Add this row to orders_source.csv:

ORD9915,diana.prince@email.com,"Žvėryno g. 19, Vilnius",2026-06-25 14:00:00,Delivered,ITEM007,2,10.99,1.99,3.00
Run: call run_oltp_pipeline(); then call run_etls();

-- must appear in OLTP
select * from orders where order_code = 'ORD9915';
select * from order_items where order_code = 'ORD9915';

-- must appear in fact_sales
select order_code, quantity_ordered, historical_unit_price, line_item_gross_revenue, net_revenue
from fact_sales
where order_code = 'ORD9915';
-- expected: quantity=2, unit_price=10.99, gross=21.98, net=21.98+delivery_share+tip_share
Test 5: Soft delete (customer removed from CSV)
Remove george.clooney@email.com from customers.csv.

Run: call run_oltp_pipeline();

select email, is_active from customers where email = 'george.clooney@email.com';
-- expected: is_active = false

-- his orders must still exist (append-only)
select count(*) from orders where email = 'george.clooney@email.com';
-- expected: 2
Test 6: Reactivation (soft-deleted customer comes back)
Add george.clooney@email.com back to customers.csv (same row as before).

Run: call run_oltp_pipeline();

select email, is_active from customers where email = 'george.clooney@email.com';
-- expected: is_active = true
Test 7: New review on an already-processed (date, restaurant) combo
This tests the ratings upsert fix. Add to reviews_source.csv:

bob.jones@email.com,REST03,3,Good but not as fresh this time.,2026-05-16 20:00:00
This is the same date (2026-05-16) and same restaurant (REST03) as charlie.brown's existing review.

Run: call run_oltp_pipeline(); then call run_etls();

-- fact_restaurant_ratings must now show count=2 and updated average for that day
select total_review_count, average_rating_score
from fact_restaurant_ratings frr
join dim_restaurants dr on frr.restaurant_key = dr.restaurant_key
join dim_date d on frr.date_key = d.date_key
where dr.source_restaurant_code = 'REST03'
  and d.full_date = '2026-05-16';
-- expected: total_review_count = 2, average_rating_score = 4.00  (5+3)/2
Test 8: Pro-rata fee allocation check
Verify the delivery fee math for a known order. ORD9901 has two items:

ITEM001: qty=2, price=14.99 → gross=29.98
ITEM002: qty=1, price=16.99 → gross=16.99
Total order gross = 46.97, delivery_fee=3.50, driver_tip=5.00
select
    order_code,
    historical_unit_price,
    quantity_ordered,
    line_item_gross_revenue,
    delivery_fees,
    driver_tips,
    net_revenue,
    -- manual check: delivery_fees should = 3.50 * (line_gross / 46.97)
    round(3.50 * line_item_gross_revenue / 46.97, 2) as expected_delivery,
    round(5.00 * line_item_gross_revenue / 46.97, 2) as expected_tip
from fact_sales
where order_code = 'ORD9901'
order by historical_unit_price;
-- delivery_fees and driver_tips must match expected_delivery and expected_tip
-- net_revenue must equal line_item_gross_revenue + delivery_fees + driver_tips
Test 9: Cancelled order still appears in fact_sales
ORD9904 has order_status = Cancelled. Verify it's tracked.

select fs.order_code, dos.status_code, fs.quantity_ordered, fs.net_revenue
from fact_sales fs
join dim_order_status dos on fs.order_status_key = dos.order_status_key
where fs.order_code = 'ORD9904';
-- expected: status_code = 'Cancelled', quantity_ordered = 1, net_revenue > 0

-- dim_order_status should contain both statuses
select status_code from dim_order_status order by status_code;
-- expected: Cancelled, Delivered
Quick reference: what to rerun for each type of change:

Change	Rerun
CSV data change only	call run_oltp_pipeline(); → call run_etls();
OLAP-only check (no data change)	call run_etls();
Full teardown and reload	call drop_oltp_schema(); → call run_oltp_pipeline(); → call run_etls();
FDW connection broken	Re-run OLTPtoOLAP_link.sql first, then run_etls()