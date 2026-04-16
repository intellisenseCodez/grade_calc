-- ============================================================
--  MAMA BUKKA RESTAURANT — DATABASE PROJECT
--  Phase 1: Database Setup & Administration
--  PostgreSQL | Version 1.0 | April 2026
-- ============================================================


-- ============================================================
-- SECTION 0: CREATE DATABASE
-- Run this block as a superuser (e.g., postgres) from psql
-- BEFORE connecting to mama_bukka_db.
-- ============================================================

-- NOTE: CREATE DATABASE cannot run inside a transaction block.
-- Execute this statement alone, then reconnect to mama_bukka_db.

CREATE DATABASE mama_bukka_db
    ENCODING    'UTF8'
    LC_COLLATE  'en_NG.UTF-8'
    LC_CTYPE    'en_NG.UTF-8'
    TEMPLATE    template0;   -- template0 is required when changing locale

-- Connect to the new database before running everything below:
-- \c mama_bukka_db


-- ============================================================
-- SECTION 1: SCHEMA IMPLEMENTATION (5.1.1)
-- ============================================================

-- ──────────────────────────────────────────────────────────
-- DESIGN NOTE — SERIAL vs UUID for Primary Keys
--
-- SERIAL/BIGSERIAL (chosen here):
--   + Simple integers — easy to read, join, and debug.
--   + Smaller storage (4 or 8 bytes vs 16 bytes for UUID).
--   + Native B-tree index performance is optimal.
--   - Sequential; exposes approximate record counts to
--     anyone who can read an ID.
--   - Not globally unique across databases/shards.
--
-- UUID (alternative):
--   + Globally unique — safe to merge data from multiple
--     sources (e.g., future branch locations).
--   + Does not leak business information.
--   - 16-byte storage; slightly larger indexes.
--   - Random UUIDs (v4) cause index fragmentation on INSERT.
--     UUID v7 (time-ordered) mitigates this in PG 17+.
--   - Harder to type/read in support queries.
--
-- Decision: BIGSERIAL is used throughout. Mama Bukka is a
-- single-location business with no current requirement for
-- distributed ID generation. If the business expands to
-- multiple sites, migrating to UUID v7 is straightforward.
-- ──────────────────────────────────────────────────────────


-- ──────────────────────────────────────────────────────────
-- TABLE: customer
-- Stores registered customers, contact info, and loyalty tier.
--
-- DESIGN NOTE — loyalty_tier implementation:
--   Option A (chosen): VARCHAR with a CHECK constraint.
--     CHECK (loyalty_tier IN ('bronze','silver','gold','vip'))
--     Pros: simple, no extra join, fast.
--     Cons: adding a new tier requires an ALTER TABLE.
--
--   Option B: Separate loyalty_tier lookup table with FK.
--     Pros: tiers can be added/renamed by INSERT, not ALTER.
--           Can store tier metadata (discount %, description).
--     Cons: requires a join on every customer query.
--
--   For a single-location restaurant with stable tier names,
--   Option A is sufficient and keeps queries simple. If tier
--   metadata (e.g., discount percentage) is ever needed,
--   migrating to Option B is the correct next step.
-- ──────────────────────────────────────────────────────────

