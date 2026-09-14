-- =========================================================
-- Test 02: Vie migration and DML
-- =========================================================

-- ========================================================
-- ========================================================
-- START SETUP
-- ========================================================
-- ========================================================

/* Extensions needed */
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS btree_gist;
SET search_path TO chronoturtle, public;

/* -------------------
   SCHEMA
   ------------------- */
CREATE SCHEMA management;
CREATE SCHEMA telematic;

/* -------------------
   ENUM
   ------------------- */
CREATE TYPE management.tire_type_enum AS ENUM ('winter','summer','all_season');
CREATE TYPE management.tire_status_enum AS ENUM ('mounted','stored','damaged','discarded');
CREATE TYPE management.fuel_type_enum AS ENUM ('gasoline','diesel','hybrid','electric');
CREATE TYPE management.customer_type_enum AS ENUM ('private','corporate');
CREATE TYPE management.skill_level_enum AS ENUM ('junior','mid','senior','master');
CREATE TYPE management.service_type_enum AS ENUM ('maintenance','repair','inspection','recall','recurring');
CREATE TYPE management.tire_set_status_enum AS ENUM ('stored','mounted','disposed');
CREATE TYPE management.engine_state_enum AS ENUM ('ok','warning','error');

-- ========================================================
-- 1) tire
-- Test cases:
--   - single table with many realistic typed columns (production_date, enums, numeric)
--   - referenced by other tables (tire_set, service_record)
--   - tests serial PK handling
-- ========================================================
CREATE TABLE management.tire
(
    id              SERIAL PRIMARY KEY,
    production_date DATE                        NOT NULL,
    tire_type       management.tire_type_enum   NOT NULL,
    size_text       TEXT                        NOT NULL, -- e.g. "205/55R16"
    profile_mm_left NUMERIC(4, 1)               NOT NULL, -- mm of tread left (decimal)
    brand           TEXT,
    pressure_psi    NUMERIC(5, 2),
    status          management.tire_status_enum NOT NULL DEFAULT 'stored',
    manufacturer_id INT,                                  -- optional link to manufacturer
    notes           TEXT,
    created_at      TIMESTAMPTZ                          DEFAULT Date('2025-11-24')::timestamptz
);

CREATE INDEX idx_tire_brand ON management.tire (brand);
CREATE INDEX idx_tire_status ON management.tire (status);

-- ========================================================
-- 2) manufacturer
-- Test cases:
--   - table with NO references (standalone)
--   - includes PostGIS location (GEOGRAPHY) for HQ location
--   - jsonb for miscellaneous details
-- ========================================================
CREATE TABLE management.manufacturer
(
    id           SERIAL PRIMARY KEY,
    name         TEXT NOT NULL,
    location     geometry(Geometry, 4326),
    founded_year INT,
    details      JSONB,
    created_at   TIMESTAMPTZ DEFAULT Date('2025-11-23')::timestamptz
);

CREATE INDEX idx_manufacturer_name ON management.manufacturer (name);

-- ========================================================
-- 3) garage
-- Test cases:
--   - table referenced by multiple tables (mechanic, service_record, tire_set)
--   - contains self reference (parent_garage_id)
--   - uses PostGIS GEOGRAPHY for location
-- ========================================================
CREATE TABLE management.garage
(
    garage_id        SERIAL PRIMARY KEY,
    parent_garage_id INT  REFERENCES management.garage (garage_id) ON DELETE SET NULL, -- self reference
    name             TEXT NOT NULL,
    location         geometry(Geometry, 2056),                                         -- e.g. POINT(lon lat)
    services_offered TEXT[],                                                           -- array of services
    opening_hours    JSONB,                                                            -- structured opening hours, timezone-aware
    rating           NUMERIC(3, 2),
    created_at       TIMESTAMPTZ DEFAULT Date('2025-11-22')::timestamptz
);

CREATE INDEX idx_garage_name ON management.garage (name);
-- Spatial index for PostGIS queries
CREATE INDEX idx_garage_location ON management.garage USING GIST (location);

-- ========================================================
-- 4) car
-- Test cases:
--   - UUID primary key table
--   - references manufacturer (no-ref table)
--   - referenced by tire_set (back-reference to installed_tire_set_id)
--   - arrays, jsonb, enums, and realistic columns
-- ========================================================
CREATE TABLE management.car
(
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vin             VARCHAR(17) UNIQUE        NOT NULL,
    manufacturer_id INT                       REFERENCES management.manufacturer (id) ON DELETE SET NULL,
    model           TEXT,
    model_trim      TEXT,
    year            INT,
    mileage_km      BIGINT           DEFAULT 0,
    fuel_type       management.fuel_type_enum NOT NULL,
    tags            TEXT[], -- keywords e.g. ['fleet','leased']
    options         JSONB,  -- options and packages
    created_at      TIMESTAMPTZ      DEFAULT Date('2025-11-21')::timestamptz
);

CREATE INDEX idx_car_manufacturer ON management.car (manufacturer_id);
CREATE INDEX idx_car_fuel ON management.car (fuel_type);

-- ========================================================
-- 5) tire_set
-- Test cases:
--   - uses composite PK
--   - grouping multiple FK references to the same table (4 management.tire FK columns)
--   - references car (UUID) and garage (storage location)
--   - tests update/remove semantics for sets
-- ========================================================
CREATE TABLE management.tire_set
(
    car_id              UUID                            REFERENCES management.car (id) ON DELETE SET NULL,
    front_left_tire_id  INT REFERENCES management.tire (id) ON DELETE RESTRICT,
    front_right_tire_id INT REFERENCES management.tire (id) ON DELETE RESTRICT,
    rear_left_tire_id   INT REFERENCES management.tire (id) ON DELETE RESTRICT,
    rear_right_tire_id  INT REFERENCES management.tire (id) ON DELETE RESTRICT,
    set_status          management.tire_set_status_enum NOT NULL DEFAULT 'stored',
    mounted_at          TIMESTAMPTZ,
    removed_at          TIMESTAMPTZ,
    storage_garage_id   INT                             REFERENCES management.garage (garage_id) ON DELETE SET NULL,
    notes               TEXT,

    PRIMARY KEY (front_left_tire_id, front_right_tire_id, rear_left_tire_id, rear_right_tire_id)
);

CREATE INDEX idx_tireset_car ON management.tire_set (car_id);
CREATE INDEX idx_tireset_status ON management.tire_set (set_status);

-- ========================================================
-- 6) tire_set_log
-- Test cases:
--   - uses composite FK referencing tire_set's composite PK
--   - tests foreign key integrity with multi-column references
-- ========================================================
CREATE TABLE management.tire_set_log
(
    id                  SERIAL PRIMARY KEY,
    front_left_tire_id  INT,
    front_right_tire_id INT,
    rear_left_tire_id   INT,
    rear_right_tire_id  INT,
    log                 TEXT,
    created_at          TIMESTAMPTZ DEFAULT Date('2025-11-28')::timestamptz,
    FOREIGN KEY (front_left_tire_id, front_right_tire_id, rear_left_tire_id, rear_right_tire_id)
        REFERENCES management.tire_set (front_left_tire_id, front_right_tire_id, rear_left_tire_id, rear_right_tire_id)
        ON DELETE RESTRICT
);

