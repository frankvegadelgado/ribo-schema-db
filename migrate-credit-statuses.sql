-- =============================================================================
-- migrate-credit-statuses.sql
-- Replaces the simplified credit_request_statuses seed data in ribo_schema.sql
-- with the 13 real statuses observed in the Odoo Créditos module.
--
-- WHY: ribo_schema.sql seeds 8 generic statuses (draft, submitted, in_review…).
--      The actual Odoo credit workflow has 13 specific stages that must match
--      exactly so status codes returned by the API are consistent with Odoo.
--
-- STRUCTURAL CHANGES: NONE — table schema is unchanged.
--      Only the seed rows in credit_request_statuses are replaced.
--
-- Real Odoo status pipeline (left-to-right in the UI):
--
--   cotizacion ──► en_revision ──► en_aprobacion ──► acreditacion_pendiente
--       └──────────────────────────────────────────────────► rechazado
--
--   acreditacion_pendiente ──► acreditado ──► pagado  ✅ (terminal)
--       │
--       ├──► reconfigurado   (restructured terms, stays active)
--       ├──► renovado        (renewed for another cycle)
--       ├──► pre_cancelado   (pending final cancellation)
--       ├──► refinanciado    (replaced by a new credit) ✅ (terminal)
--       ├──► judicial        (sent to legal / collections)
--       ├──► incobrable      (written off / uncollectable) ✅ (terminal)
--       └──► rechazado       (rejected) ✅ (terminal)
--
-- Run AFTER ribo_schema.sql (tables must exist).
-- Run BEFORE seed-partners.sql (no credit_requests rows exist yet at that point).
-- =============================================================================

SET NAMES utf8mb4;
SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0;

-- ---------------------------------------------------------------------------
-- Step 1 — Clear the simplified placeholder statuses inserted by ribo_schema.sql
-- FK checks are OFF so this won't fail even if credit_requests rows exist.
-- ---------------------------------------------------------------------------
DELETE FROM credit_request_statuses;

-- Reset the auto_increment so IDs start from 1 predictably.
ALTER TABLE credit_request_statuses AUTO_INCREMENT = 1;

-- ---------------------------------------------------------------------------
-- Step 2 — Insert the 13 real Odoo Créditos statuses
--
-- Columns: code, label, description, is_terminal
--   code        → machine key used in ribo-api business logic
--   label       → Spanish display name shown in back-office / frontend
--   description → operational meaning for agents
--   is_terminal → TRUE means the credit lifecycle has ended for this record
-- ---------------------------------------------------------------------------
INSERT INTO credit_request_statuses (code, label, description, is_terminal) VALUES

  -- ── Initial stage ──────────────────────────────────────────────────────
  ('cotizacion',
   'Cotización',
   'Crédito recién creado o simulado; aún no enviado a revisión. '
   'Equivale al estado "Borrador" en versiones anteriores del esquema. '
   'El cliente o el agente puede editar todos los campos libremente.',
   FALSE),

  -- ── Review & approval pipeline ─────────────────────────────────────────
  ('en_revision',
   'En Revisión',
   'El expediente fue enviado; un agente de crédito está verificando '
   'documentación, historial crediticio y capacidad de pago. '
   'Odoo campo Estado: "En revisión".',
   FALSE),

  ('en_aprobacion',
   'En Aprobación',
   'La revisión técnica pasó; el crédito está en mesa de aprobación '
   '(comité o supervisor). Odoo campo Estado: "En aprobación".',
   FALSE),

  ('acreditacion_pendiente',
   'Acreditación Pendiente',
   'Crédito aprobado por el comité; pendiente de firma de contrato '
   'y desembolso efectivo al cliente.',
   FALSE),

  -- ── Active & disbursed ─────────────────────────────────────────────────
  ('acreditado',
   'Acreditado',
   'Contrato firmado y fondos desembolsados. El crédito está vigente '
   'y generando cuotas. Corresponde a "Acreditado" en Odoo.',
   FALSE),

  -- ── Completed ─────────────────────────────────────────────────────────
  ('pagado',
   'Pagado',
   'Todas las cuotas fueron cobradas. Crédito cancelado exitosamente. '
   'Estado terminal — no se esperan más transacciones sobre este registro.',
   TRUE),

  -- ── Restructuring / lifecycle variants ────────────────────────────────
  ('reconfigurado',
   'Reconfigurado',
   'Se modificaron las condiciones del crédito activo (monto, tasa, plazo) '
   'sin cancelarlo. El crédito sigue vigente con los nuevos términos.',
   FALSE),

  ('renovado',
   'Renovado',
   'Crédito original finalizado y reemplazado por uno nuevo al mismo cliente '
   'dentro del mismo ciclo comercial. Sigue activo bajo el nuevo número.',
   FALSE),

  ('pre_cancelado',
   'Pre-Cancelado',
   'Se inició el proceso de cancelación anticipada; pendiente de liquidación '
   'del saldo total. Pasará a "Pagado" o "Rechazado" según el desenlace.',
   FALSE),

  -- ── Terminal — negative outcomes ───────────────────────────────────────
  ('refinanciado',
   'Refinanciado',
   'El saldo fue refinanciado y absorbido por un nuevo crédito. '
   'Este registro queda cerrado; el nuevo crédito lleva la deuda.',
   TRUE),

  ('judicial',
   'Judicial',
   'La deuda fue transferida al área legal / estudio jurídico para cobranza '
   'coactiva. Puede recuperarse (→ acreditado o pagado) o declararse incobrable.',
   FALSE),

  ('incobrable',
   'Incobrable',
   'Deuda declarada irrecuperable y castigada contablemente. '
   'Estado terminal — registro conservado para historial y reportes.',
   TRUE),

  ('rechazado',
   'Rechazado',
   'Solicitud denegada en cualquier etapa del proceso (revisión, aprobación '
   'o acreditación). El cliente puede volver a postular. '
   'Odoo acción: botón RECHAZAR.',
   TRUE);

-- ---------------------------------------------------------------------------
-- Step 3 — Update the DEFAULT on credit_requests.status_id
--          The old default pointed to status_id = 1 ('draft').
--          After re-seeding, status_id = 1 is now 'cotizacion' — same intent,
--          no ALTER TABLE needed; the DEFAULT 1 still resolves correctly.
-- ---------------------------------------------------------------------------
-- (No ALTER needed — DEFAULT 1 still maps to 'cotizacion' after re-seed.)

SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS;

-- ---------------------------------------------------------------------------
-- Verification — run this after applying the migration
-- ---------------------------------------------------------------------------
SELECT
    status_id,
    code,
    label,
    is_terminal,
    CASE is_terminal WHEN TRUE THEN '✅ terminal' ELSE '↻  active' END AS lifecycle
FROM credit_request_statuses
ORDER BY status_id;
