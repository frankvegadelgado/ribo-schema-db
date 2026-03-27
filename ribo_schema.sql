-- =============================================================================
-- RIBO — Relational Database Schema
-- Compatible with Odoo res.partner conventions where noted.
-- =============================================================================


-- =============================================================================
-- GEOGRAPHIC TABLES
-- Following the structure from kidino/SQL-Countries-States-Provinces
-- =============================================================================

-- Countries catalogue. Mirrors Odoo's res.country.
-- Stores ISO 3166-1 alpha-2 codes and full country names.
CREATE TABLE IF NOT EXISTS countries (
    country_id   INT UNSIGNED    NOT NULL,
    ccode        CHAR(2)         NOT NULL,          -- ISO 3166-1 alpha-2 (e.g. 'AR', 'US')
    name         VARCHAR(255)    NOT NULL,
    phone_code   VARCHAR(10)     DEFAULT NULL,      -- International dial prefix (e.g. '+54')
    PRIMARY KEY (country_id),
    UNIQUE KEY uq_countries_ccode (ccode)
);

-- States / provinces within a country. Mirrors Odoo's res.country.state.
-- Each record belongs to exactly one country.
CREATE TABLE IF NOT EXISTS states_provinces (
    state_id     INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    country_id   INT UNSIGNED    NOT NULL,
    name         VARCHAR(255)    NOT NULL,
    code         VARCHAR(10)     DEFAULT NULL,      -- ISO 3166-2 subdivision code (e.g. 'BA', 'CA')
    PRIMARY KEY (state_id),
    KEY idx_states_country (country_id),
    CONSTRAINT fk_states_country FOREIGN KEY (country_id)
        REFERENCES countries (country_id)
        ON UPDATE CASCADE ON DELETE RESTRICT
);

-- Cities / municipalities within a state or province.
-- Extends the kidino model with an explicit city level.
CREATE TABLE IF NOT EXISTS cities (
    city_id      INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    state_id     INT UNSIGNED    NOT NULL,
    name         VARCHAR(255)    NOT NULL,
    zip_code     VARCHAR(20)     DEFAULT NULL,      -- Postal / ZIP code for the city
    PRIMARY KEY (city_id),
    KEY idx_cities_state (state_id),
    CONSTRAINT fk_cities_state FOREIGN KEY (state_id)
        REFERENCES states_provinces (state_id)
        ON UPDATE CASCADE ON DELETE RESTRICT
);


-- =============================================================================
-- KYC (KNOW YOUR CUSTOMER)
-- =============================================================================

-- Catalogue of possible KYC review statuses for a client.
-- Kept as a separate table so statuses can be extended without schema changes.
CREATE TABLE IF NOT EXISTS kyc_statuses (
    kyc_status_id   TINYINT UNSIGNED    NOT NULL AUTO_INCREMENT,
    code            VARCHAR(30)         NOT NULL,   -- Machine-readable key (e.g. 'in_progress')
    label           VARCHAR(60)         NOT NULL,   -- Human-readable label (e.g. 'In Progress')
    description     TEXT                DEFAULT NULL,
    is_terminal     BOOLEAN             NOT NULL DEFAULT FALSE, -- TRUE for final states (approved/rejected)
    PRIMARY KEY (kyc_status_id),
    UNIQUE KEY uq_kyc_code (code)
);

-- Seed the standard KYC statuses.
INSERT INTO kyc_statuses (code, label, is_terminal) VALUES
    ('pending',      'Pending',        FALSE),
    ('in_progress',  'In Progress',    FALSE),
    ('under_review', 'Under Review',   FALSE),
    ('approved',     'Approved',       TRUE),
    ('rejected',     'Rejected',       TRUE),
    ('expired',      'Expired',        TRUE),
    ('suspended',    'Suspended',      FALSE);


-- =============================================================================
-- CLIENTS
-- Represents natural or legal persons that operate as clients in RIBO.
-- Field naming aligned with Odoo's res.partner model for easy integration.
-- =============================================================================