-- ========================================================
-- 7) owner
-- Test cases:
--   - SERIAL PK
--   - various contact fields and an enum
--   - used in many-to-many ownership history
--   - has UNIQUE constraint on email
-- ========================================================
CREATE TABLE management.owner
(
    id            SERIAL PRIMARY KEY,
    legal_name    TEXT                          NOT NULL,
    display_name  TEXT,
    address       TEXT,
    phone         TEXT,
    email         TEXT,
    customer_type management.customer_type_enum NOT NULL DEFAULT 'private',
    metadata      JSONB,
    created_at    TIMESTAMPTZ                            DEFAULT Date('2025-11-20')::timestamptz,

    UNIQUE (email)
);

CREATE INDEX idx_owner_email ON management.owner (email);

-- ========================================================
-- 8) car_owner_history
-- Test cases:
--   - references car (UUID) and management.owner (serial)
--   - uses TSRANGE to test temporal ownership ranges (range types)
--   - tests constraint with exclusion or check on overlapping ownership windows if needed
-- ========================================================
CREATE TABLE management.car_owner_history
(
    id               SERIAL PRIMARY KEY,
    car_id           UUID    NOT NULL REFERENCES management.car (id) ON DELETE CASCADE,
    owner_id         INT     NOT NULL REFERENCES management.owner (id) ON DELETE CASCADE,
    ownership_period TSRANGE NOT NULL, -- e.g. ['2020-01-01','2021-01-01']
    notes            TEXT,
    created_at       TIMESTAMPTZ DEFAULT Date('2025-11-19')::timestamptz
);

-- Example useful index (gin on range)
CREATE INDEX idx_car_owner_history_car_period ON management.car_owner_history USING GIST (car_id, ownership_period);

-- ========================================================
-- 9) mechanic
-- Test cases:
--   - SERIAL PK referencing garage
--   - arrays and enums to test text[] and skill-level enumeration
-- ========================================================
CREATE TABLE management.mechanic
(
    mechanic_id    SERIAL PRIMARY KEY,
    garage_id      INT  REFERENCES management.garage (garage_id) ON DELETE SET NULL,
    full_name      TEXT NOT NULL,
    certifications TEXT[], -- e.g. ['ASE A1','EV Certified']
    hire_date      DATE,
    skill_level    management.skill_level_enum DEFAULT 'mid',
    active         BOOLEAN                     DEFAULT true,
    notes          TEXT,
    created_at     TIMESTAMPTZ                 DEFAULT Date('2025-11-18')::timestamptz
);

CREATE INDEX idx_mechanic_garage ON management.mechanic (garage_id);
CREATE INDEX idx_mechanic_skill ON management.mechanic (skill_level);

-- ========================================================
-- 10) garage_mechanic
-- Test cases:
--   - Many-to-many join table (garage <-> mechanic)
--   - uses TSRANGE to represent shift ranges
--   - composite PK (garage_id, mechanic_id)
-- ========================================================
CREATE TABLE management.garage_mechanic
(
    garage_id   INT     NOT NULL REFERENCES management.garage (garage_id) ON DELETE CASCADE,
    mechanic_id INT     NOT NULL REFERENCES management.mechanic (mechanic_id) ON DELETE CASCADE,
    shift_range TSRANGE NOT NULL,
    role        TEXT,
    created_at  TIMESTAMPTZ DEFAULT Date('2025-11-17')::timestamptz,
    UNIQUE (garage_id, mechanic_id, shift_range),
    PRIMARY KEY (garage_id, mechanic_id)
);

CREATE INDEX idx_gma_garage ON management.garage_mechanic (garage_id);
CREATE INDEX idx_gma_mechanic ON management.garage_mechanic (mechanic_id);

-- ========================================================
-- 11) service_record
-- Test cases:
--   - Complex hub: references multiple other tables (car, mechanic, garage, tire)
--   - referenced by other tables (inspection)
--   - self-reference for follow-up services (related_service_id)
--   - includes jsonb diagnostics and TSRANGE service_window
--   - uses UUID PK
-- ========================================================
CREATE TABLE management.service_record
(
    service_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    car_id             UUID REFERENCES management.car (id) ON DELETE CASCADE,
    mechanic_id        INT                          REFERENCES management.mechanic (mechanic_id) ON DELETE SET NULL,
    garage_id          INT                          REFERENCES management.garage (garage_id) ON DELETE SET NULL,
    related_service_id UUID                         REFERENCES management.service_record (service_id) ON DELETE SET NULL, -- self reference
    tire_id            INT                          REFERENCES management.tire (id) ON DELETE SET NULL,
    service_type       management.service_type_enum NOT NULL,
    cost               NUMERIC(12, 2),
    notes              TEXT,
    service_window     TSRANGE,                                                                                           -- planned window for the service
    diagnostic_data    JSONB,                                                                                             -- e.g. diagnostics, DTC snapshots
    created_at         TIMESTAMPTZ      DEFAULT Date('2025-11-16')::timestamptz
);

CREATE INDEX idx_service_car ON management.service_record (car_id);
CREATE INDEX idx_service_garage ON management.service_record (garage_id);
CREATE INDEX idx_service_type ON management.service_record (service_type);

-- ========================================================
-- 12) inspection
-- Test cases:
--   - references management.service_record (tests referencing a UUID PK)
--   - stores jsonb for issues found
-- ========================================================
CREATE TABLE management.inspection
(
    id             SERIAL PRIMARY KEY,
    service_id     UUID REFERENCES management.service_record (service_id) ON DELETE CASCADE,
    inspector_name TEXT,
    passed         BOOLEAN,
    issues_found   JSONB,
    performed_at   TIMESTAMPTZ DEFAULT Date('2025-11-18')::timestamptz
);

CREATE INDEX idx_inspection_service ON management.inspection (service_id);

-- ========================================================
-- 13) feature
-- Test cases:
--   - master list table used in many-to-many with car (feature assignment)
--   - has UNIQUE constraint on name
-- ========================================================
CREATE TABLE management.feature
(
    feature_id  SERIAL PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    created_at  TIMESTAMPTZ DEFAULT Date('2025-11-14')::timestamptz
);

-- ========================================================
-- 14) management.car_feature
-- Test cases:
--   - car references multiple tables (car->feature)
--   - also demonstrates installation/unenrollment time windows
-- ========================================================
CREATE TABLE management.car_feature
(
    id           SERIAL PRIMARY KEY,
    car_id       UUID REFERENCES management.car (id) ON DELETE CASCADE,
    feature_id   INT REFERENCES management.feature (feature_id) ON DELETE CASCADE,
    installed_at TIMESTAMPTZ DEFAULT Date('2025-11-13')::timestamptz,
    removed_at   TIMESTAMPTZ,
    installed_by INT REFERENCES management.mechanic (mechanic_id) ON DELETE SET NULL,
    notes        TEXT
);

