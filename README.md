# Food Delivery: DB Course Work

## Setup

Start the containers (OLTP on port 5432, OLAP on port 5433, pgAdmin on 8080):

```bash
docker compose up -d
```

---

## Script execution

### 1. Load data into OLTP: run on `delivery_oltp` (port 5432)

```
OLTP.sql
```

Creates schema, stages CSVs from `initial_data_csv/`, loads everything into the OLTP tables. Already calls `run_oltp_pipeline()` at the end: just run the whole file.

### 2. Set up FDW link: run on `delivery_olap` (port 5433)

```
OLTP_to_OLAP.sql
```

Connects the OLAP database to OLTP via Foreign Data Wrapper. Run once.  
Calls `verify_fdw_staging_layers()` at the end to confirm the connection works.

### 3. Create OLAP tables: run on `delivery_olap` (port 5433)

```
OLAP.sql
```

Creates schemas for `dw_staging` and for DWH. Already calls procedures at the end: just run the whole file.

### 4. Run ETL: run on `delivery_olap` (port 5433)

```
ETL.sql
```

Populates the data warehouse from OLTP data. Calls `run_etls()` at the end.

### 5. Queries (optional)

| File | Run on |
|------|--------|
| `queries_oltp.sql` | `delivery_oltp` (port 5432) |
| `queries_olap.sql` | `delivery_olap` (port 5433) |

---

All scripts are idempotent: safe to rerun.