-- Document types accepted as identity proof (DNI, passport, RUC, CUIT, etc.).
CREATE TABLE IF NOT EXISTS document_types (
    document_type_id   TINYINT UNSIGNED    NOT NULL AUTO_INCREMENT,
    code               VARCHAR(20)         NOT NULL,   -- e.g. 'DNI', 'PASSPORT', 'RUC'
    label              VARCHAR(60)         NOT NULL,
    PRIMARY KEY (document_type_id),
    UNIQUE KEY uq_doc_type_code (code)
);

INSERT INTO document_types (code, label) VALUES
    ('DNI',       'Documento Nacional de Identidad'),
    ('PASSPORT',  'Passport'),
    ('CUIT',      'CUIT / CUIL'),
    ('RUC',       'Registro Único de Contribuyentes'),
    ('NIT',       'Número de Identificación Tributaria'),
    ('CE',        'Cédula de Extranjería'),
    ('OTHER',     'Other');

-- Main client table. Supports both individual (person) and company clients.
-- Mirrors Odoo's res.partner with KYC lifecycle tracking.
CREATE TABLE IF NOT EXISTS clients (
    client_id           INT UNSIGNED        NOT NULL AUTO_INCREMENT,

    -- Identity fields
    document_type_id    TINYINT UNSIGNED    NOT NULL,
    dni                 VARCHAR(30)         NOT NULL,   -- Identity document number (DNI / passport / RUC …)
    first_name          VARCHAR(100)        DEFAULT NULL, -- NULL for legal entities
    last_name           VARCHAR(100)        DEFAULT NULL, -- NULL for legal entities
    company_name        VARCHAR(255)        DEFAULT NULL, -- NULL for natural persons
    is_company          BOOLEAN             NOT NULL DEFAULT FALSE,
    vat                 VARCHAR(30)         DEFAULT NULL, -- Tax ID / VAT number (Odoo: partner.vat)
    gender              ENUM('M','F','X')   DEFAULT NULL,
    birth_date          DATE                DEFAULT NULL,
    nationality_id      INT UNSIGNED        DEFAULT NULL, -- FK → countries

    -- Contact fields (aligned with Odoo res.partner)
    email               VARCHAR(254)        DEFAULT NULL,
    phone               VARCHAR(30)         DEFAULT NULL, -- Landline (Odoo: partner.phone)
    mobile              VARCHAR(30)         DEFAULT NULL, -- Mobile (Odoo: partner.mobile)
    website             VARCHAR(255)        DEFAULT NULL,

    -- Address fields (Odoo: street, street2, city, state_id, country_id, zip)
    street              VARCHAR(255)        DEFAULT NULL,
    street2             VARCHAR(255)        DEFAULT NULL,
    city_id             INT UNSIGNED        DEFAULT NULL, -- FK → cities
    state_id            INT UNSIGNED        DEFAULT NULL, -- FK → states_provinces
    country_id          INT UNSIGNED        DEFAULT NULL, -- FK → countries
    zip_code            VARCHAR(20)         DEFAULT NULL,

    -- KYC lifecycle
    kyc_status_id       TINYINT UNSIGNED    NOT NULL DEFAULT 1, -- starts as 'pending'
    kyc_reviewed_at     DATETIME            DEFAULT NULL,
    kyc_reviewed_by     INT UNSIGNED        DEFAULT NULL, -- FK → users (back-office agent)
    kyc_notes           TEXT                DEFAULT NULL,

    -- Odoo integration helpers
    odoo_partner_id     INT UNSIGNED        DEFAULT NULL, -- External Odoo res.partner ID
    ref                 VARCHAR(50)         DEFAULT NULL, -- Internal client reference / Odoo ref

    -- Audit
    is_active           BOOLEAN             NOT NULL DEFAULT TRUE,
    created_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                                                        ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (client_id),
    UNIQUE KEY uq_clients_dni (document_type_id, dni),
    UNIQUE KEY uq_clients_odoo (odoo_partner_id),
    KEY idx_clients_kyc    (kyc_status_id),
    KEY idx_clients_country (country_id),

    CONSTRAINT fk_clients_doc_type   FOREIGN KEY (document_type_id)
        REFERENCES document_types (document_type_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_clients_kyc_status FOREIGN KEY (kyc_status_id)
        REFERENCES kyc_statuses (kyc_status_id)      ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_clients_nationality FOREIGN KEY (nationality_id)
        REFERENCES countries (country_id)             ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_clients_city       FOREIGN KEY (city_id)
        REFERENCES cities (city_id)                   ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_clients_state      FOREIGN KEY (state_id)
        REFERENCES states_provinces (state_id)        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_clients_country    FOREIGN KEY (country_id)
        REFERENCES countries (country_id)             ON UPDATE CASCADE ON DELETE SET NULL
);

-- Audit log of every KYC status transition for a client.
-- Preserves the full history of approvals, rejections and reactivations.
CREATE TABLE IF NOT EXISTS client_kyc_history (
    history_id          INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    client_id           INT UNSIGNED        NOT NULL,
    from_status_id      TINYINT UNSIGNED    DEFAULT NULL,  -- NULL on first assignment
    to_status_id        TINYINT UNSIGNED    NOT NULL,
    changed_by          INT UNSIGNED        DEFAULT NULL,  -- FK → users
    notes               TEXT                DEFAULT NULL,
    changed_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (history_id),
    KEY idx_kyc_history_client (client_id),
    CONSTRAINT fk_kyc_hist_client  FOREIGN KEY (client_id)
        REFERENCES clients (client_id)       ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_kyc_hist_from    FOREIGN KEY (from_status_id)
        REFERENCES kyc_statuses (kyc_status_id) ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_kyc_hist_to      FOREIGN KEY (to_status_id)
        REFERENCES kyc_statuses (kyc_status_id) ON UPDATE CASCADE ON DELETE RESTRICT
);


-- =============================================================================
-- USERS
-- Two personas: public (anonymous / token-based) and private (credential-based).
-- =============================================================================

-- User roles catalogue. Defines permission levels inside RIBO.
CREATE TABLE IF NOT EXISTS roles (
    role_id     TINYINT UNSIGNED    NOT NULL AUTO_INCREMENT,
    code        VARCHAR(30)         NOT NULL,   -- e.g. 'admin', 'agent', 'client', 'public'
    label       VARCHAR(60)         NOT NULL,
    description TEXT                DEFAULT NULL,
    PRIMARY KEY (role_id),
    UNIQUE KEY uq_roles_code (code)
);

INSERT INTO roles (code, label, description) VALUES
    ('admin',   'Administrator', 'Full system access'),
    ('agent',   'Agent',         'Back-office KYC and client management'),
    ('client',  'Client',        'Authenticated client portal access'),
    ('public',  'Public',        'Anonymous or token-only access; no credentials');

-- Platform users table.
-- Private users (is_public = FALSE) hold a hashed password and a role.
-- Public users (is_public = TRUE) are identified by a token only (e.g. API consumers, guests).
CREATE TABLE IF NOT EXISTS users (
    user_id         INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    role_id         TINYINT UNSIGNED    NOT NULL,

    -- Identification
    username        VARCHAR(60)         DEFAULT NULL,   -- NULL for public/guest users
    email           VARCHAR(254)        DEFAULT NULL,

    -- Credentials — only for private users (is_public = FALSE)
    password_hash   VARCHAR(255)        DEFAULT NULL,   -- bcrypt / argon2 hash; NULL for public users
    password_salt   VARCHAR(255)        DEFAULT NULL,   -- Explicit salt if not embedded in hash

    -- Token-based access — primary mechanism for public users, optional 2FA for private
    access_token        VARCHAR(512)    DEFAULT NULL,   -- JWT or opaque token
    refresh_token       VARCHAR(512)    DEFAULT NULL,
    token_expires_at    DATETIME        DEFAULT NULL,

    -- Two-factor authentication (private users)
    totp_secret         VARCHAR(64)     DEFAULT NULL,   -- TOTP secret (2FA)
    is_2fa_enabled      BOOLEAN         NOT NULL DEFAULT FALSE,

    -- Public / private flag
    is_public           BOOLEAN         NOT NULL DEFAULT FALSE,
    -- TRUE  → public/guest user; no login required, identified by token
    -- FALSE → private user with username + password credentials

    -- Optional link to a client record (client-portal users)
    client_id           INT UNSIGNED    DEFAULT NULL,   -- FK → clients

    -- Profile
    first_name          VARCHAR(100)    DEFAULT NULL,
    last_name           VARCHAR(100)    DEFAULT NULL,

    -- Audit & status
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    last_login_at       DATETIME        DEFAULT NULL,
    last_login_ip       VARCHAR(45)     DEFAULT NULL,   -- Supports IPv4 and IPv6
    failed_login_count  TINYINT UNSIGNED NOT NULL DEFAULT 0,
    locked_until        DATETIME        DEFAULT NULL,   -- Brute-force lockout expiry
    created_at          DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
                                                    ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (user_id),
    UNIQUE KEY uq_users_username (username),
    UNIQUE KEY uq_users_email    (email),
    KEY idx_users_role   (role_id),
    KEY idx_users_client (client_id),

    CONSTRAINT fk_users_role   FOREIGN KEY (role_id)
        REFERENCES roles (role_id)     ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_users_client FOREIGN KEY (client_id)
        REFERENCES clients (client_id) ON UPDATE CASCADE ON DELETE SET NULL
);

-- Now that users exists, add the deferred FKs on clients that reference users.
ALTER TABLE clients
    ADD CONSTRAINT fk_clients_reviewed_by FOREIGN KEY (kyc_reviewed_by)
        REFERENCES users (user_id) ON UPDATE CASCADE ON DELETE SET NULL;

ALTER TABLE client_kyc_history
    ADD CONSTRAINT fk_kyc_hist_user FOREIGN KEY (changed_by)
        REFERENCES users (user_id) ON UPDATE CASCADE ON DELETE SET NULL;

-- =============================================================================
-- CREDITS
-- Models the credit products offered on ribo.pe and web-submitted requests.
-- =============================================================================

-- Nomenclator of credit types available on the RIBO platform.
-- Each row matches one product shown on ribo.pe/peru-productos.
CREATE TABLE IF NOT EXISTS credit_types (
    credit_type_id      TINYINT UNSIGNED    NOT NULL AUTO_INCREMENT,
    code                VARCHAR(30)         NOT NULL,   -- Machine key  e.g. 'personal', 'vehiculo'
    label               VARCHAR(80)         NOT NULL,   -- Display name e.g. 'Crédito Personal'
    description         TEXT                DEFAULT NULL,

    -- Amount constraints (in the product's native currency)
    min_amount          DECIMAL(12,2)       DEFAULT NULL,  -- Minimum requestable amount
    max_amount          DECIMAL(12,2)       DEFAULT NULL,  -- Maximum requestable amount (NULL = no cap)
    currency            CHAR(3)             NOT NULL DEFAULT 'PEN',  -- ISO 4217

    -- Installment (cuota) constraints
    min_installments    TINYINT UNSIGNED    DEFAULT NULL,  -- Minimum number of monthly payments
    max_installments    TINYINT UNSIGNED    DEFAULT NULL,  -- Maximum number of monthly payments

    -- Lifecycle
    is_active           BOOLEAN             NOT NULL DEFAULT TRUE,
    sort_order          TINYINT UNSIGNED    NOT NULL DEFAULT 0,  -- Display ordering on the website
    created_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                                                        ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (credit_type_id),
    UNIQUE KEY uq_credit_type_code (code)
);

-- Seed with the six products published on ribo.pe
-- Amounts and installment ranges sourced from ribo.pe and ribo.pe/peru-productos.
INSERT INTO credit_types
    (code, label, description, min_amount, max_amount, currency, min_installments, max_installments, sort_order)
VALUES
    ('personal',
     'Crédito Personal',
     'Financiamiento rápido para imprevistos, compras u oportunidades personales.',
     400.00,   NULL,      'PEN', 1, 12, 1),

    ('vehiculo',
     'Crédito para Vehículos',
     'Financiamiento de carros nuevos y usados, para uso personal o laboral.',
     16000.00, NULL,      'PEN', 1, 48, 2),

    ('moto',
     'Crédito para Motos',
     'Financiamiento ágil para adquisición de motocicletas.',
     570.00,   NULL,      'PEN', 1,  4, 3),

    ('soat',
     'Crédito para SOAT',
     'Financiamiento del Seguro Obligatorio de Accidentes de Tránsito.',
     5000.00,  NULL,      'PEN', 1, 15, 4),

    ('pyme',
     'Crédito para PYMES',
     'Préstamos flexibles para impulsar pequeñas y medianas empresas.',
     NULL,     NULL,      'PEN', 1, 15, 5),

    ('remesa',
     'Remesa Internacional',
     'Envío de remesas internacionales mediante tarjeta Creskard.',
     NULL,     NULL,      'USD', NULL, NULL, 6);


-- Catalogue of possible statuses for a credit request.
CREATE TABLE IF NOT EXISTS credit_request_statuses (
    status_id   TINYINT UNSIGNED    NOT NULL AUTO_INCREMENT,
    code        VARCHAR(30)         NOT NULL,   -- e.g. 'draft', 'submitted', 'approved'
    label       VARCHAR(60)         NOT NULL,
    description TEXT                DEFAULT NULL,
    is_terminal BOOLEAN             NOT NULL DEFAULT FALSE, -- TRUE for final states
    PRIMARY KEY (status_id),
    UNIQUE KEY uq_credit_req_status_code (code)
);

INSERT INTO credit_request_statuses (code, label, description, is_terminal) VALUES
    ('draft',       'Borrador',          'Solicitud iniciada pero no enviada',              FALSE),
    ('submitted',   'Enviada',           'Solicitud recibida por RIBO vía web',             FALSE),
    ('in_review',   'En Revisión',       'Equipo RIBO está evaluando la solicitud',         FALSE),
    ('approved',    'Aprobada',          'Crédito aprobado; pendiente de desembolso',       TRUE),
    ('disbursed',   'Desembolsado',      'Fondos transferidos a la cuenta del cliente',     TRUE),
    ('rejected',    'Rechazada',         'Solicitud no cumple los criterios de aprobación', TRUE),
    ('cancelled',   'Cancelada',         'Cancelada por el cliente o por expiración',       TRUE),
    ('expired',     'Expirada',          'Sin respuesta del solicitante en el plazo dado',  TRUE);


-- Web credit requests submitted through ribo.pe.
-- Captures every loan / remittance application originating from the website,
-- whether the submitter is already a registered client or a new prospect.
CREATE TABLE IF NOT EXISTS credit_requests (
    credit_request_id   INT UNSIGNED        NOT NULL AUTO_INCREMENT,

    -- What product was requested
    credit_type_id      TINYINT UNSIGNED    NOT NULL,  -- FK → credit_types

    -- Who made the request
    -- client_id is NULL when the prospect has not been KYC-registered yet.
    client_id           INT UNSIGNED        DEFAULT NULL,  -- FK → clients

    -- Prospect contact info captured from the web form
    -- (used when client_id is NULL; copied to client record once KYC completes)
    prospect_first_name VARCHAR(100)        DEFAULT NULL,
    prospect_last_name  VARCHAR(100)        DEFAULT NULL,
    prospect_email      VARCHAR(254)        DEFAULT NULL,
    prospect_phone      VARCHAR(30)         DEFAULT NULL,
    prospect_dni        VARCHAR(30)         DEFAULT NULL,  -- Document number entered on form

    -- Financial terms requested via the simulator / form
    requested_amount    DECIMAL(12,2)       NOT NULL,
    currency            CHAR(3)             NOT NULL DEFAULT 'PEN',  -- ISO 4217
    installments        TINYINT UNSIGNED    DEFAULT NULL,  -- Número de cuotas requested
    monthly_payment     DECIMAL(12,2)       DEFAULT NULL,  -- Estimated cuota shown on the simulator

    -- Approved terms (filled in by an agent after approval)
    approved_amount     DECIMAL(12,2)       DEFAULT NULL,
    approved_rate_pct   DECIMAL(6,4)        DEFAULT NULL,  -- Annual effective rate (TEA %)
    approved_installments TINYINT UNSIGNED  DEFAULT NULL,
    approved_at         DATETIME            DEFAULT NULL,
    approved_by         INT UNSIGNED        DEFAULT NULL,  -- FK → users (agent)
    disbursed_at        DATETIME            DEFAULT NULL,

    -- Request lifecycle
    status_id           TINYINT UNSIGNED    NOT NULL DEFAULT 1,  -- starts as 'draft'
    source_channel      VARCHAR(30)         NOT NULL DEFAULT 'web',
    -- e.g. 'web', 'typeform', 'whatsapp', 'referral'
    utm_source          VARCHAR(100)        DEFAULT NULL,  -- Marketing attribution
    utm_medium          VARCHAR(100)        DEFAULT NULL,
    utm_campaign        VARCHAR(100)        DEFAULT NULL,

    -- Free-text fields
    notes               TEXT                DEFAULT NULL,  -- Internal agent notes
    rejection_reason    TEXT                DEFAULT NULL,  -- Populated on rejection

    -- Audit
    submitted_at        DATETIME            DEFAULT NULL,  -- When the web form was sent
    created_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                                                        ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (credit_request_id),
    KEY idx_cr_client      (client_id),
    KEY idx_cr_type        (credit_type_id),
    KEY idx_cr_status      (status_id),
    KEY idx_cr_submitted   (submitted_at),

    CONSTRAINT fk_cr_credit_type FOREIGN KEY (credit_type_id)
        REFERENCES credit_types (credit_type_id)            ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_cr_client      FOREIGN KEY (client_id)
        REFERENCES clients (client_id)                      ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_cr_status      FOREIGN KEY (status_id)
        REFERENCES credit_request_statuses (status_id)      ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_cr_approved_by FOREIGN KEY (approved_by)
        REFERENCES users (user_id)                          ON UPDATE CASCADE ON DELETE SET NULL
);

-- Full status-transition audit trail for every credit request.
CREATE TABLE IF NOT EXISTS credit_request_history (
    history_id          INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    credit_request_id   INT UNSIGNED        NOT NULL,
    from_status_id      TINYINT UNSIGNED    DEFAULT NULL,  -- NULL on first assignment
    to_status_id        TINYINT UNSIGNED    NOT NULL,
    changed_by          INT UNSIGNED        DEFAULT NULL,  -- FK → users; NULL = system/webhook
    notes               TEXT                DEFAULT NULL,
    changed_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (history_id),
    KEY idx_crh_request (credit_request_id),
    CONSTRAINT fk_crh_request     FOREIGN KEY (credit_request_id)
        REFERENCES credit_requests (credit_request_id)          ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_crh_from        FOREIGN KEY (from_status_id)
        REFERENCES credit_request_statuses (status_id)          ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_crh_to          FOREIGN KEY (to_status_id)
        REFERENCES credit_request_statuses (status_id)          ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_crh_user        FOREIGN KEY (changed_by)
        REFERENCES users (user_id)                              ON UPDATE CASCADE ON DELETE SET NULL
);


-- =============================================================================
-- SESSION MANAGEMENT
-- =============================================================================

-- Refresh-token rotation log. Invalidates old tokens and detects token reuse attacks.
CREATE TABLE IF NOT EXISTS user_sessions (
    session_id          INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    user_id             INT UNSIGNED    NOT NULL,
    refresh_token_hash  VARCHAR(255)    NOT NULL,   -- Hashed refresh token (never store plain)
    issued_at           DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at          DATETIME        NOT NULL,
    revoked_at          DATETIME        DEFAULT NULL, -- NULL = still valid
    ip_address          VARCHAR(45)     DEFAULT NULL,
    user_agent          VARCHAR(512)    DEFAULT NULL,
    PRIMARY KEY (session_id),
    KEY idx_sessions_user (user_id),
    CONSTRAINT fk_sessions_user FOREIGN KEY (user_id)
        REFERENCES users (user_id) ON UPDATE CASCADE ON DELETE CASCADE
);