CREATE INDEX idx_cfa_car ON management.car_feature (car_id);
CREATE INDEX idx_cfa_feature ON management.car_feature (feature_id);

-- ========================================================
-- 15) telematic.telematics_snapshot
-- Test cases:
--   - different schema (telematic)
--   - jsonb (telematics), arrays (DTC codes), range (speed_range), gps jsonb
--   - tests storing varied telemetry and indexing strategies
-- ========================================================
CREATE TABLE telematic.telematics_snapshot
(
    id           SERIAL PRIMARY KEY,
    car_id       UUID REFERENCES management.car (id) ON DELETE CASCADE,
    snapshot_ts  TIMESTAMPTZ NOT NULL         DEFAULT Date('2025-11-12')::timestamptz,
    dtc_codes    TEXT[],    -- diagnostic trouble codes
    telematics   JSONB,     -- full device snapshot
    speed_range  INT4RANGE, -- min/max speed observed in snapshot window
    gps          JSONB,     -- { lat, lon, accuracy, path: [ ... ] }
    engine_state management.engine_state_enum DEFAULT 'ok'
);

CREATE INDEX idx_telematics_car_time ON telematic.telematics_snapshot (car_id, snapshot_ts);
CREATE INDEX idx_telematics_engine_state ON telematic.telematics_snapshot (engine_state);

-- ========================================================
-- 16) maintenance_ticket
-- Test cases:
--   - demonstrates SERIAL PK with a custom column name (custom_name_id)
--   - references a UUID PK and is referenced by others if needed
-- ========================================================
CREATE TABLE management.maintenance_ticket
(
    custom_name_id SERIAL PRIMARY KEY, -- custom-id name, tests ORMs that expect "id"
    service_id     UUID REFERENCES management.service_record (service_id) ON DELETE SET NULL,
    reported_by    INT  REFERENCES management.owner (id) ON DELETE SET NULL,
    description    TEXT,
    status         TEXT,
    created_at     TIMESTAMPTZ DEFAULT Date('2025-11-11')::timestamptz
);

CREATE INDEX idx_maintenance_service ON management.maintenance_ticket (service_id);

-- ========================================================
-- 17) Additional useful index / constraint examples
-- Test cases:
--   - unique and partial indexes to test DB optimization & constraint behaviour
-- ========================================================
-- Example: unique VIN already was created; here's a partial unique on manufacturer name + founded_year only if founded_year is not null
CREATE UNIQUE INDEX IF NOT EXISTS uq_manufacturer_name_year ON management.manufacturer (name, founded_year) WHERE founded_year IS NOT NULL;

-- ========================================================
-- ========================================================
-- START TESTS
-- ========================================================
-- ========================================================

-- =========================================================
-- STEP 1: Insert 1 row WITHOUT SERIAL PK for every table
-- =========================================================

-- manufacturer
INSERT INTO management.manufacturer (name, location, founded_year, details)
VALUES ('Example Tyres Ltd',
        ST_Transform(ST_SetSRID(ST_Point(2600000, 1200000), 2056), 4326),
        1958,
        '{
            "notes": "HQ in Switzerland",
            "website": "https://exampletyres.example"
        }'::jsonb);

-- garage
INSERT INTO management.garage (parent_garage_id, name, location, services_offered, opening_hours, rating)
VALUES (NULL,
        'Central Garage',
        ST_Transform(ST_SetSRID(ST_Point(2600000, 1200000), 2056), 2056),
        ARRAY ['tyre_change','inspection','maintenance'],
        '{
            "mon-fri": "08:00-18:00",
            "sat": "09:00-14:00"
        }'::jsonb,
        4.6);

-- owner
INSERT INTO management.owner (legal_name, display_name, address, phone, email, customer_type, metadata)
VALUES ('Max Muster',
        'M. Muster',
        'Example Street 1, 1000 Sampletown',
        '+41 44 000 00 01',
        'max.muster@example.com',
        'private',
        '{
            "notes": "VIP customer"
        }'::jsonb);

-- tire
INSERT INTO management.tire (production_date, tire_type, size_text, profile_mm_left, brand, pressure_psi, status, manufacturer_id, notes)
VALUES ('2024-06-15',
        'summer',
        '205/55R16',
        7.5,
        'GoodTyre',
        32.0,
        'stored',
        (SELECT id FROM management.manufacturer WHERE name = 'Example Tyres Ltd' LIMIT 1),
        'Batch A1');

-- car
INSERT INTO management.car (id, vin, manufacturer_id, model, model_trim, year, mileage_km, fuel_type, tags, options)
VALUES ('00000000-0000-0000-0000-000000000001'::uuid,
        'WDB1234561A654321',
        (SELECT id FROM management.manufacturer WHERE name = 'Example Tyres Ltd' LIMIT 1),
        'Model X',
        'Premium',
        2021,
        45200,
        'gasoline',
        ARRAY ['fleet','company'],
        '{
            "color": "black",
            "seats": 5
        }'::jsonb);

-- car_owner_history
INSERT INTO management.car_owner_history (car_id, owner_id, ownership_period)
VALUES ((SELECT id FROM management.car WHERE vin = 'WDB1234561A654321' LIMIT 1),
        (SELECT id FROM management.owner WHERE legal_name = 'Max Muster' LIMIT 1),
        '[2020-01-01,2021-01-01]'::tsrange);

-- tire_set
INSERT INTO management.tire_set (car_id, front_left_tire_id, front_right_tire_id, rear_left_tire_id, rear_right_tire_id, set_status,
                                 storage_garage_id, notes)
VALUES ((SELECT id FROM management.car WHERE vin = 'WDB1234561A654321'),
        (SELECT id FROM management.tire WHERE brand = 'GoodTyre' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'GoodTyre' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'GoodTyre' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'GoodTyre' LIMIT 1),
        'mounted',
        (SELECT garage_id FROM management.garage WHERE name = 'Central Garage' LIMIT 1),
        'Initial set');

-- tire_set
INSERT INTO management.tire_set_log (front_left_tire_id, front_right_tire_id, rear_left_tire_id, rear_right_tire_id, log)
VALUES ((SELECT id FROM management.tire WHERE brand = 'GoodTyre' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'GoodTyre' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'GoodTyre' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'GoodTyre' LIMIT 1),
        'Intern accidentally punctured the left rear tire, we just glued it');

-- mechanic
INSERT INTO management.mechanic (garage_id, full_name, certifications, hire_date, skill_level, active, notes)
VALUES ((SELECT garage_id FROM management.garage WHERE name = 'Central Garage'),
        'John Doe',
        ARRAY ['ASE A1','EV Certified'],
        '2018-05-01',
        'senior',
        true,
        'Lead mechanic');

-- garage_mechanic
INSERT INTO management.garage_mechanic (garage_id, mechanic_id, shift_range, role)
VALUES ((SELECT garage_id FROM management.garage WHERE name = 'Central Garage'),
        (SELECT mechanic_id FROM management.mechanic WHERE full_name = 'John Doe'),
        '[2025-11-01 08:00:00,2025-11-01 16:00:00)'::tsrange,
        'shift_lead');