CREATE TABLE customer (
    customer_id     BIGSERIAL       PRIMARY KEY,
    full_name       VARCHAR(150)    NOT NULL,
    phone_number    VARCHAR(20)     NOT NULL UNIQUE,
    email           VARCHAR(255)    UNIQUE,           -- nullable: not all customers have email
    address         TEXT,
    loyalty_tier    VARCHAR(10)     NOT NULL DEFAULT 'bronze'
                        CHECK (loyalty_tier IN ('bronze', 'silver', 'gold', 'vip')),
    registered_at   TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  customer                IS 'Registered customers including loyalty tier and contact details.';
COMMENT ON COLUMN customer.loyalty_tier   IS 'Tier assigned based on cumulative spend. Defaults to bronze on registration.';
COMMENT ON COLUMN customer.email          IS 'Optional — not all walk-in customers provide an email address.';


-- ──────────────────────────────────────────────────────────
-- TABLE: staff
-- Records all employees, their roles, and employment status.
-- ──────────────────────────────────────────────────────────

CREATE TABLE staff (
    staff_id        BIGSERIAL       PRIMARY KEY,
    full_name       VARCHAR(150)    NOT NULL,
    role            VARCHAR(50)     NOT NULL
                        CHECK (role IN ('manager', 'cashier', 'cook', 'delivery_rider', 'waiter', 'cleaner')),
    phone_number    VARCHAR(20)     NOT NULL UNIQUE,
    email           VARCHAR(255)    UNIQUE,
    hire_date       DATE            NOT NULL,
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  staff           IS 'All employees — current and former. is_active = FALSE for departed staff.';
COMMENT ON COLUMN staff.is_active IS 'Soft-delete flag. Records are never deleted to preserve order history integrity.';


-- ──────────────────────────────────────────────────────────
-- TABLE: supplier
-- Contact records for all ingredient suppliers.
-- ──────────────────────────────────────────────────────────

CREATE TABLE supplier (
    supplier_id     BIGSERIAL       PRIMARY KEY,
    supplier_name   VARCHAR(150)    NOT NULL,
    contact_person  VARCHAR(150),
    phone_number    VARCHAR(20)     NOT NULL UNIQUE,
    email           VARCHAR(255)    UNIQUE,
    address         TEXT,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE supplier IS 'Ingredient suppliers. Linked to inventory for traceability of stock sources.';


-- ──────────────────────────────────────────────────────────
-- TABLE: menu_item
-- Full catalogue of dishes with pricing and availability.
-- ──────────────────────────────────────────────────────────

CREATE TABLE menu_item (
    item_id         BIGSERIAL       PRIMARY KEY,
    item_name       VARCHAR(150)    NOT NULL UNIQUE,
    category        VARCHAR(50)     NOT NULL
                        CHECK (category IN ('soup', 'swallow', 'rice', 'protein', 'drink', 'other')),
    unit_price      NUMERIC(10, 2)  NOT NULL CHECK (unit_price > 0),
    is_available    BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  menu_item              IS 'Dish catalogue. Prices here are the CURRENT prices. Historical prices are stored in order_detail.';
COMMENT ON COLUMN menu_item.is_available IS 'Set to FALSE when a dish is temporarily off the menu (e.g., ingredient stockout).';


-- ──────────────────────────────────────────────────────────
-- TABLE: inventory
-- Current stock levels per ingredient with reorder threshold.
--
-- DESIGN NOTE — quantity_in_stock:
--   This column stores the current quantity for reporting
--   convenience but is always reconciled against inventory_log
--   (the authoritative source). A trigger updates this column
--   on every inventory_log INSERT (implemented in Phase 2).
-- ──────────────────────────────────────────────────────────

CREATE TABLE inventory (
    inventory_id        BIGSERIAL       PRIMARY KEY,
    ingredient_name     VARCHAR(150)    NOT NULL UNIQUE,
    unit_of_measure     VARCHAR(30)     NOT NULL,   -- e.g., 'kg', 'litres', 'pieces'
    quantity_in_stock   NUMERIC(12, 3)  NOT NULL DEFAULT 0
                            CHECK (quantity_in_stock >= 0),
    reorder_threshold   NUMERIC(12, 3)  NOT NULL CHECK (reorder_threshold >= 0),
    unit_cost           NUMERIC(10, 2)  NOT NULL CHECK (unit_cost > 0),
    supplier_id         BIGINT          REFERENCES supplier (supplier_id)
                            ON DELETE SET NULL,     -- preserve ingredient record if supplier is removed
    last_restocked_at   TIMESTAMPTZ,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  inventory                   IS 'Current stock per ingredient. quantity_in_stock is the live balance.';
COMMENT ON COLUMN inventory.reorder_threshold IS 'Low-stock alert fires when quantity_in_stock drops to or below this value.';
COMMENT ON COLUMN inventory.supplier_id       IS 'Primary supplier for this ingredient. ON DELETE SET NULL preserves the ingredient record.';


-- ──────────────────────────────────────────────────────────
-- TABLE: orders
-- Header record for every customer transaction.
--
-- DESIGN NOTE — ON DELETE behaviour for customer_id / staff_id:
--   ON DELETE RESTRICT is used on both FKs. Customers and staff
--   must never be physically deleted while orders reference them.
--   Soft-deletion (is_active flag on staff; equivalent on
--   customer) is the correct operational pattern. This constraint
--   enforces that discipline at the database level.
--
-- DESIGN NOTE — delivery_time CHECK:
--   The constraint delivery_time > order_time applies only when
--   delivery_time IS NOT NULL (i.e., the order has been
--   delivered). It is not valid for pending/in-progress orders.
-- ──────────────────────────────────────────────────────────

CREATE TABLE orders (
    order_id        BIGSERIAL       PRIMARY KEY,
    customer_id     BIGINT          NOT NULL
                        REFERENCES customer (customer_id) ON DELETE RESTRICT,
    staff_id        BIGINT          NOT NULL
                        REFERENCES staff (staff_id) ON DELETE RESTRICT,
    order_type      VARCHAR(20)     NOT NULL
                        CHECK (order_type IN ('dine-in', 'delivery', 'catering')),
    status          VARCHAR(20)     NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'confirmed', 'preparing', 'ready', 'delivered', 'cancelled')),
    order_time      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    delivery_time   TIMESTAMPTZ,
    delivery_address TEXT,          -- required for delivery orders; nullable for dine-in
    notes           TEXT,
    CONSTRAINT chk_delivery_time
        CHECK (delivery_time IS NULL OR delivery_time > order_time)
);

COMMENT ON TABLE  orders               IS 'One row per customer transaction (order header). Line items are in order_detail.';
COMMENT ON COLUMN orders.delivery_time IS 'Populated when order status transitions to ''delivered''. Must be after order_time.';
COMMENT ON COLUMN orders.staff_id      IS 'Staff member who took or is responsible for the order.';


-- ──────────────────────────────────────────────────────────
-- TABLE: order_detail
-- One row per dish per order (line items).
--
-- DESIGN NOTE — unit_price denormalisation:
--   unit_price stores the price AT THE TIME OF SALE, copied
--   from menu_item.unit_price at insert time. This is
--   intentional: menu prices change, but historical revenue
--   figures must remain accurate. This is a documented
--   departure from strict 3NF and is standard practice in
--   transactional systems (cf. GAAP revenue recording).
-- ──────────────────────────────────────────────────────────

CREATE TABLE order_detail (
    detail_id       BIGSERIAL       PRIMARY KEY,
    order_id        BIGINT          NOT NULL
                        REFERENCES orders (order_id) ON DELETE CASCADE,
                        -- Cascade: if an order header is deleted (e.g., test data cleanup),
                        -- its line items must go with it. Orders should not be deleted in
                        -- production — use status = 'cancelled' instead.
    item_id         BIGINT          NOT NULL
                        REFERENCES menu_item (item_id) ON DELETE RESTRICT,
    quantity        INTEGER         NOT NULL CHECK (quantity > 0),
    unit_price      NUMERIC(10, 2)  NOT NULL CHECK (unit_price > 0),  -- price at time of sale
    subtotal        NUMERIC(12, 2)  GENERATED ALWAYS AS (quantity * unit_price) STORED
);

COMMENT ON TABLE  order_detail           IS 'Line items within an order. One row per dish per order.';
COMMENT ON COLUMN order_detail.unit_price IS 'Price captured at time of sale — NOT a live reference to menu_item.unit_price.';
COMMENT ON COLUMN order_detail.subtotal   IS 'Computed column: quantity × unit_price. Stored for query performance.';


-- ──────────────────────────────────────────────────────────
-- TABLE: payment
-- Payment record linked to each order.
--
-- DESIGN NOTE — one payment per order:
--   A UNIQUE constraint on order_id enforces a 1-to-1
--   relationship between an order and its payment record.
--   Split payments are out of scope for v1.0. If partial or
--   split payments are required in future, this constraint
--   should be removed and a payment_type column added.
-- ──────────────────────────────────────────────────────────

CREATE TABLE payment (
    payment_id      BIGSERIAL       PRIMARY KEY,
    order_id        BIGINT          NOT NULL UNIQUE
                        REFERENCES orders (order_id) ON DELETE RESTRICT,
    amount          NUMERIC(12, 2)  NOT NULL CHECK (amount > 0),
    payment_method  VARCHAR(20)     NOT NULL
                        CHECK (payment_method IN ('cash', 'bank_transfer', 'pos')),
    payment_status  VARCHAR(20)     NOT NULL DEFAULT 'pending'
                        CHECK (payment_status IN ('pending', 'completed', 'failed', 'refunded')),
    paid_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  payment              IS 'One payment record per order. amount should match the sum of order_detail subtotals.';
COMMENT ON COLUMN payment.paid_at      IS 'Populated when payment_status transitions to ''completed''.';


-- ──────────────────────────────────────────────────────────
-- TABLE: inventory_log
-- Append-only audit log of all stock movements.
--
-- DESIGN NOTE — Event Sourcing pattern:
--   This table is NEVER updated or deleted from. Every stock
--   change (restock or consumption) is a new INSERT with a
--   signed quantity_change (+ve for stock in, -ve for stock
--   out). The authoritative current stock level for any
--   ingredient is:
--       SELECT SUM(quantity_change)
--       FROM inventory_log
--       WHERE inventory_id = <id>;
--   The inventory.quantity_in_stock column is a denormalised
--   cache updated by trigger (Phase 2) for query convenience.
--   Row-level security or a RULE can be added to physically
--   prevent UPDATE/DELETE on this table in production.
-- ──────────────────────────────────────────────────────────

CREATE TABLE inventory_log (
    log_id              BIGSERIAL       PRIMARY KEY,
    inventory_id        BIGINT          NOT NULL
                            REFERENCES inventory (inventory_id) ON DELETE RESTRICT,
    quantity_change     NUMERIC(12, 3)  NOT NULL,  -- positive = stock in, negative = stock out
    movement_type       VARCHAR(20)     NOT NULL
                            CHECK (movement_type IN ('restock', 'consumption', 'adjustment', 'wastage')),
    reference_order_id  BIGINT
                            REFERENCES orders (order_id) ON DELETE SET NULL,
                            -- Links consumption entries back to the order that caused them.
                            -- NULL for restocks, adjustments, and wastage.
    supplier_id         BIGINT
                            REFERENCES supplier (supplier_id) ON DELETE SET NULL,
                            -- Populated for restock movements only.
    notes               TEXT,
    logged_at           TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    logged_by           BIGINT
                            REFERENCES staff (staff_id) ON DELETE SET NULL
);

COMMENT ON TABLE  inventory_log                 IS 'Append-only event log of all stock movements. Never UPDATE or DELETE from this table.';
COMMENT ON COLUMN inventory_log.quantity_change IS 'Signed value: positive = stock received, negative = stock consumed or lost.';


-- ──────────────────────────────────────────────────────────
-- TABLE: catering_event
-- Full record of catering bookings.
--
-- DESIGN NOTE — separate from orders:
--   Catering events have attributes (event_date, venue,
--   guest_count, quoted_price, deposit_paid) that are
--   meaningless for walk-in or delivery orders. Merging them
--   into the orders table would produce many nullable columns
--   and violate clean entity design. The catering_event table
--   has a direct FK to customer (who booked) and staff
--   (who is assigned to manage the event).
-- ──────────────────────────────────────────────────────────

CREATE TABLE catering_event (
    event_id        BIGSERIAL       PRIMARY KEY,
    customer_id     BIGINT          NOT NULL
                        REFERENCES customer (customer_id) ON DELETE RESTRICT,
    assigned_staff  BIGINT
                        REFERENCES staff (staff_id) ON DELETE SET NULL,
    event_date      DATE            NOT NULL,
    venue           TEXT            NOT NULL,
    guest_count     INTEGER         NOT NULL CHECK (guest_count > 0),
    quoted_price    NUMERIC(12, 2)  NOT NULL CHECK (quoted_price > 0),
    deposit_paid    NUMERIC(12, 2)  NOT NULL DEFAULT 0
                        CHECK (deposit_paid >= 0),
    balance_due     NUMERIC(12, 2)  GENERATED ALWAYS AS (quoted_price - deposit_paid) STORED,
    payment_status  VARCHAR(20)     NOT NULL DEFAULT 'deposit_pending'
                        CHECK (payment_status IN ('deposit_pending', 'deposit_paid', 'fully_paid', 'cancelled')),
    notes           TEXT,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  catering_event             IS 'Catering bookings — distinct from standard orders due to event-specific attributes.';
COMMENT ON COLUMN catering_event.balance_due IS 'Computed: quoted_price − deposit_paid. Stored for reporting convenience.';


-- ============================================================
-- SECTION 2: INDEXES (5.1.1 — high-frequency query columns)
-- ============================================================

-- Foreign key indexes (prevent sequential scans on FK lookups)
CREATE INDEX idx_inventory_supplier        ON inventory        (supplier_id);
CREATE INDEX idx_orders_customer           ON orders           (customer_id);
CREATE INDEX idx_orders_staff              ON orders           (staff_id);
CREATE INDEX idx_order_detail_order        ON order_detail     (order_id);
CREATE INDEX idx_order_detail_item         ON order_detail     (item_id);
CREATE INDEX idx_payment_order             ON payment          (order_id);
CREATE INDEX idx_inventory_log_inventory   ON inventory_log    (inventory_id);
CREATE INDEX idx_inventory_log_order       ON inventory_log    (reference_order_id);
CREATE INDEX idx_inventory_log_supplier    ON inventory_log    (supplier_id);
CREATE INDEX idx_inventory_log_staff       ON inventory_log    (logged_by);
CREATE INDEX idx_catering_customer         ON catering_event   (customer_id);
CREATE INDEX idx_catering_staff            ON catering_event   (assigned_staff);

-- High-frequency query columns specified in requirements
CREATE INDEX idx_orders_order_time         ON orders           (order_time DESC);
CREATE INDEX idx_orders_status             ON orders           (status);

-- Composite index: most order queries filter by customer AND time range
CREATE INDEX idx_orders_customer_time      ON orders           (customer_id, order_time DESC);

-- Partial index: active (non-cancelled) orders only — very common filter
CREATE INDEX idx_orders_active             ON orders           (status, order_time DESC)
    WHERE status NOT IN ('delivered', 'cancelled');

-- Inventory low-stock queries
CREATE INDEX idx_inventory_low_stock       ON inventory        (quantity_in_stock)
    WHERE quantity_in_stock <= reorder_threshold;


-- ============================================================
-- SECTION 3: ROLE-BASED ACCESS CONTROL (5.1.2)
-- ============================================================

-- ──────────────────────────────────────────────────────────
-- Create roles (IF NOT EXISTS avoids error on re-run)
-- ──────────────────────────────────────────────────────────

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'admin_role') THEN
        CREATE ROLE admin_role;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cashier_role') THEN
        CREATE ROLE cashier_role;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kitchen_role') THEN
        CREATE ROLE kitchen_role;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'readonly_role') THEN
        CREATE ROLE readonly_role;
    END IF;
END
$$;


-- ──────────────────────────────────────────────────────────
-- ROLE: admin_role
-- Full access to all schema objects. Can DDL.
-- ──────────────────────────────────────────────────────────

GRANT ALL PRIVILEGES ON DATABASE mama_bukka_db TO admin_role;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO admin_role;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO admin_role;
GRANT CREATE ON SCHEMA public TO admin_role;

-- Ensure future tables/sequences are also covered
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL PRIVILEGES ON TABLES    TO admin_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL PRIVILEGES ON SEQUENCES TO admin_role;


-- ──────────────────────────────────────────────────────────
-- ROLE: cashier_role
-- INSERT + SELECT on orders, order_detail, payment only.
-- No DELETE. No UPDATE on any order record.
-- ──────────────────────────────────────────────────────────

GRANT SELECT, INSERT ON orders       TO cashier_role;
GRANT SELECT, INSERT ON order_detail TO cashier_role;
GRANT SELECT, INSERT ON payment      TO cashier_role;

-- Cashiers need to read the menu to place orders
GRANT SELECT ON menu_item  TO cashier_role;
GRANT SELECT ON customer   TO cashier_role;

-- Sequence access for INSERT (BIGSERIAL)
GRANT USAGE ON SEQUENCE orders_order_id_seq       TO cashier_role;
GRANT USAGE ON SEQUENCE order_detail_detail_id_seq TO cashier_role;
GRANT USAGE ON SEQUENCE payment_payment_id_seq     TO cashier_role;


-- ──────────────────────────────────────────────────────────
-- ROLE: kitchen_role
-- SELECT on orders and order_detail.
-- UPDATE on orders.status only (controlled via a view in Phase 2;
-- here we grant table-level UPDATE and rely on application logic,
-- or use a column-level grant for tighter control).
-- No access to payment or customer tables.
-- ──────────────────────────────────────────────────────────

GRANT SELECT ON orders       TO kitchen_role;
GRANT SELECT ON order_detail TO kitchen_role;
GRANT SELECT ON menu_item    TO kitchen_role;   -- needed to display dish names

-- Column-level UPDATE: kitchen can only change the status column
GRANT UPDATE (status) ON orders TO kitchen_role;


-- ──────────────────────────────────────────────────────────
-- ROLE: readonly_role
-- SELECT on all tables. Used by reporting tools and analysts.
-- ──────────────────────────────────────────────────────────

GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_role;

-- Ensure future tables are also readable by this role
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO readonly_role;


-- ──────────────────────────────────────────────────────────
-- EXAMPLE: Creating actual login users and assigning roles
-- (Replace passwords before running in production)
-- ──────────────────────────────────────────────────────────

-- CREATE USER db_admin    WITH PASSWORD 'change_me_admin'   IN ROLE admin_role;
-- CREATE USER cashier_app WITH PASSWORD 'change_me_cashier' IN ROLE cashier_role;
-- CREATE USER kitchen_app WITH PASSWORD 'change_me_kitchen' IN ROLE kitchen_role;
-- CREATE USER analyst     WITH PASSWORD 'change_me_readonly' IN ROLE readonly_role;


-- ============================================================
-- SECTION 4: SEED DATA (representative sample for testing)
-- ============================================================

-- Suppliers
INSERT INTO supplier (supplier_name, contact_person, phone_number, email, address) VALUES
    ('Eko Fresh Produce',     'Bayo Adewale',  '+2348031234567', 'eko@freshproduce.ng', 'Mile 12 Market, Lagos'),
    ('Lagos Grains & Spices', 'Ngozi Okonkwo', '+2348059876543', 'ngozi@lgspices.ng',   'Oyingbo Market, Lagos'),
    ('Mainland Meats Ltd',    'Seun Bello',    '+2348077654321', 'seun@mainmeat.ng',    'Ketu, Lagos');

-- Menu items
INSERT INTO menu_item (item_name, category, unit_price) VALUES
    ('Amala',            'swallow',  800.00),
    ('Eba',              'swallow',  700.00),
    ('Pounded Yam',      'swallow',  900.00),
    ('Ewedu Soup',       'soup',     500.00),
    ('Gbegiri Soup',     'soup',     600.00),
    ('Egusi Soup',       'soup',     800.00),
    ('Vegetable Soup',   'soup',     800.00),
    ('White Soup',       'soup',    1000.00),
    ('Peppersoup',       'soup',    1200.00),
    ('Jollof Rice',      'rice',    1000.00),
    ('Fried Rice',       'rice',    1100.00),
    ('Goat Meat',        'protein', 1500.00),
    ('Catfish',          'protein', 1800.00),
    ('Chicken',          'protein', 1400.00),
    ('Soft Drink (35cl)','drink',    300.00),
    ('Bottled Water',    'drink',    200.00);

-- Staff
INSERT INTO staff (full_name, role, phone_number, email, hire_date) VALUES
    ('Fatimah Adesanya', 'manager',         '+2348011111111', 'fatimah@mamabukka.ng', '2022-01-15'),
    ('Tunde Okafor',     'cashier',         '+2348022222222', 'tunde@mamabukka.ng',   '2022-03-01'),
    ('Amaka Eze',        'cook',            '+2348033333333', NULL,                   '2022-03-01'),
    ('Chukwuemeka Nze',  'delivery_rider',  '+2348044444444', NULL,                   '2023-06-10'),
    ('Blessing Dada',    'waiter',          '+2348055555555', NULL,                   '2023-08-20');

-- Customers
INSERT INTO customer (full_name, phone_number, email, address, loyalty_tier) VALUES
    ('Adaeze Obiora',  '+2348060001111', 'adaeze@gmail.com',  '5 Aba Road, Yaba, Lagos',   'gold'),
    ('Kehinde Salami', '+2348070002222', 'kehinde@yahoo.com', '12 Allen Ave, Ikeja, Lagos', 'silver'),
    ('Mrs Ronke Babs', '+2348080003333', NULL,                'Oworosoki Estate, Lagos',    'bronze');

-- Inventory
INSERT INTO inventory (ingredient_name, unit_of_measure, quantity_in_stock, reorder_threshold, unit_cost, supplier_id) VALUES
    ('Yam Flour (Elubo)',  'kg',      50.000, 10.000,  800.00, 2),
    ('Cassava (for Eba)',  'kg',      40.000,  8.000,  300.00, 2),
    ('Yam (for Pounded)', 'kg',      60.000, 10.000,  500.00, 1),
    ('Jute Leaves (Ewedu)','kg',     15.000,  3.000,  400.00, 1),
    ('Black-eyed Beans',  'kg',      20.000,  5.000,  600.00, 2),
    ('Ground Crayfish',   'kg',      10.000,  2.000, 1200.00, 2),
    ('Melon Seeds (Egusi)','kg',     12.000,  3.000,  900.00, 2),
    ('Spinach (Efo)',      'kg',      8.000,  2.000,  350.00, 1),
    ('Goat Meat',          'kg',     25.000,  5.000, 3500.00, 3),
    ('Catfish',            'kg',     18.000,  4.000, 2800.00, 3),
    ('Chicken',            'kg',     20.000,  5.000, 2200.00, 3),
    ('Long Grain Rice',    'kg',     80.000, 15.000,  650.00, 2),
    ('Palm Oil',           'litres', 30.000,  5.000, 1100.00, 1),
    ('Seasoning (Maggi)',  'pieces', 200.000, 50.000,   50.00, 2);

-- Sample orders with details and payments
INSERT INTO orders (customer_id, staff_id, order_type, status, order_time, delivery_time) VALUES
    (1, 2, 'dine-in',  'delivered', '2026-04-07 12:15:00+01', NULL),
    (2, 2, 'delivery', 'delivered', '2026-04-07 13:00:00+01', '2026-04-07 13:45:00+01'),
    (3, 2, 'dine-in',  'preparing', '2026-04-08 11:30:00+01', NULL);

INSERT INTO order_detail (order_id, item_id, quantity, unit_price) VALUES
    -- Order 1: Amala + Ewedu + Goat Meat
    (1, 1, 1, 800.00),
    (1, 4, 1, 500.00),
    (1, 12, 1, 1500.00),
    -- Order 2: Jollof Rice + Chicken + Soft Drink
    (2, 10, 2, 1000.00),
    (2, 14, 2, 1400.00),
    (2, 15, 2, 300.00),
    -- Order 3: Pounded Yam + Egusi + Catfish
    (3, 3, 1, 900.00),
    (3, 6, 1, 800.00),
    (3, 13, 1, 1800.00);

INSERT INTO payment (order_id, amount, payment_method, payment_status, paid_at) VALUES
    (1, 2800.00, 'pos',           'completed', '2026-04-07 12:50:00+01'),
    (2, 5400.00, 'bank_transfer', 'completed', '2026-04-07 13:10:00+01');
-- Order 3 payment is still pending

-- Sample inventory log entries
INSERT INTO inventory_log (inventory_id, quantity_change, movement_type, reference_order_id, supplier_id, notes, logged_by) VALUES
    (1,  50.000, 'restock',     NULL, 2, 'Opening stock — yam flour',        1),
    (9,  25.000, 'restock',     NULL, 3, 'Opening stock — goat meat',         1),
    (12, 80.000, 'restock',     NULL, 2, 'Opening stock — long grain rice',   1),
    (1,  -1.000, 'consumption', 1,   NULL, 'Amala for order #1',              2),
    (9,  -0.500, 'consumption', 1,   NULL, 'Goat meat for order #1',          2),
    (12, -1.500, 'consumption', 2,   NULL, 'Rice for order #2',               2),
    (11, -1.000, 'consumption', 2,   NULL, 'Chicken for order #2',            2);

-- Sample catering event
INSERT INTO catering_event (customer_id, assigned_staff, event_date, venue, guest_count, quoted_price, deposit_paid, payment_status, notes) VALUES
    (1, 1, '2026-05-10', 'Eko Hotel Banquet Hall, Victoria Island, Lagos', 150, 450000.00, 150000.00, 'deposit_paid',
     'Full Nigerian spread — amala, ewedu, jollof rice, assorted proteins. Client confirmed menu on 01/04/2026.');


-- ============================================================
-- SECTION 5: VERIFICATION QUERIES
-- Run these after setup to confirm everything is working.
-- ============================================================

-- 5a. Confirm all tables exist
SELECT tablename
FROM   pg_tables
WHERE  schemaname = 'public'
ORDER  BY tablename;

-- 5b. Confirm all roles exist
SELECT rolname FROM pg_roles
WHERE  rolname IN ('admin_role','cashier_role','kitchen_role','readonly_role');

-- 5c. Confirm all indexes exist
SELECT indexname, tablename
FROM   pg_indexes
WHERE  schemaname = 'public'
ORDER  BY tablename, indexname;

-- 5d. Revenue by order (quick sanity check)
SELECT
    o.order_id,
    c.full_name                        AS customer,
    o.order_type,
    o.status,
    SUM(od.subtotal)                   AS order_total,
    p.payment_method,
    p.payment_status
FROM   orders       o
JOIN   customer     c  ON c.customer_id = o.customer_id
JOIN   order_detail od ON od.order_id   = o.order_id
LEFT JOIN payment   p  ON p.order_id    = o.order_id
GROUP  BY o.order_id, c.full_name, o.order_type, o.status, p.payment_method, p.payment_status
ORDER  BY o.order_id;

-- 5e. Low-stock alert (ingredients at or below reorder threshold)
SELECT
    ingredient_name,
    quantity_in_stock,
    reorder_threshold,
    unit_of_measure
FROM   inventory
WHERE  quantity_in_stock <= reorder_threshold
ORDER  BY quantity_in_stock;

-- 5f. Catering events with balance due
SELECT
    ce.event_id,
    c.full_name        AS booked_by,
    ce.event_date,
    ce.venue,
    ce.guest_count,
    ce.quoted_price,
    ce.deposit_paid,
    ce.balance_due,
    ce.payment_status
FROM   catering_event ce
JOIN   customer       c ON c.customer_id = ce.customer_id
ORDER  BY ce.event_date;

-- ============================================================
-- END OF PHASE 1 SCRIPT
-- ============================================================
