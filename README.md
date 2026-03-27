# RIBO — Database Schema Reference

This document describes the full relational schema for the **RIBO** platform — a Peruvian fintech that offers personal loans, vehicle financing, SOAT insurance financing, SME loans, motorcycle loans, and international remittances through its website [ribo.pe](https://ribo.pe).

The schema is written in MySQL and follows naming conventions compatible with **Odoo's `res.partner`** model to simplify ERP integration. Every section below explains the business purpose, the tables involved, and what each field means.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Module: Geography](#2-module-geography)
   - [`countries`](#countries)
   - [`states_provinces`](#states_provinces)
   - [`cities`](#cities)
3. [Module: KYC (Know Your Customer)](#3-module-kyc-know-your-customer)
   - [`kyc_statuses`](#kyc_statuses)
4. [Module: Clients](#4-module-clients)
   - [`document_types`](#document_types)
   - [`client_tiers`](#client_tiers)
   - [`clients`](#clients)
   - [`client_kyc_history`](#client_kyc_history)
5. [Module: Users & Access Control](#5-module-users--access-control)
   - [`roles`](#roles)
   - [`users`](#users)
   - [`user_sessions`](#user_sessions)
6. [Module: Credits](#6-module-credits)
   - [`credit_types`](#credit_types)
   - [`credit_request_statuses`](#credit_request_statuses)
   - [`credit_requests`](#credit_requests)
   - [`credit_request_history`](#credit_request_history)
7. [Key Business Flows](#7-key-business-flows)
8. [Design Principles](#8-design-principles)

---

## 1. Architecture Overview

The schema is organized into four functional modules that map directly to business domains:

```
┌─────────────────────────────────────────────────────────────────┐
│  GEOGRAPHY                                                      │
│  countries ──► states_provinces ──► cities                     │
└───────────────────────────┬─────────────────────────────────────┘
                            │ (address FKs)
┌───────────────────────────▼─────────────────────────────────────┐
│  CLIENTS                                                        │
│  document_types ──► clients ◄── kyc_statuses                   │
│  client_tiers   ──►    │                                        │
│                        └──► client_kyc_history                  │
└───────────────────────────┬─────────────────────────────────────┘
                            │ (client_id FK)
┌───────────────────────────▼─────────────────────────────────────┐
│  CREDITS                                                        │
│  credit_types ──► credit_requests ◄── credit_request_statuses  │
│                        │                                        │
│                        └──► credit_request_history              │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  USERS & ACCESS CONTROL                                         │
│  roles ──► users ──► user_sessions                             │
│               │                                                 │
│               └──► clients (optional link for portal users)    │
└─────────────────────────────────────────────────────────────────┘
```

**Separation of concerns:**
- A **client** is a real-world person or company going through KYC.
- A **user** is a system account (back-office agent, admin, or client-portal login).
- A **credit_request** is a web form submission — it can exist before a client record does (prospect flow).
- **Geography tables** are shared reference data, never deleted, only extended.

---

## 2. Module: Geography

These three tables form a cascading geographic hierarchy used for address normalization across the entire platform. The structure follows the [kidino/SQL-Countries-States-Provinces](https://github.com/kidino/SQL-Countries-States-Provinces) convention and mirrors Odoo's `res.country` and `res.country.state` models.

### `countries`

A catalogue of all countries, populated once from ISO data. Rows are never deleted because they are referenced by clients and users.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `country_id` | INT UNSIGNED | No | Primary key. Matches the ISO numeric country code (e.g. `604` for Peru). |
| `ccode` | CHAR(2) | No | ISO 3166-1 alpha-2 country code (e.g. `PE`, `US`, `AR`). Unique across the table. Used for display and API payloads. |
| `name` | VARCHAR(255) | No | Full official country name in English (e.g. `Peru`). |
| `phone_code` | VARCHAR(10) | Yes | International dialing prefix including the `+` sign (e.g. `+51` for Peru). Used to validate and format phone numbers at the application layer. |

**Constraints:** `ccode` has a unique index (`uq_countries_ccode`). No automatic deletion is allowed on referenced rows (`ON DELETE RESTRICT` on all child FKs).

---

### `states_provinces`

States, departments, or provinces within a country. Each row belongs to exactly one country.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `state_id` | INT UNSIGNED | No | Auto-incremented primary key. |
| `country_id` | INT UNSIGNED | No | FK → `countries`. The country this subdivision belongs to. Cascades on update, restricts on delete. |
| `name` | VARCHAR(255) | No | Full name of the state or department (e.g. `Lima`, `Cusco`). |
| `code` | VARCHAR(10) | Yes | ISO 3166-2 subdivision code (e.g. `PE-LIM` for Lima, Peru). Optional — some countries do not publish formal codes. |

---

### `cities`

Cities or municipalities within a state. This level is not present in the base kidino model; RIBO adds it to allow precise address capture and postal-code assignment.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `city_id` | INT UNSIGNED | No | Auto-incremented primary key. |
| `state_id` | INT UNSIGNED | No | FK → `states_provinces`. The state this city belongs to. Cascades on update, restricts on delete. |
| `name` | VARCHAR(255) | No | City or municipality name (e.g. `Miraflores`, `San Isidro`). |
| `zip_code` | VARCHAR(20) | Yes | Primary postal code for the city. Individual clients may override this with their specific `zip_code` on the `clients` table. |

---

## 3. Module: KYC (Know Your Customer)

KYC is the regulatory process RIBO uses to verify client identity before granting credit. Every client carries a KYC status that agents update as documents are reviewed. The design uses a separate **nomenclator table** so the list of statuses can be changed without touching application code.

### `kyc_statuses`

Catalogue of all possible KYC review states. Seeded at installation with seven standard statuses.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `kyc_status_id` | TINYINT UNSIGNED | No | Auto-incremented primary key. |
| `code` | VARCHAR(30) | No | Machine-readable identifier used in application logic (e.g. `in_progress`, `approved`). Unique. |
| `label` | VARCHAR(60) | No | Human-readable display name shown in back-office UI (e.g. `In Progress`). |
| `description` | TEXT | Yes | Optional longer explanation of what this status means operationally. |
| `is_terminal` | BOOLEAN | No | `TRUE` if no further transitions are expected from this status. Terminal statuses are `approved`, `rejected`, and `expired`. Non-terminal statuses (`pending`, `in_progress`, `under_review`, `suspended`) can still move forward or backward in the workflow. |

**Seeded statuses, their meaning, and mapping to the Odoo `Estado` field:**

| Code | Terminal | Odoo `Estado` | Meaning |
|---|---|---|---|
| `pending` | No | `Borrador` | Default state on client creation — no review has started. |
| `in_progress` | No | *(internal)* | An agent has started collecting or verifying documents. |
| `under_review` | No | `Revisión` | All documents received; awaiting final decision. |
| `approved` | **Yes** | `Aprobado` | Client identity verified; eligible for credit products. |
| `rejected` | **Yes** | *(internal)* | Client failed verification; cannot proceed. |
| `expired` | **Yes** | *(internal)* | Approval lapsed without disbursement within the allowed period. |
| `suspended` | No | *(internal)* | Temporarily blocked (e.g. fraud flag); can be re-opened by admin. |

> **Odoo sync note.** The Odoo `res.partner` export uses three `Estado` values: `Borrador` (→ `pending`), `Revisión` (→ `under_review`), and `Aprobado` (→ `approved`). The additional statuses (`in_progress`, `rejected`, `expired`, `suspended`) are RIBO-internal states that do not have a direct Odoo counterpart but are needed for the full back-office workflow.

---

## 4. Module: Clients

Clients are the natural persons and companies that apply for credit at RIBO. This module is the central entity of the platform. Its field naming is deliberately aligned with Odoo's `res.partner` model so records can be synced bidirectionally.

### `document_types`

A short nomenclator of accepted identity document types. Having a separate table (instead of a plain ENUM) allows adding new document types (e.g. for new countries of operation) without a schema migration.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `document_type_id` | TINYINT UNSIGNED | No | Auto-incremented primary key. |
| `code` | VARCHAR(20) | No | Short machine key (e.g. `DNI`, `PASSPORT`, `RUC`). Unique. Used in API responses and application logic. |
| `label` | VARCHAR(60) | No | Full human-readable name displayed in forms and reports (e.g. `Documento Nacional de Identidad`). |

**Seeded document types:**

| Code | Label | Typical country |
|---|---|---|
| `DNI` | Documento Nacional de Identidad | Peru, Argentina |
| `PASSPORT` | Passport | International |
| `CUIT` | CUIT / CUIL | Argentina |
| `RUC` | Registro Único de Contribuyentes | Peru |
| `NIT` | Número de Identificación Tributaria | Colombia, Bolivia |
| `CE` | Cédula de Extranjería | Peru (foreign residents) |
| `OTHER` | Other | Catch-all |

---

### `client_tiers`

A nomenclator of commercial risk tiers that RIBO's credit team assigns to each client. Tiers determine credit eligibility, maximum limits, and operational treatment. The data is sourced from the Odoo `res.partner` field `Tipo de cliente`.

Using a separate table (rather than an ENUM or a plain string) means new tiers can be introduced — or existing ones renamed — with a single `INSERT` or `UPDATE`, without touching application code or running a migration.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `tier_id` | TINYINT UNSIGNED | No | Auto-incremented primary key. |
| `code` | VARCHAR(30) | No | Machine-readable slug used in application logic and API filters (e.g. `classic`, `lista_negativa`). Unique. |
| `label` | VARCHAR(60) | No | Display name shown in the back-office UI and client portal (e.g. `Classic`, `Lista Negativa`). |
| `description` | TEXT | Yes | Operational description explaining the criteria and treatment for clients in this tier. |
| `credit_eligible` | BOOLEAN | No | `FALSE` for tiers that block new credit issuance (currently only `lista_negativa`). Application-layer credit checks must gate on this flag before opening any new `credit_requests`. |
| `sort_order` | TINYINT UNSIGNED | No | Display order in dropdowns and reports. Lower numbers appear first. |
| `is_active` | BOOLEAN | No | Allows retiring a tier without deleting it or breaking historical references on `clients.tier_id`. |

**Seeded tiers (sourced from Odoo `Tipo de cliente` values observed in production):**

| Code | `credit_eligible` | Observed share | Description |
|---|---|---|---|
| `potencial` | ✅ Yes | < 1% | New prospect with no RIBO credit history. Limit and tier will be assigned after first assessment. |
| `classic` | ✅ Yes | 27% | Standard client with a normal credit profile and a moderate credit limit (median ~S/ 800). |
| `select` | ✅ Yes | 14% | Good track record; higher limit than Classic (median ~S/ 1,200). |
| `gold` | ✅ Yes | 9% | Premium client with excellent repayment history and the highest credit limits (up to S/ 184,000 observed). |
| `zona_gris` | ✅ Yes | 3% | Under enhanced monitoring due to irregular payment behaviour. Eligible for credit but with tighter controls. |
| `lista_negativa` | ❌ **No** | 40% | Blacklisted. Ineligible for new credit until the restriction is formally lifted by a compliance officer. |

> **Risk note.** `Lista Negativa` represents 40% of the current client base — the largest single tier. This reflects RIBO's pattern of onboarding and then restricting high-risk clients rather than rejecting them outright, allowing future re-evaluation.

---

### `clients`

The main entity table. A client can be either a **natural person** (individual) or a **legal entity** (company). The `is_company` flag controls which name fields are relevant. Every credit request ultimately links to a client record once KYC is complete.

#### Identity fields

| Column | Type | Nullable | Description |
|---|---|---|---|
| `client_id` | INT UNSIGNED | No | Auto-incremented primary key. Internal RIBO identifier. |
| `document_type_id` | TINYINT UNSIGNED | No | FK → `document_types`. Defines what kind of ID the `dni` field holds. |
| `dni` | VARCHAR(30) | No | The actual identity document number (e.g. `12345678` for a Peruvian DNI). Together with `document_type_id` forms a unique key — the same number cannot be registered twice for the same document type. |
| `first_name` | VARCHAR(100) | Yes | Given name(s). `NULL` for legal entities (`is_company = TRUE`). |
| `last_name` | VARCHAR(100) | Yes | Family name(s). `NULL` for legal entities. |
| `company_name` | VARCHAR(255) | Yes | Legal business name. `NULL` for natural persons (`is_company = FALSE`). |
| `is_company` | BOOLEAN | No | `TRUE` if the client is a legal entity (PYME, corporation). Drives which name field and which document types are applicable. Defaults to `FALSE`. |
| `vat` | VARCHAR(30) | Yes | Tax ID or VAT registration number. For Peruvian companies this is the `RUC`; for individuals it may be the same as `dni`. Mirrors Odoo's `partner.vat`. |
| `gender` | ENUM('M','F','X') | Yes | Biological or self-reported gender. `NULL` for companies. `X` covers non-binary and undisclosed. |
| `birth_date` | DATE | Yes | Date of birth. Used for age verification and credit scoring. `NULL` for companies. |
| `nationality_id` | INT UNSIGNED | Yes | FK → `countries`. The client's nationality (which may differ from their country of residence). `NULL` on deletion of the referenced country (SET NULL). |

#### Contact fields

| Column | Type | Nullable | Description |
|---|---|---|---|
| `email` | VARCHAR(254) | Yes | Primary email address. 254 characters is the RFC 5321 maximum. |
| `phone` | VARCHAR(30) | Yes | Landline number including country code (Odoo: `partner.phone`). |
| `mobile` | VARCHAR(30) | Yes | Mobile / WhatsApp number. RIBO uses WhatsApp as a primary contact channel (Odoo: `partner.mobile`). |
| `website` | VARCHAR(255) | Yes | Company or personal website. Mainly relevant for PYME clients. |

#### Address fields

These mirror Odoo's structured address model. The hierarchy `country → state → city` is fully normalized via FKs; `zip_code` can override the default postal code stored on the city.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `street` | VARCHAR(255) | Yes | Primary street address line (Odoo: `partner.street`). |
| `street2` | VARCHAR(255) | Yes | Apartment, floor, reference (Odoo: `partner.street2`). |
| `city_id` | INT UNSIGNED | Yes | FK → `cities`. Normalized city reference. |
| `state_id` | INT UNSIGNED | Yes | FK → `states_provinces`. Department or state. |
| `country_id` | INT UNSIGNED | Yes | FK → `countries`. Country of residence (may differ from nationality). |
| `zip_code` | VARCHAR(20) | Yes | Specific postal code for the client's address, overriding the city default when needed. |

#### KYC lifecycle fields

| Column | Type | Nullable | Description |
|---|---|---|---|
| `kyc_status_id` | TINYINT UNSIGNED | No | FK → `kyc_statuses`. Current KYC state of this client. Defaults to `1` (`pending`) on record creation. |
| `kyc_reviewed_at` | DATETIME | Yes | Timestamp of the last KYC decision (approval or rejection). `NULL` while still in review. |
| `kyc_reviewed_by` | INT UNSIGNED | Yes | FK → `users`. The back-office agent who made the last KYC decision. `NULL` if not yet reviewed or if the reviewing user was deleted. |
| `kyc_notes` | TEXT | Yes | Free-text field for the agent to record observations, document quality notes, or reasons for the decision. Not shown to clients. |

#### Odoo integration fields

| Column | Type | Nullable | Description |
|---|---|---|---|
| `odoo_partner_id` | INT UNSIGNED | Yes | The `res.partner` ID of the corresponding record in the Odoo ERP. Unique — one client maps to at most one Odoo partner. Used to keep both systems in sync. |
| `ref` | VARCHAR(50) | Yes | Internal reference code (Odoo: `partner.ref`). Can hold a client code, account number, or legacy ID from a previous system. |

#### Commercial tier

| Column | Type | Nullable | Description |
|---|---|---|---|
| `tier_id` | TINYINT UNSIGNED | Yes | FK → `client_tiers`. The risk/commercial segment assigned by RIBO's credit team (e.g. `classic`, `gold`, `lista_negativa`). `NULL` when the client has not yet been classified — typically the case for brand-new prospects. The `client_tiers.credit_eligible` flag on the referenced row must be checked before opening any new credit request for this client. |

#### Credit capacity & balance fields

These six fields are computed and maintained by Odoo and exposed through the `res.partner` export. They give a real-time financial snapshot of the client's credit position. All monetary values are in Peruvian Soles (PEN) unless the underlying credit product specifies otherwise.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `credit_limit` | DECIMAL(12,2) | Yes | Maximum capital RIBO will extend to this client across all active credit products simultaneously. Corresponds to Odoo's **"Monto maximo de capital disponible"**. `NULL` means not yet assessed (typically `Lista Negativa` or unclassified clients). Negative values indicate the client has exceeded their limit. Observed range: −S/ 2,185 to S/ 184,625. |
| `available_credit_slots` | INT | No | Odoo computed field **"Créditos activos disponibles"**. The value `−1` is a system sentinel meaning *not computed* or *unlimited slots*. In the current production dataset this is always `−1`; once Odoo populates it with a positive integer it will represent the number of additional simultaneous credits the client may open. Defaults to `−1`. |
| `monthly_payment_capacity` | DECIMAL(12,2) | Yes | Maximum monthly instalment the client can absorb, derived from their income assessment. Corresponds to Odoo's **"Capacidad de pago mensual disponible"**. `NULL` (or stored as `−1` when synced from Odoo) means not yet assessed. Observed meaningful range: S/ 3,000 – S/ 7,862. |
| `current_balance` | DECIMAL(12,2) | Yes | Total outstanding principal owed by the client across all active credits. Corresponds to Odoo's **"Saldo"**. `NULL` when the client has no active credits. Observed range: S/ 126 – S/ 130,500. |
| `overdue_balance` | DECIMAL(12,2) | Yes | The portion of `current_balance` that is past its due date. Corresponds to Odoo's **"Saldo vencido"**. `NULL` when there is no overdue amount. A non-zero value triggers risk alerts and may drive tier reclassification toward `zona_gris` or `lista_negativa`. Observed range: S/ 126 – S/ 18,325. |
| `active_credits_count` | TINYINT UNSIGNED | No | Number of currently active credit agreements. Corresponds to Odoo's **"Creditos activos"**. Observed values in production: `0`, `1`, `2`. Defaults to `0`. |

#### Audit fields

| Column | Type | Nullable | Description |
|---|---|---|---|
| `is_active` | BOOLEAN | No | Soft-delete flag. `FALSE` hides the client from normal queries without deleting history. |
| `created_at` | DATETIME | No | Timestamp of record creation. Set automatically by the database. |
| `updated_at` | DATETIME | No | Timestamp of the last update. Updated automatically by MySQL on every write. |

---

### `client_kyc_history`

An append-only audit log that records every KYC status transition for a client. It answers questions like *"Who approved this client and when?"* or *"Was this client ever suspended before being approved?"*

The `from_status_id` being `NULL` on the first row is intentional — it marks the initial assignment when the client was created with status `pending`.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `history_id` | INT UNSIGNED | No | Auto-incremented primary key. |
| `client_id` | INT UNSIGNED | No | FK → `clients`. The client whose KYC changed. Cascades on delete — history is removed if the client is hard-deleted. |
| `from_status_id` | TINYINT UNSIGNED | Yes | FK → `kyc_statuses`. The status before the transition. `NULL` on the very first assignment. Preserved even if the status is later deleted (SET NULL). |
| `to_status_id` | TINYINT UNSIGNED | No | FK → `kyc_statuses`. The status after the transition. Cannot be `NULL` — every row must record where the client ended up. |
| `changed_by` | INT UNSIGNED | Yes | FK → `users`. The agent or admin who triggered the change. `NULL` if the change was made programmatically (e.g. expiry job). |
| `notes` | TEXT | Yes | Reason or context for the transition (e.g. *"Missing utility bill resubmitted"*). |
| `changed_at` | DATETIME | No | Exact timestamp of the transition. Defaults to `CURRENT_TIMESTAMP`. |

---

## 5. Module: Users & Access Control

Users are system accounts — distinct from clients. The same person may have both a `clients` record (their financial identity) and a `users` record (their login credentials). The module supports two authentication paradigms: credential-based (private users) and token-based (public/API users).

### `roles`

A nomenclator defining the four permission levels in the system.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `role_id` | TINYINT UNSIGNED | No | Auto-incremented primary key. |
| `code` | VARCHAR(30) | No | Machine-readable role identifier. Unique. Used in authorization middleware. |
| `label` | VARCHAR(60) | No | Human-readable name shown in the admin UI. |
| `description` | TEXT | Yes | Explanation of what this role can and cannot do. |

**Seeded roles:**

| Code | Intended for |
|---|---|
| `admin` | RIBO staff with full system access — can manage users, roles, and configuration. |
| `agent` | Back-office staff who handle KYC review and client management, but cannot change system configuration. |
| `client` | Registered clients accessing the self-service portal to track their credit requests. |
| `public` | Anonymous visitors or external API integrations identified by token only; no password, no personal account. |

---

### `users`

The platform's user table. It unifies two very different personas under one table, controlled by the `is_public` flag.

**Private users** (`is_public = FALSE`): admins, agents, and portal clients. They authenticate with a username/email + password and may optionally enable TOTP two-factor authentication.

**Public users** (`is_public = TRUE`): API consumers, webhooks, or anonymous web sessions. They are identified exclusively by a token; they have no password.

#### Identification fields

| Column | Type | Nullable | Description |
|---|---|---|---|
| `user_id` | INT UNSIGNED | No | Auto-incremented primary key. |
| `role_id` | TINYINT UNSIGNED | No | FK → `roles`. Determines what actions this user can perform. |
| `username` | VARCHAR(60) | Yes | Unique login name. `NULL` for public/guest users who do not have a login. |
| `email` | VARCHAR(254) | Yes | Unique email address. Used for password resets, notifications, and as an alternative login identifier. |

#### Credential fields (private users only)

| Column | Type | Nullable | Description |
|---|---|---|---|
| `password_hash` | VARCHAR(255) | Yes | The result of hashing the user's password with bcrypt or Argon2. Never store the plaintext password. `NULL` for public users. |
| `password_salt` | VARCHAR(255) | Yes | Explicit cryptographic salt. For bcrypt/Argon2 the salt is embedded in `password_hash`; this column exists for algorithms that manage the salt separately. |

#### Token fields

| Column | Type | Nullable | Description |
|---|---|---|---|
| `access_token` | VARCHAR(512) | Yes | A short-lived JWT or opaque token sent with each API request. For private users this is issued after login; for public users it is their sole identifier. |
| `refresh_token` | VARCHAR(512) | Yes | A long-lived token used to obtain a new `access_token` without re-authentication. The rotation log is kept in `user_sessions`. |
| `token_expires_at` | DATETIME | Yes | Expiry timestamp of the current `access_token`. Application should reject requests where this is in the past. |

#### Two-factor authentication fields

| Column | Type | Nullable | Description |
|---|---|---|---|
| `totp_secret` | VARCHAR(64) | Yes | Base32-encoded TOTP secret shared with the user's authenticator app (e.g. Google Authenticator). `NULL` when 2FA is not configured. |
| `is_2fa_enabled` | BOOLEAN | No | `TRUE` if TOTP verification is required at login. Defaults to `FALSE`. |

#### Access model

| Column | Type | Nullable | Description |
|---|---|---|---|
| `is_public` | BOOLEAN | No | `TRUE` → public/guest user (token-only, no password). `FALSE` → private user (username + password). Defaults to `FALSE`. |
| `client_id` | INT UNSIGNED | Yes | FK → `clients`. Links a portal user to their corresponding client record. An agent or admin user will have this as `NULL`. |

#### Profile fields

| Column | Type | Nullable | Description |
|---|---|---|---|
| `first_name` | VARCHAR(100) | Yes | Given name. Used in UI greetings and email templates. |
| `last_name` | VARCHAR(100) | Yes | Family name. |

#### Security & audit fields

| Column | Type | Nullable | Description |
|---|---|---|---|
| `is_active` | BOOLEAN | No | Soft-delete / disable flag. Deactivated users cannot log in. Defaults to `TRUE`. |
| `last_login_at` | DATETIME | Yes | Timestamp of the most recent successful login. Used in security dashboards. |
| `last_login_ip` | VARCHAR(45) | Yes | IP address of the last login. Supports IPv4 (15 chars) and IPv6 (39 chars). Stored for audit purposes. |
| `failed_login_count` | TINYINT UNSIGNED | No | Counter of consecutive failed login attempts. Reset to `0` on successful login. |
| `locked_until` | DATETIME | Yes | If not `NULL` and in the future, the account is temporarily locked due to repeated failed logins (brute-force protection). The application must check this before processing any login attempt. |
| `created_at` | DATETIME | No | Record creation timestamp. |
| `updated_at` | DATETIME | No | Last modification timestamp, maintained automatically by MySQL. |

---

### `user_sessions`

Stores one row per issued refresh token. This enables **refresh-token rotation** — a security pattern where each token is single-use: consuming it issues a new one and invalidates the old. If the old token is presented again, a reuse attack is detected and all sessions for that user can be revoked.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `session_id` | INT UNSIGNED | No | Auto-incremented primary key. |
| `user_id` | INT UNSIGNED | No | FK → `users`. The user this session belongs to. Cascades on delete — all sessions are removed when the user is hard-deleted. |
| `refresh_token_hash` | VARCHAR(255) | No | A one-way hash of the refresh token (never store the raw token in the database). The application hashes the incoming token and looks it up here. |
| `issued_at` | DATETIME | No | When this token was generated. Defaults to `CURRENT_TIMESTAMP`. |
| `expires_at` | DATETIME | No | Absolute expiry. The application rejects tokens presented after this timestamp even if `revoked_at` is `NULL`. |
| `revoked_at` | DATETIME | Yes | Timestamp of explicit revocation (logout, rotation, or admin action). `NULL` means the token is still valid (subject to `expires_at`). |
| `ip_address` | VARCHAR(45) | Yes | IP from which the session was created. Supports IPv4 and IPv6. |
| `user_agent` | VARCHAR(512) | Yes | Browser or API client user-agent string at session creation. Used for anomaly detection (e.g. unexpected device change). |

---

## 6. Module: Credits

This module models RIBO's core business: the financial products offered on the website and the lifecycle of every loan or remittance application submitted through it.

### `credit_types`

The product catalogue — one row per credit product published on [ribo.pe/peru-productos](https://ribo.pe/peru-productos). This is a **nomenclator**: it defines the available options and their business rules (amount ranges, installment limits). Application-layer validation uses these values to enforce the simulator's constraints.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `credit_type_id` | TINYINT UNSIGNED | No | Auto-incremented primary key. |
| `code` | VARCHAR(30) | No | Machine key used in code and API payloads (e.g. `personal`, `vehiculo`, `soat`). Unique. |
| `label` | VARCHAR(80) | No | Display name shown to end users (e.g. `Crédito Personal`). |
| `description` | TEXT | Yes | Short marketing description of the product, matching the website copy. |
| `min_amount` | DECIMAL(12,2) | Yes | Minimum amount a client can request for this product. `NULL` means no enforced minimum (as in PYME and Remesa, which are negotiated). |
| `max_amount` | DECIMAL(12,2) | Yes | Maximum requestable amount. `NULL` means no published cap. |
| `currency` | CHAR(3) | No | ISO 4217 currency code for this product. All Peruvian lending products use `PEN`; international remittances use `USD`. Defaults to `PEN`. |
| `min_installments` | TINYINT UNSIGNED | Yes | Minimum number of monthly installments (cuotas). `NULL` for remesas which are not installment-based. |
| `max_installments` | TINYINT UNSIGNED | Yes | Maximum number of monthly installments. Drives the simulator's slider upper bound. |
| `is_active` | BOOLEAN | No | Controls whether the product appears on the website and is available for new requests. Allows retiring a product without deleting its historical requests. Defaults to `TRUE`. |
| `sort_order` | TINYINT UNSIGNED | No | Display order on the website simulator dropdown. Lower numbers appear first. |
| `created_at` | DATETIME | No | Record creation timestamp. |
| `updated_at` | DATETIME | No | Last modification timestamp. |

**Seeded products (sourced from ribo.pe):**

| Code | Label | Currency | Min Amount | Max Installments |
|---|---|---|---|---|
| `personal` | Crédito Personal | PEN | S/ 400 | 12 months |
| `vehiculo` | Crédito para Vehículos | PEN | S/ 16,000 | 48 months |
| `moto` | Crédito para Motos | PEN | S/ 570 | 4 months |
| `soat` | Crédito para SOAT | PEN | S/ 5,000 | 15 months |
| `pyme` | Crédito para PYMES | PEN | — (negotiated) | 15 months |
| `remesa` | Remesa Internacional | USD | — (negotiated) | — |

---

### `credit_request_statuses`

Lifecycle states for a credit request. Like `kyc_statuses`, this is a nomenclator — separating the state definitions from the transactional table makes it easy to add states or rename labels without a schema change.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `status_id` | TINYINT UNSIGNED | No | Auto-incremented primary key. |
| `code` | VARCHAR(30) | No | Machine-readable key (e.g. `submitted`, `approved`). Unique. |
| `label` | VARCHAR(60) | No | Human-readable label in Spanish, matching back-office language (e.g. `En Revisión`). |
| `description` | TEXT | Yes | Longer explanation of what this state means operationally. |
| `is_terminal` | BOOLEAN | No | `TRUE` for states from which no further transitions are expected. Once a request reaches a terminal state, agents must create a new request rather than reopen the old one. |

**Lifecycle flow:**

```
draft ──► submitted ──► in_review ──► approved ──► disbursed
                                  └──► rejected
              └──► cancelled
                             └──► expired
```

| Code | Terminal | Meaning |
|---|---|---|
| `draft` | No | Request started on the web form but not yet sent (e.g. simulator filled but "Submit" not clicked). |
| `submitted` | No | Form submitted by the prospect; received by RIBO. Triggers agent notification. |
| `in_review` | No | An agent has picked up the request and is evaluating documents and creditworthiness. |
| `approved` | **Yes** | Request approved; awaiting fund disbursement. Approved terms are recorded on the request row. |
| `disbursed` | **Yes** | Funds have been transferred to the client's bank account. The credit is now active. |
| `rejected` | **Yes** | Request does not meet approval criteria. The `rejection_reason` field on `credit_requests` is populated. |
| `cancelled` | **Yes** | Withdrawn by the client before a decision, or cancelled by the system after inactivity. |
| `expired` | **Yes** | The prospect did not respond within the required timeframe after initial contact. |

---

### `credit_requests`

The central transactional table of the credits module. Each row represents one loan or remittance application submitted through the RIBO website. The table is designed to capture both **prospect requests** (before KYC, where `client_id` is `NULL`) and **client requests** (where the applicant is already registered and verified).

This dual design supports RIBO's funnel: a visitor uses the simulator on ribo.pe, submits a form with their contact details, and only later gets linked to a full `clients` record after an agent completes their KYC.

#### Identification fields

| Column | Type | Nullable | Description |
|---|---|---|---|
| `credit_request_id` | INT UNSIGNED | No | Auto-incremented primary key. |
| `credit_type_id` | TINYINT UNSIGNED | No | FK → `credit_types`. The product being requested (e.g. personal loan, vehicle, SOAT). |
| `client_id` | INT UNSIGNED | Yes | FK → `clients`. Links the request to a verified client record. `NULL` when the applicant is still a prospect who has not completed KYC. Once KYC is done, an agent populates this field, tying together the web submission and the client record. `SET NULL` on client deletion to preserve the request history. |

#### Prospect contact fields

These fields capture the contact information that the prospect enters on the web form. They are used **only when `client_id` is NULL**. Once KYC is complete and `client_id` is set, these fields become redundant (the data lives on the `clients` record) but are kept for historical accuracy.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `prospect_first_name` | VARCHAR(100) | Yes | First name entered on the web form. |
| `prospect_last_name` | VARCHAR(100) | Yes | Last name entered on the web form. |
| `prospect_email` | VARCHAR(254) | Yes | Email address entered on the web form. Used to contact the prospect while they are not yet a registered client. |
| `prospect_phone` | VARCHAR(30) | Yes | Phone or WhatsApp number from the web form. |
| `prospect_dni` | VARCHAR(30) | Yes | Identity document number entered on the form. Used during KYC to look up or create the `clients` record. |

#### Requested terms fields

What the applicant asked for, as entered in the website simulator.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `requested_amount` | DECIMAL(12,2) | No | The loan or remittance amount the applicant entered in the simulator. Validated against `credit_types.min_amount` and `max_amount`. |
| `currency` | CHAR(3) | No | ISO 4217 currency of the requested amount. Copied from `credit_types.currency` at submission time and stored here so the record is self-contained even if the product's currency changes later. Defaults to `PEN`. |
| `installments` | TINYINT UNSIGNED | Yes | Number of monthly installments (cuotas) the applicant selected in the simulator. `NULL` for remesas or when the slider was not used. |
| `monthly_payment` | DECIMAL(12,2) | Yes | The estimated monthly payment amount displayed by the simulator at submission. Stored for reference — the actual approved cuota may differ. |

#### Approved terms fields

These fields are filled in by a back-office agent after the credit committee approves the request. They may differ from the requested terms (e.g. the approved amount may be lower than requested).

| Column | Type | Nullable | Description |
|---|---|---|---|
| `approved_amount` | DECIMAL(12,2) | Yes | The final approved loan amount. `NULL` until approval. |
| `approved_rate_pct` | DECIMAL(6,4) | Yes | The annual effective interest rate (TEA — Tasa Efectiva Anual) offered to the client, expressed as a percentage with four decimal places (e.g. `24.0000` for 24%). `NULL` until approval. |
| `approved_installments` | TINYINT UNSIGNED | Yes | Final agreed number of installments. May differ from `installments`. `NULL` until approval. |
| `approved_at` | DATETIME | Yes | Timestamp when the credit committee made the approval decision. `NULL` until approved. |
| `approved_by` | INT UNSIGNED | Yes | FK → `users`. The agent or admin who recorded the approval. `NULL` if not yet approved. `SET NULL` if that user is deleted. |
| `disbursed_at` | DATETIME | Yes | Timestamp when the funds were transferred to the client. `NULL` until disbursement. Only set when `status` reaches `disbursed`. |

#### Lifecycle & tracking fields

| Column | Type | Nullable | Description |
|---|---|---|---|
| `status_id` | TINYINT UNSIGNED | No | FK → `credit_request_statuses`. Current state in the approval workflow. Defaults to `1` (`draft`) on creation. |
| `source_channel` | VARCHAR(30) | No | How the request originated. `web` for the ribo.pe simulator, `typeform` for the Typeform forms linked on the site, `whatsapp` for requests taken over chat, `referral` for partner-sourced leads. Defaults to `web`. |
| `utm_source` | VARCHAR(100) | Yes | UTM tracking parameter from the URL at the time of form submission (e.g. `google`, `facebook`). Used for marketing attribution reporting. |
| `utm_medium` | VARCHAR(100) | Yes | UTM medium parameter (e.g. `cpc`, `email`, `social`). |
| `utm_campaign` | VARCHAR(100) | Yes | UTM campaign name (e.g. `soat_promo_2025`). |

#### Notes & rejection fields

| Column | Type | Nullable | Description |
|---|---|---|---|
| `notes` | TEXT | Yes | Internal agent notes about this request. Not visible to the client. |
| `rejection_reason` | TEXT | Yes | Explanation of why the request was rejected. Populated when `status` transitions to `rejected`. May be shown to the client in the portal. |

#### Audit fields

| Column | Type | Nullable | Description |
|---|---|---|---|
| `submitted_at` | DATETIME | Yes | Timestamp when the applicant clicked "Submit" on the web form. Distinct from `created_at` — a `draft` row is created before submission. |
| `created_at` | DATETIME | No | Database record creation timestamp. |
| `updated_at` | DATETIME | No | Last modification timestamp, maintained automatically. |

---

### `credit_request_history`

Append-only audit trail of every status transition in a credit request's lifecycle. Mirrors the same pattern used in `client_kyc_history`. Useful for compliance reporting, SLA measurement (how long did a request sit in `in_review`?), and dispute resolution.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `history_id` | INT UNSIGNED | No | Auto-incremented primary key. |
| `credit_request_id` | INT UNSIGNED | No | FK → `credit_requests`. The request whose status changed. Cascades on delete — history rows are removed if the parent request is hard-deleted. |
| `from_status_id` | TINYINT UNSIGNED | Yes | FK → `credit_request_statuses`. Status before the transition. `NULL` on the very first row when a request is created. Preserved as `NULL` if the referenced status is later deleted (SET NULL). |
| `to_status_id` | TINYINT UNSIGNED | No | FK → `credit_request_statuses`. Status after the transition. Always required. |
| `changed_by` | INT UNSIGNED | Yes | FK → `users`. The agent or admin who made the change. `NULL` if triggered automatically by the system (e.g. expiry cron job or webhook from an external service). |
| `notes` | TEXT | Yes | Context for the transition (e.g. *"Client confirmed bank account details via WhatsApp"*). |
| `changed_at` | DATETIME | No | Precise timestamp of the transition. Defaults to `CURRENT_TIMESTAMP`. |

---

## 7. Key Business Flows

### New prospect submits a loan request via the website

```
1. Visitor opens ribo.pe and uses the simulator.
2. A credit_requests row is created with status = 'draft'.
3. Visitor fills in the web form and clicks "Solicítalo ya".
4. status transitions to 'submitted'; submitted_at is recorded.
   → A credit_request_history row is inserted (draft → submitted).
5. An agent picks up the request → status → 'in_review'.
6. Agent contacts the prospect for KYC documents.
7. A clients record is created; credit_requests.client_id is linked.
8. clients.kyc_status_id progresses through pending → in_progress → approved.
   → client_kyc_history rows are inserted for each transition.
9. Credit committee reviews → credit_requests status → 'approved'.
   → approved_amount, approved_rate_pct, approved_at, approved_by are filled in.
10. Funds are transferred → status → 'disbursed'; disbursed_at is set.
```

### Existing client requests a second credit

```
1. Client logs in to the portal (users record with role = 'client').
2. Client opens simulator and submits a new request.
3. A credit_requests row is created with client_id already set.
4. Prospect fields (prospect_*) are left NULL — client data is on clients.
5. KYC is already approved → no new KYC required.
6. Flow continues from step 5 above.
```

### KYC expiry job (automated)

```
1. Scheduled job queries clients WHERE kyc_status = 'approved'
   AND kyc_reviewed_at < NOW() - INTERVAL 1 YEAR.
2. For each expired client:
   a. UPDATE clients SET kyc_status_id = 'expired'.
   b. INSERT INTO client_kyc_history (from = approved, to = expired, changed_by = NULL).
3. Any open credit_requests for these clients are flagged for agent review.
```

---

## 8. Design Principles

### Nomenclators over ENUMs
Status fields (`kyc_status_id`, `status_id`, `role_id`, `credit_type_id`, `document_type_id`, `tier_id`) all reference separate catalogue tables instead of using MySQL `ENUM`. This means new values can be added with a simple `INSERT` instead of an `ALTER TABLE`, and every status carries a human-readable label and metadata (like `is_terminal` or `credit_eligible`).

### Client tiers as a first-class concept
The `client_tiers` nomenclator encodes RIBO's commercial segmentation logic (Classic → Select → Gold, and risk tiers like Zona Gris and Lista Negativa). The `credit_eligible` boolean on the tier row is the authoritative gate for new credit issuance — application code checks this flag instead of hard-coding tier names, making it safe to rename or add tiers in the future. In the current production dataset, 40% of clients are `Lista Negativa`, making this flag operationally critical.

### Odoo financial fields synced to the client record
Six fields on `clients` (`credit_limit`, `available_credit_slots`, `monthly_payment_capacity`, `current_balance`, `overdue_balance`, `active_credits_count`) mirror Odoo computed columns from `res.partner`. They are denormalized deliberately: keeping them on the `clients` row avoids expensive cross-system joins at query time and makes the RIBO schema self-sufficient for reporting. The Odoo sync job is responsible for keeping these values fresh. The sentinel value `−1` for `available_credit_slots` and `monthly_payment_capacity` is preserved from Odoo to avoid data loss during import; application code must treat `−1` as `NULL` for business logic purposes.

### Audit trails as first-class citizens
Both the KYC workflow (`client_kyc_history`) and the credit workflow (`credit_request_history`) have dedicated history tables. These are append-only: rows are never updated, only inserted. This guarantees a tamper-evident record of every state change, required for financial regulatory compliance (SBS Resolution N° 02568-2021).

### Prospect-first credit requests
A `credit_requests` row can exist **before** a `clients` row. This models the real funnel: web visitors submit forms before completing KYC. The `prospect_*` fields capture their self-reported data; `client_id` is nullable and gets filled in later. This avoids losing lead data if KYC fails.

### Odoo compatibility
All field names and foreign key patterns on the `clients` table follow Odoo's `res.partner` conventions (`vat`, `street`, `street2`, `ref`, `odoo_partner_id`). This makes bidirectional sync straightforward without a transformation layer.

### Security by design
- Passwords are stored only as hashes (`password_hash`) — never plaintext.
- Refresh tokens are stored only as hashes in `user_sessions` — never raw.
- Brute-force protection is built into the schema via `failed_login_count` and `locked_until`.
- The `is_public` flag cleanly separates two authentication paradigms (credential vs. token) in a single `users` table.

### Soft deletes
Both `clients` and `users` have an `is_active` flag. Deactivating a record preserves all referential integrity and history while hiding the entity from normal application queries. Hard deletes are reserved for GDPR erasure requests, handled at the application layer.