-- service_record
INSERT INTO management.service_record (service_id, car_id, mechanic_id, garage_id, tire_id, service_type, cost, notes)
VALUES ('00000000-0000-0000-0000-000000000002'::uuid,
        (SELECT id FROM management.car WHERE vin = 'WDB1234561A654321'),
        (SELECT mechanic_id FROM management.mechanic WHERE full_name = 'John Doe'),
        (SELECT garage_id FROM management.garage WHERE name = 'Central Garage'),
        (SELECT id FROM management.tire WHERE brand = 'GoodTyre' LIMIT 1),
        'maintenance',
        249.99,
        'Oil change and basic inspection');

-- inspection
INSERT INTO management.inspection (service_id, inspector_name, passed, issues_found)
VALUES ((SELECT service_id FROM management.service_record LIMIT 1),
        'Richard Roe',
        true,
        '[]'::jsonb);

-- feature
INSERT INTO management.feature (name, description)
VALUES ('Heated Seats', 'Seats with internal heating');

-- car_feature
INSERT INTO management.car_feature (car_id, feature_id, installed_at, installed_by, notes)
VALUES ((SELECT id FROM management.car WHERE vin = 'WDB1234561A654321'),
        (SELECT feature_id FROM management.feature WHERE name = 'Heated Seats'),
        Date('2025-11-10')::timestamptz,
        (SELECT mechanic_id FROM management.mechanic WHERE full_name = 'John Doe'),
        'Installed at purchase');

-- telematics_snapshot
INSERT INTO telematic.telematics_snapshot (car_id, snapshot_ts, dtc_codes, telematics, speed_range, gps, engine_state)
VALUES ((SELECT id FROM management.car WHERE vin = 'WDB1234561A654321'),
        Date('2025-11-10')::timestamptz,
        ARRAY []::text[],
        '{
            "battery": 98,
            "temp_c": 22
        }'::jsonb,
        '[0,120]'::int4range,
        '{
            "lat": 47.376887,
            "lon": 8.541694
        }'::jsonb,
        'ok');

-- maintenance_ticket
INSERT INTO management.maintenance_ticket (service_id, reported_by, description, status)
VALUES ((SELECT service_id FROM management.service_record LIMIT 1),
        (SELECT id FROM management.owner WHERE legal_name = 'Max Muster'),
        'Customer reports vibration at high speed',
        'open');


-- =========================================================
-- STEP 2: migrate to vie
-- =========================================================
SELECT set_commit_author('alice@example.com');
SELECT migrate_schemas_to_vie('management', 'telematic');

SELECT *
FROM management.maintenance_ticket;
SELECT *
FROM management.inspection;
SELECT *
FROM telematic.telematics_snapshot;
SELECT *
FROM management.car_feature;
SELECT *
FROM management.car_owner_history;
SELECT *
FROM management.garage_mechanic;
SELECT *
FROM management.tire_set;
SELECT *
FROM management.tire_set_log;
SELECT *
FROM management.service_record;
SELECT *
FROM management.mechanic;
SELECT *
FROM management.car;
SELECT *
FROM management.feature;
SELECT *
FROM management.owner;
SELECT *
FROM management.garage;
SELECT *
FROM management.tire;
SELECT *
FROM management.manufacturer;

-- =========================================================
-- STEP 3: Insert 1 row WITH PK for every table
-- =========================================================
-- manufacturer
INSERT INTO management.manufacturer (id, name, location, founded_year, details)
VALUES (1001,
        'Sample Wheels Ltd',
        ST_SetSRID(ST_Point(8.541694, 47.376887), 4326),
        1975,
        '{
            "special": "high performance"
        }'::jsonb);
SELECT *
FROM management.manufacturer;

-- garage
INSERT INTO management.garage (garage_id, parent_garage_id, name, location, services_offered, opening_hours, rating)
VALUES (5001,
        NULL,
        'North Garage',
        ST_SetSRID(ST_Point(7.588576, 47.559598), 2056),
        ARRAY ['inspection','repair'],
        '{
            "mon-fri": "07:00-17:00"
        }'::jsonb,
        4.2);
SELECT *
FROM management.garage;

-- owner
INSERT INTO management.owner (id, legal_name, display_name, address, phone, email, customer_type, metadata)
VALUES (3001,
        'Müster Logistics Ltd',
        'MüsterLog',
        'Example Park 5, 1000 Sampletown',
        '+41 44 000 11 22',
        'contact@muesterlog.example',
        'corporate',
        '{
            "fleet_size": 80
        }'::jsonb);
SELECT *
FROM management.owner;

-- tire
INSERT INTO management.tire (id, production_date, tire_type, size_text, profile_mm_left, brand, pressure_psi, status, manufacturer_id)
VALUES (2001,
        '2023-11-01',
        'winter',
        '195/65R15',
        9.2,
        'SwissGrip',
        34.0,
        'mounted',
        1001);
SELECT *
FROM management.tire;

-- car
INSERT INTO management.car (id, vin, manufacturer_id, model, model_trim, year, mileage_km, fuel_type, tags, options)
VALUES ('11111111-1111-1111-1111-111111111111'::uuid,
        '1HGCM82633A004352',
        1001,
        'Model S',
        'Long Range',
        2020,
        12000,
        'electric',
        ARRAY ['leased'],
        '{
            "battery_kwh": 85
        }'::jsonb);
INSERT INTO management.car (id, vin, manufacturer_id, model, model_trim, year, mileage_km, fuel_type, tags, options)
VALUES ('22222222-2222-2222-2222-222222222222'::uuid,
        'VF1RFB00456812345',
        (SELECT id FROM management.manufacturer WHERE name = 'Demo Wheels Ltd' LIMIT 1),
        'Model A',
        'Comfort',
        2019,
        38000,
        'diesel',
        ARRAY ['company'],
        '{
            "color": "silver",
            "seats": 5
        }'::jsonb);
SELECT *
FROM management.car;

-- tire_set
INSERT INTO management.tire_set (car_id, front_left_tire_id, front_right_tire_id, rear_left_tire_id, rear_right_tire_id, set_status,
                                 storage_garage_id)
VALUES ('11111111-1111-1111-1111-111111111111'::uuid,
        2001,
        2001,
        2001,
        2001,
        'stored',
        5001);
SELECT *
FROM management.tire_set;

-- tire_set_log
INSERT INTO management.tire_set_log (front_left_tire_id, front_right_tire_id, rear_left_tire_id, rear_right_tire_id, log)
VALUES (2001,
        2001,
        2001,
        2001,
        'have one flat spot');
SELECT *
FROM management.tire_set_log;

-- mechanic
INSERT INTO management.mechanic (mechanic_id, garage_id, full_name, certifications, hire_date, skill_level, active)
VALUES (7001,
        5001,
        'Erika Müster',
        ARRAY ['ASE B2'],
        '2020-09-15',
        'mid',
        true);
SELECT *
FROM management.mechanic;

-- garage_mechanic
INSERT INTO management.garage_mechanic (garage_id, mechanic_id, shift_range, role)
VALUES (5001,
        7001,
        '[2025-11-02 08:00:00,2025-11-02 16:00:00)'::tsrange,
        'morning');
SELECT *
FROM management.garage_mechanic;

-- service_record
INSERT INTO management.service_record (service_id, car_id, mechanic_id, garage_id, tire_id, service_type, cost, notes)
VALUES ('22222222-2222-2222-2222-222222222222'::uuid,
        '11111111-1111-1111-1111-111111111111'::uuid,
        7001,
        5001,
        2001,
        'repair',
        1024.50,
        'Brake pad replacement');
INSERT INTO management.service_record (service_id, car_id, mechanic_id, garage_id, tire_id, service_type, cost, notes)
VALUES ('33333333-3333-3333-3333-333333333333'::uuid,
        (SELECT id FROM management.car WHERE vin = 'VF1RFB00456812345'),
        (SELECT mechanic_id FROM management.mechanic WHERE full_name = 'Joe Bloggs'),
        (SELECT garage_id FROM management.garage WHERE name = 'East Garage'),
        (SELECT id FROM management.tire WHERE brand = 'AlpineGrip' LIMIT 1),
        'inspection',
        299.99,
        'Pre-winter inspection');
SELECT *
FROM management.service_record;

-- inspection
INSERT INTO management.inspection (id, service_id, inspector_name, passed, issues_found)
VALUES (9001,
        '22222222-2222-2222-2222-222222222222'::uuid,
        'Mary Major',
        false,
        '{
            "brakes": "worn",
            "lights": "ok"
        }'::jsonb);
SELECT *
FROM management.inspection;

-- feature
INSERT INTO management.feature (feature_id, name, description)
VALUES (6001, 'Sunroof', 'Panoramic sunroof');
SELECT *
FROM management.feature;

-- car_feature
INSERT INTO management.car_feature (id, car_id, feature_id, installed_at, installed_by)
VALUES (70001,
        '11111111-1111-1111-1111-111111111111'::uuid,
        6001,
        Date('2025-11-10')::timestamptz - interval '365 days',
        7001);
SELECT *
FROM management.car_feature;

-- telematics_snapshot
INSERT INTO telematic.telematics_snapshot (id, car_id, snapshot_ts, dtc_codes, telematics, speed_range, gps, engine_state)
VALUES (10001,
        '11111111-1111-1111-1111-111111111111'::uuid,
        Date('2025-11-10')::timestamptz - interval '1 day',
        ARRAY ['P0420'],
        '{
            "battery": 75,
            "temp_c": 15
        }'::jsonb,
        '[10,90]'::int4range,
        '{
            "lat": 46.204391,
            "lon": 6.143157
        }'::jsonb,
        'warning');
SELECT *
FROM telematic.telematics_snapshot;

-- maintenance_ticket
INSERT INTO management.maintenance_ticket (custom_name_id, service_id, reported_by, description, status)
VALUES (90001,
        '22222222-2222-2222-2222-222222222222'::uuid,
        3001,
        'Brake squeal on cold mornings',
        'open');
SELECT *
FROM management.maintenance_ticket;

-- =========================================================
-- STEP 4: Insert 1 row WITHOUT PK for every table
-- =========================================================
SELECT set_commit_author('bob@example.com');

-- manufacturer
INSERT INTO management.manufacturer (name, location, founded_year, details)
VALUES ('Demo Wheels Ltd',
        ST_SetSRID(ST_Point(7.4474, 46.9481), 4326),
        1982,
        '{
            "special": "off-road",
            "website": "https://demowheels.example"
        }'::jsonb);
SELECT *
FROM management.manufacturer;

-- garage
INSERT INTO management.garage (parent_garage_id, name, location, services_offered, opening_hours, rating)
VALUES (NULL,
        'East Garage',
        ST_SetSRID(ST_Point(6.143157, 46.204391), 2056),
        ARRAY ['tyre_change','inspection'],
        '{
            "mon-fri": "08:00-18:00"
        }'::jsonb,
        4.1);
SELECT *
FROM management.garage;

-- owner
INSERT INTO management.owner (legal_name, display_name, address, phone, email, customer_type, metadata)
VALUES ('Sample Autos Ltd',
        'Sample Autos',
        'Example Street 12, 1000 Sampletown',
        '+41 41 000 22 33',
        'contact@sampleautos.example',
        'corporate',
        '{
            "fleet_size": 15
        }'::jsonb);
SELECT *
FROM management.owner;

-- tire
INSERT INTO management.tire (production_date, tire_type, size_text, profile_mm_left, brand, pressure_psi, status, manufacturer_id)
VALUES ('2025-01-20',
        'summer',
        '225/45R17',
        8.0,
        'AlpineGrip',
        33.5,
        'mounted',
        (SELECT id FROM management.manufacturer WHERE name = 'Demo Wheels Ltd' LIMIT 1));
SELECT *
FROM management.tire;

-- tire_set
INSERT INTO management.tire_set (car_id, front_left_tire_id, front_right_tire_id, rear_left_tire_id, rear_right_tire_id, set_status,
                                 storage_garage_id)
VALUES ((SELECT id FROM management.car WHERE vin = 'VF1RFB00456812345'),
        (SELECT id FROM management.tire WHERE brand = 'AlpineGrip' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'AlpineGrip' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'AlpineGrip' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'AlpineGrip' LIMIT 1),
        'stored',
        (SELECT garage_id FROM management.garage WHERE name = 'East Garage'));
SELECT *
FROM management.tire_set;

-- tire_set_log
INSERT INTO management.tire_set_log (front_left_tire_id, front_right_tire_id, rear_left_tire_id, rear_right_tire_id, log)
VALUES ((SELECT front_left_tire_id FROM management.tire_set WHERE set_status = 'stored' LIMIT 1),
        (SELECT front_right_tire_id FROM management.tire_set WHERE set_status = 'stored' LIMIT 1),
        (SELECT rear_left_tire_id FROM management.tire_set WHERE set_status = 'stored' LIMIT 1),
        (SELECT rear_right_tire_id FROM management.tire_set WHERE set_status = 'stored' LIMIT 1),
        'balanced read tires');
SELECT *
FROM management.tire_set_log;

-- mechanic
INSERT INTO management.mechanic (garage_id, full_name, certifications, hire_date, skill_level, active)
VALUES ((SELECT garage_id FROM management.garage WHERE name = 'East Garage'),
        'Joe Bloggs',
        ARRAY ['ASE C1'],
        '2019-03-10',
        'mid',
        true);
SELECT *
FROM management.mechanic;

-- garage_mechanic
INSERT INTO management.garage_mechanic (garage_id, mechanic_id, shift_range, role)
VALUES ((SELECT garage_id FROM management.garage WHERE name = 'East Garage'),
        (SELECT mechanic_id FROM management.mechanic WHERE full_name = 'Joe Bloggs'),
        '[2025-11-03 08:00:00,2025-11-03 16:00:00)'::tsrange,
        'morning');
SELECT *
FROM management.garage_mechanic;

-- inspection
INSERT INTO management.inspection (service_id, inspector_name, passed, issues_found)
VALUES ((SELECT service_id FROM management.service_record LIMIT 1 OFFSET 1),
        'Jane Roe',
        true,
        '[]'::jsonb);
SELECT *
FROM management.inspection;

-- feature
INSERT INTO management.feature (name, description)
VALUES ('Parking Sensors', 'Front and rear parking sensors');
SELECT *
FROM management.feature;

-- car_feature
INSERT INTO management.car_feature (car_id, feature_id, installed_at, installed_by, notes)
VALUES ((SELECT id FROM management.car WHERE vin = 'VF1RFB00456812345'),
        (SELECT feature_id FROM management.feature WHERE name = 'Parking Sensors'),
        Date('2025-11-10')::timestamptz,
        (SELECT mechanic_id FROM management.mechanic WHERE full_name = 'Joe Bloggs'),
        'Optional install');
SELECT *
FROM management.car_feature;

-- telematics_snapshot
INSERT INTO telematic.telematics_snapshot (car_id, snapshot_ts, dtc_codes, telematics, speed_range, gps, engine_state)
VALUES ((SELECT id FROM management.car WHERE vin = 'VF1RFB00456812345'),
        Date('2025-11-10')::timestamptz,
        ARRAY []::text[],
        '{
            "battery": 85,
            "temp_c": 18
        }'::jsonb,
        '[0,110]'::int4range,
        '{
            "lat": 46.9481,
            "lon": 7.4474
        }'::jsonb,
        'ok');
SELECT *
FROM telematic.telematics_snapshot;

-- maintenance_ticket
INSERT INTO management.maintenance_ticket (service_id, reported_by, description, status)
VALUES ((SELECT service_id FROM management.service_record LIMIT 1 OFFSET 1),
        (SELECT id FROM management.owner WHERE legal_name = 'Sample Autos Ltd'),
        'Strange noise from front tires',
        'open');
SELECT *
FROM management.maintenance_ticket;

-- =========================================================
-- STEP 5: Insert with DUPLICATE PK for every table - should throw error
-- =========================================================

-- manufacturer (duplicate PK 1001)
INSERT INTO management.manufacturer (id, name, location, founded_year, details)
VALUES (1001,
        'Duplicate Wheels',
        ST_SetSRID(ST_Point(8, 47), 4326),
        2000,
        '{
            "notes": "duplicate"
        }'::jsonb);

-- garage (duplicate PK 5001)
INSERT INTO management.garage (garage_id, parent_garage_id, name, location, services_offered, opening_hours, rating)
VALUES (5001,
        NULL,
        'Duplicate Garage',
        ST_SetSRID(ST_Point(8, 47), 2056),
        ARRAY ['inspection'],
        '{
            "mon-fri": "08:00-17:00"
        }'::jsonb,
        3.5);

-- owner (duplicate PK 3001)
INSERT INTO management.owner (id, legal_name, display_name, address, phone, email, customer_type, metadata)
VALUES (3001,
        'Duplicate Owner',
        'DupOwner',
        'Test Street 1',
        '+41 000 000 00',
        'dup@example.com',
        'private',
        '{
            "note": "duplicate"
        }'::jsonb);

-- tire (duplicate PK 2001)
INSERT INTO management.tire (id, production_date, tire_type, size_text, profile_mm_left, brand, pressure_psi, status, manufacturer_id)
VALUES (2001,
        '2025-01-01',
        'winter',
        '205/50R17',
        7.0,
        'DuplicateTire',
        31.0,
        'stored',
        1001);

-- car (duplicate PK uuid '11111111-1111-1111-1111-111111111111')
INSERT INTO management.car (id, vin, manufacturer_id, model, model_trim, year, mileage_km, fuel_type, tags, options)
VALUES ('11111111-1111-1111-1111-111111111111'::uuid,
        'DUPVIN0000001',
        1001,
        'Duplicate Car',
        'Trim1',
        2022,
        1000,
        'electric',
        ARRAY ['test'],
        '{
            "color": "white"
        }'::jsonb);

-- tire_set (duplicate PK 2001)
INSERT INTO management.tire_set (car_id, front_left_tire_id, front_right_tire_id, rear_left_tire_id, rear_right_tire_id, set_status,
                                 storage_garage_id)
VALUES ('11111111-1111-1111-1111-111111111111'::uuid,
        2001, 2001, 2001, 2001,
        'stored',
        5001);

-- mechanic (duplicate PK 7001)
INSERT INTO management.mechanic (mechanic_id, garage_id, full_name, certifications, hire_date, skill_level, active)
VALUES (7001,
        5001,
        'Duplicate Mechanic',
        ARRAY ['ASE D1'],
        '2021-01-01',
        'junior',
        true);

-- garage_mechanic (duplicate PK 5001, 7001)
INSERT INTO management.garage_mechanic (garage_id, mechanic_id, shift_range, role)
VALUES (5001,
        7001,
        '[2025-11-04 08:00:00,2025-11-04 16:00:00)'::tsrange,
        'afternoon');

-- service_record (duplicate PK '22222222-2222-2222-2222-222222222222')
INSERT INTO management.service_record (service_id, car_id, mechanic_id, garage_id, tire_id, service_type, cost, notes)
VALUES ('22222222-2222-2222-2222-222222222222'::uuid,
        '11111111-1111-1111-1111-111111111111'::uuid,
        7001,
        5001,
        2001,
        'repair',
        999.99,
        'Duplicate entry');

-- inspection (duplicate PK 9001)
INSERT INTO management.inspection (id, service_id, inspector_name, passed, issues_found)
VALUES (9001,
        '22222222-2222-2222-2222-222222222222'::uuid,
        'Duplicate Inspector',
        true,
        '[]'::jsonb);

-- feature (duplicate PK 6001)
INSERT INTO management.feature (feature_id, name, description)
VALUES (6001, 'Duplicate Feature', 'Test duplicate feature');

-- car_feature (duplicate PK 70001)
INSERT INTO management.car_feature (id, car_id, feature_id, installed_at, installed_by)
VALUES (70001,
        '11111111-1111-1111-1111-111111111111'::uuid,
        6001,
        Date('2025-11-10')::timestamptz,
        7001);

-- telematics_snapshot (duplicate PK 10001)
INSERT INTO telematic.telematics_snapshot (id, car_id, snapshot_ts, dtc_codes, telematics, speed_range, gps, engine_state)
VALUES (10001,
        '11111111-1111-1111-1111-111111111111'::uuid,
        Date('2025-11-10')::timestamptz,
        ARRAY ['P0001'],
        '{
            "battery": 50
        }'::jsonb,
        '[0,100]'::int4range,
        '{
            "lat": 46.0,
            "lon": 7.0
        }'::jsonb,
        'ok');

-- maintenance_ticket (duplicate PK 90001)
INSERT INTO management.maintenance_ticket (custom_name_id, service_id, reported_by, description, status)
VALUES (90001,
        '22222222-2222-2222-2222-222222222222'::uuid,
        3001,
        'Duplicate ticket',
        'open');


-- =========================================================
-- STEP 6: Multiple inserts WITHOUT PK for every table
-- =========================================================
SELECT set_commit_author('alice@example.com');

-- manufacturer
INSERT INTO management.manufacturer (name, location, founded_year, details)
VALUES ('Placeholder Wheels Ltd', ST_SetSRID(ST_Point(8.6, 47.0), 4326), 1990, '{
    "notes": "importer"
}'::jsonb),
       ('TireMasters', ST_SetSRID(ST_Point(8.55, 47.01), 4326), 1985, '{
           "notes": "premium"
       }'::jsonb);
SELECT *
FROM management.manufacturer;

-- garage
INSERT INTO management.garage (parent_garage_id, name, location, services_offered, opening_hours, rating)
VALUES (NULL, 'West Garage', ST_SetSRID(ST_Point(6.64, 46.52), 2056), ARRAY ['inspection','tyre_change'], '{
    "mon-fri": "08-18"
}'::jsonb, 4.0),
       (NULL, 'St. Gallen Garage', ST_SetSRID(ST_Point(9.37, 47.42), 2056), ARRAY ['maintenance','inspection'], '{
           "mon-fri": "07-17"
       }'::jsonb, 4.3);
SELECT *
FROM management.garage;

-- owner
INSERT INTO management.owner (legal_name, display_name, address, phone, email, customer_type, metadata)
VALUES ('Example Corp A', 'Hug', 'Industrial Str. 1', '+41 41 123 45 67', 'corp-a@example.com', 'corporate', '{}'::jsonb),
       ('Example Corp B', 'Meyer', 'Main Str. 12', '+41 44 765 43 21', 'corp-b@example.com', 'corporate', '{}'::jsonb);
SELECT *
FROM management.owner;

-- tire
INSERT INTO management.tire (production_date, tire_type, size_text, profile_mm_left, brand, pressure_psi, status, manufacturer_id)
VALUES ('2025-03-10', 'summer', '205/55R16', 7.5, 'WheelPro', 32.0, 'mounted', (SELECT id FROM management.manufacturer WHERE name = 'Placeholder Wheels Ltd')),
       ('2025-03-11', 'winter', '195/65R15', 8.0, 'TireMasters', 34.0, 'stored', (SELECT id FROM management.manufacturer WHERE name = 'TireMasters'));
SELECT *
FROM management.tire;

-- tire_set
INSERT INTO management.tire_set (car_id, front_left_tire_id, front_right_tire_id, rear_left_tire_id, rear_right_tire_id, set_status,
                                 storage_garage_id)
VALUES ((SELECT id FROM management.car WHERE vin = 'VF1TEST000001'), (SELECT id FROM management.tire WHERE brand = 'WheelPro' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'WheelPro' LIMIT 1), (SELECT id FROM management.tire WHERE brand = 'WheelPro' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'WheelPro' LIMIT 1), 'mounted',
        (SELECT garage_id FROM management.garage WHERE name = 'West Garage')),
       ((SELECT id FROM management.car WHERE vin = 'VF1TEST000002'), (SELECT id FROM management.tire WHERE brand = 'TireMasters' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'TireMasters' LIMIT 1), (SELECT id FROM management.tire WHERE brand = 'TireMasters' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'TireMasters' LIMIT 1), 'stored',
        (SELECT garage_id FROM management.garage WHERE name = 'St. Gallen Garage'));
SELECT *
FROM management.tire_set;

-- tire_set_log
INSERT INTO management.tire_set_log (front_left_tire_id, front_right_tire_id, rear_left_tire_id, rear_right_tire_id, log)
VALUES ((SELECT id FROM management.tire WHERE brand = 'WheelPro' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'WheelPro' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'WheelPro' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'WheelPro' LIMIT 1),
        'Tires rotated and balanced'),
       ((SELECT id FROM management.tire WHERE brand = 'TireMasters' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'TireMasters' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'TireMasters' LIMIT 1),
        (SELECT id FROM management.tire WHERE brand = 'TireMasters' LIMIT 1),
        'Stored for summer season');
SELECT *
FROM management.tire_set_log;

-- mechanic
INSERT INTO management.mechanic (garage_id, full_name, certifications, hire_date, skill_level, active)
VALUES ((SELECT garage_id FROM management.garage WHERE name = 'West Garage'), 'Fred Nurk', ARRAY ['ASE B1'], '2022-01-01', 'junior', true),
       ((SELECT garage_id FROM management.garage WHERE name = 'St. Gallen Garage'), 'Erika Mustermann', ARRAY ['ASE A2'], '2021-06-15', 'mid', true);
SELECT *
FROM management.mechanic;

-- =========================================================
-- STEP 7: Updates every table
-- =========================================================
SELECT set_commit_author('bob@example.com');

-- Update manufacturer
UPDATE management.manufacturer
SET founded_year = founded_year + 1
WHERE name = 'Example Tyres Ltd';
SELECT *
FROM management.manufacturer;

-- Update garage
UPDATE management.garage
SET rating = 4.8
WHERE name = 'Central Garage';
SELECT *
FROM management.garage;

-- Update owner
UPDATE management.owner
SET phone = '+41 44 999 99 99'
WHERE legal_name = 'Max Muster';
SELECT *
FROM management.owner;

-- Update tire
UPDATE management.tire
SET profile_mm_left = profile_mm_left - 0.5
WHERE brand = 'GoodTyre';
SELECT *
FROM management.tire;

-- Update car
UPDATE management.car
SET mileage_km = mileage_km + 150
WHERE vin = 'WDB1234561A654321';
SELECT *
FROM management.car;

-- Update tire_set
UPDATE management.tire_set
SET set_status='disposed'
WHERE front_left_tire_id = 2001;
SELECT *
FROM management.tire_set;

-- Update mechanic
UPDATE management.mechanic
SET skill_level='senior'
WHERE full_name = 'John Doe';
SELECT *
FROM management.mechanic;

-- Update garage_mechanic
UPDATE management.garage_mechanic
SET role='lead'
WHERE garage_id = 1;
SELECT *
FROM management.garage_mechanic;

-- Update service_record
UPDATE management.service_record
SET cost=management.service_record.cost * 1.1;
SELECT *
FROM management.service_record;

-- Update inspection
UPDATE management.inspection
SET passed= false
WHERE id = 9001;
SELECT *
FROM management.inspection;

-- Update feature
UPDATE management.feature
SET description='Updated feature description'
WHERE feature_id = 6001;
SELECT *
FROM management.feature;

-- Update management.car_feature
UPDATE management.car_feature
SET notes='Updated notes'
WHERE id = 70001;
SELECT *
FROM management.car_feature;

-- Update telematics_snapshot
UPDATE telematic.telematics_snapshot
SET engine_state='error'
WHERE id = 10001;
SELECT *
FROM telematic.telematics_snapshot;

-- Update car_owner_history
UPDATE management.car_owner_history
SET notes='car looks good';
SELECT *
FROM management.car_owner_history;

-- =========================================================
-- STEP 8: Check all backing table changes
-- =========================================================
SELECT *
FROM _backing.management__manufacturer;
SELECT *
FROM _backing.management__garage;
SELECT *
FROM _backing.management__owner;
SELECT *
FROM _backing.management__tire;
SELECT *
FROM _backing.management__car;
SELECT *
FROM _backing.management__tire_set;
SELECT *
FROM _backing.management__tire_set_log;
SELECT *
FROM _backing.management__mechanic;
SELECT *
FROM _backing.management__garage_mechanic;
SELECT *
FROM _backing.management__service_record;
SELECT *
FROM _backing.management__inspection;
SELECT *
FROM _backing.management__feature;
SELECT *
FROM _backing.management__car_feature;
SELECT *
FROM _backing.telematic__telematics_snapshot;
SELECT *
FROM _backing.management__maintenance_ticket;
SELECT *
FROM _backing.management__car_owner_history;

-- =========================================================
-- STEP 9: Check general functions still work
-- =========================================================

-- NOT NULL error
DO
$$
    BEGIN
        INSERT INTO management.car_owner_history (car_id, ownership_period)
        VALUES ((SELECT id FROM management.car WHERE vin = 'WDB1234561A654321' LIMIT 1),
                '[2020-01-01,2021-01-01]'::tsrange);
    EXCEPTION
        WHEN not_null_violation THEN
            RAISE NOTICE 'NOT NULL violation caught as expected';
    END;
$$;

-- Enum type miss match
UPDATE management.tire_set
SET set_status='bla'
WHERE front_left_tire_id = 2001;

-- Check if joins work correctly
SELECT *
FROM management.car
         INNER JOIN management.car_owner_history coh on car.id = coh.car_id
         INNER JOIN management.owner o on o.id = coh.owner_id;

-- Check if some postgis functions still work
SELECT ST_AsGeoJSON(location)
FROM management.garage;
SELECT ST_AsGeoJSON(location)
FROM management.manufacturer;

-- Check if unique constraint works
INSERT INTO management.owner (legal_name, display_name, address, phone, email, customer_type, metadata)
VALUES ('Max Muster',
        'M. Muster',
        'Example Street 2, 1000 Sampletown',
        '+41 44 000 00 02',
        'max.muster@example.com',
        'private',
        '{
            "notes": "Not VIP customer"
        }'::jsonb);

-- =========================================================
-- STEP 10: Delete tests (failing ones at the end)
-- =========================================================
SELECT set_commit_author('bob@example.com');

-- Delete from maintenance_ticket (no dependencies)
DELETE
FROM management.maintenance_ticket
WHERE custom_name_id = 90001;
SELECT *
FROM management.maintenance_ticket;

-- Delete from inspection (no dependencies)
DELETE
FROM management.inspection
WHERE id = 9001;
SELECT *
FROM management.inspection;

-- Delete from car_feature (no dependencies)
DELETE
FROM management.car_feature
WHERE id = 70001;
SELECT *
FROM management.car_feature;

-- Delete from feature (safe delete - no remaining references)
DELETE
FROM management.feature
WHERE feature_id = 6001;
SELECT *
FROM management.feature;

-- Delete from telematics_snapshot (no dependencies)
DELETE
FROM telematic.telematics_snapshot
WHERE id = 10001;
SELECT *
FROM telematic.telematics_snapshot;

-- Delete from car_owner_history (no dependencies)
DELETE
FROM management.car_owner_history
WHERE id = 1;
SELECT *
FROM management.car_owner_history;

-- Delete from tire_set_log (no dependencies)
DELETE
FROM management.tire_set_log
WHERE front_left_tire_id = 2001;
SELECT *
FROM management.tire_set_log;

-- Delete from garage_mechanic (no dependencies blocking this)
DELETE
FROM management.garage_mechanic
WHERE garage_id = 5001
  AND mechanic_id = 7001;
SELECT *
FROM management.garage_mechanic;

-- Delete from service_record (cascades to inspection)
DELETE
FROM management.service_record
WHERE service_id = '22222222-2222-2222-2222-222222222222'::uuid;
SELECT *
FROM management.service_record;

-- Delete from mechanic (SET NULL on service_record, car_feature, garage_mechanic CASCADE)
DELETE
FROM management.mechanic
WHERE mechanic_id = 7001;
SELECT *
FROM management.mechanic;

-- Delete from garage (SET NULL on mechanic, service_record, tire_set, self-reference)
DELETE
FROM management.garage
WHERE garage_id = 5001;
SELECT *
FROM management.garage;

-- Delete from owner (SET NULL on maintenance_ticket, CASCADE on car_owner_history)
DELETE
FROM management.owner
WHERE id = 3001;
SELECT *
FROM management.owner;

-- Delete from car (CASCADE on car_owner_history, car_feature, telematics_snapshot, service_record, SET NULL on tire_set)
DELETE
FROM management.car
WHERE id = '11111111-1111-1111-1111-111111111111'::uuid;
SELECT *
FROM management.car;

-- Delete from manufacturer (SET NULL on car and tire)
DELETE
FROM management.manufacturer
WHERE id = 1001;
SELECT *
FROM management.manufacturer;

-- =========================================================
-- Failing deletes (RESTRICT constraints) - should throw errors
-- =========================================================

-- Delete from tire_set (has tire_set_log references with composite FK) - should fail RESTRICT
DELETE
FROM management.tire_set
WHERE car_id = '00000000-0000-0000-0000-000000000001'::uuid;
SELECT *
FROM management.tire_set;

-- Delete from tire (referenced by tire_set with ON DELETE RESTRICT) - should fail
DELETE
FROM management.tire
WHERE id = 2001;
SELECT *
FROM management.tire;

-- =========================================================
-- STEP 11: Check tree, commit and commit_tree
-- =========================================================

SELECT 'commit_hash_' || RANK() OVER (ORDER BY commit.created_at) AS hash, parent_commit.rank AS parent_hash, commit.author, commit.message
FROM _vie.commit AS commit
         LEFT JOIN (SELECT hash, 'commit_hash_' || RANK() OVER (ORDER BY created_at) AS rank
                    FROM _vie.commit) AS parent_commit ON parent_commit.hash = commit.parent_hash
ORDER BY created_at;

SELECT tree.*
FROM _vie.tree
    INNER JOIN _vie.commit_tree ON commit_tree.tree_hash = tree.hash
         LEFT JOIN (SELECT hash, RANK() OVER (ORDER BY created_at) AS rank
                    FROM _vie.commit) AS commit ON commit.hash = commit_tree.commit_hash
ORDER BY commit.rank, tree.hash;

SELECT  'commit_hash_' || commit.rank, commit_tree.tree_hash
FROM _vie.commit_tree
         LEFT JOIN (SELECT hash, RANK() OVER (ORDER BY created_at) AS rank
                    FROM _vie.commit) AS commit ON commit.hash = commit_tree.commit_hash
ORDER BY commit.rank, commit_tree.tree_hash;
