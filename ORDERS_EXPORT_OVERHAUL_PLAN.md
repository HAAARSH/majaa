# MAJAA Sales — Orders Export Overhaul: Final Plan

**Project:** majaa-main (Flutter + Supabase B2B sales app)
**Scope:** Admin Orders tab export flow — 3 new features
**Date:** April 2026
**Author:** Claude (via claude.ai), spec co-written with product owner

---

## CORRECTIONS APPLIED (2026-04-22, Claude Code audit)

The original spec assumed UUID order ids and a single-team export. Reality in
this repo differs. These corrections are already baked into the Phase-A
migrations in `supabase/migrations/` (files `20260422000002` through
`20260422000005`). Subsequent phases must honor them.

1. **Order ids are TEXT, not UUID.** `orders.id TEXT PRIMARY KEY` at
   `supabase/migrations/20260323072756_fmcg_core_schema.sql:55`. All
   `UUID[]` columns in the plan that refer to orders were changed to `TEXT[]`
   (`export_batches.order_ids`, `export_batches.orders_marked_delivered`,
   `finalize_export_batch.p_order_ids`).
2. **`order_items.id` stays UUID** but is cast to TEXT when stored in the
   tracking arrays so the union/diff array math stays type-clean.
3. **`customer_brand_routing.customer_id` is TEXT** (matches `customers.id`).
4. **Empty-order false-positive** in the "fully exported" check has been
   guarded with `EXISTS (SELECT 1 FROM order_items ...)`. Without this,
   orders with zero line items (which exist — see
   `admin_orders_tab.dart:309`) would flip to Delivered on every export.
5. **`auth.uid()` returns UUID and `app_users.id` is UUID** — no cast needed.
   Older migrations cast `auth.uid()::TEXT`; new migrations use the direct
   UUID comparison.
6. **Plpgsql column ambiguity** avoided by qualifying `o.id`, `o.status` in
   the `jsonb_object_agg` call. `status` is also a user-defined enum name.
7. **Filename format adopted as new:** `{TEAM}{DD}{MM}.xls` (e.g.
   `JA2204.xls`). Current filename in `admin_orders_tab.dart:740` is
   `orders_customer_wise${dateLabel}.xls` — Phase B changes this.
8. **Current export is already cross-team-aware** (see `_buildCsv` at
   `admin_orders_tab.dart:261-328` — team product-id filter, cross-team
   pickup at lines 417-434). Feature 2 is a UX split of existing logic,
   not a new capability.
9. **Date formula already DD-MMM-YYYY uppercase** at
   `admin_orders_tab.dart:286`. Do not regress when rewriting `_buildCsv`.
10. **"Organic India" category name must be verified** in
    `product_categories` before Phase C. If the category is named
    differently, adjust `customer_brand_routing.brand_name` values and the
    matching logic accordingly.
11. **`OrderItemModel.id` is nullable in Dart** (`order_model.dart:85`).
    When collecting `writtenLineItemIds` client-side, skip nulls — the RPC
    tolerates missing ids (they simply don't count toward "fully exported").
12. **`role = 'super_admin' / 'brand_rep'`** are convention strings; no
    migration defines them as an enum. RLS `IN (...)` checks work but there
    is no DB-level constraint.
13. **Brand_rep merging must group AFTER line-item team-routing** — not
    before. Organic India routing can push a brand_rep's line item from
    its order's team to the other team's CSV. Group key is
    `(customer_id, csv-team)`, not `(customer_id, order.team_id)`.
14. **Migration filenames** use the repo's timestamped convention
    (`YYYYMMDDHHMMSS_snake_case.sql`) and live in `supabase/migrations/`,
    not the root-level `supabase_migration_*.sql` pattern.

Phase-A migrations are staged but **not applied** — review and run on
staging before production. Phase B onwards is next-session work.

---

## Read this first

This plan was designed through a detailed back-and-forth with the product owner. Every decision here has been explicitly confirmed — **do not "improve" the spec without asking.** If something seems suboptimal to you as the implementer, flag it in a comment and leave the behavior as specified. The owner has business reasons for each choice, including ones not written here.

**Do not touch anything outside the scope listed.** The rest of the admin panel, rep UI, offline queue, and existing export logic for single-team cases are working and should stay working. This is additive, not a rewrite.

---

## Context for the implementer

- Main file: `lib/presentation/admin_panel_screen/widgets/admin_orders_tab.dart` (~1,800 lines).
- Data layer: `lib/services/supabase_service.dart`.
- Models: `lib/models/order_model.dart`, `customer_model.dart`, `app_user_model.dart`, `product_model.dart`.
- Two rep roles exist: `sales_rep` (team-scoped) and `brand_rep` (cross-team via `user_brand_access` table).
- Customers already have a `type` field with values: `General Trade`, `Modern Trade`, `Wholesale`, `HoReCa`, `Pharmacy`, `Other`. Pharmacy = "medical store."
- Customers have `acc_code_ja` and `acc_code_ma` — per-team billing-software account codes. Split billing infrastructure exists at data layer.
- Cross-team catalog sharing already works via `user_brand_access`. Organic India is in JA catalog only — no need to duplicate.
- Multi-team pattern: every Supabase query filters by `team_id`. Do not drop this.
- `CLAUDE.md` at project root documents architecture conventions. Read it before starting.

---

## Three features

1. **Post-export "Mark as Delivered" dialog** — completes the pending→delivered workflow after export, with smart partial-export handling.
2. **Dual-team export with per-customer Organic India routing** — always produces both JA and MA CSVs in one click, with admin control over where each customer's Organic India items are billed.
3. **Brand_rep order merging** — brand_rep orders merge per customer into single invoices; sales_rep orders stay per-order.

The features ship in order. Do not combine phases.

---

## Feature 1: Post-export "Mark as Delivered"

### Behavior

After the CSV download completes, show a dialog:

```
┌───────────────────────────────────────────────────────┐
│ Export Complete                                       │
├───────────────────────────────────────────────────────┤
│ Downloaded:                                           │
│   ✓ JA2204.xls — 34 orders                            │
│   ✓ MA2204.xls — 18 orders                            │
│                                                       │
│ Of these:                                             │
│   • 42 orders are FULLY exported (all line items      │
│     covered across JA and MA files).                  │
│   • 10 orders are PARTIALLY exported (waiting for     │
│     their remaining items to be billed in a future    │
│     export).                                          │
│                                                       │
│ Mark the 42 fully-exported orders as Delivered?       │
│ Partial orders will stay Pending and flip             │
│ automatically when their remaining items get          │
│ exported.                                             │
│                                                       │
│                   [ Cancel ]  [ Yes, mark Delivered ] │
└───────────────────────────────────────────────────────┘
```

### Core rule (do not weaken this)

**An order flips to `Delivered` only when every one of its line items has been written into some export file across all teams.** Partial exports never change status.

### How to track "fully exported"

Add column to `public.orders`:

```sql
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS exported_line_item_ids TEXT[] DEFAULT ARRAY[]::TEXT[];

CREATE INDEX IF NOT EXISTS idx_orders_exported_line_item_ids
  ON public.orders USING GIN (exported_line_item_ids);
```

Every time an export writes a line item (including merged-invoice lines — see Feature 3), append that `order_items.id` to the parent order's `exported_line_item_ids`. When the array length equals the order's total line item count, the order is "fully exported" and eligible for Delivered.

### Audit / undo: `export_batches` table

```sql
CREATE TABLE IF NOT EXISTS public.export_batches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  exported_by_user_id UUID,
  exported_by_name TEXT NOT NULL,
  exported_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  invoice_date DATE NOT NULL,
  ja_file_name TEXT,
  ma_file_name TEXT,
  ja_invoice_range TEXT,
  ma_invoice_range TEXT,
  status_filter TEXT,
  date_range_start DATE,
  date_range_end DATE,
  order_ids UUID[] NOT NULL,
  line_item_ids_written TEXT[] NOT NULL,
  orders_marked_delivered UUID[] DEFAULT ARRAY[]::UUID[],
  previous_statuses JSONB
);

CREATE INDEX IF NOT EXISTS idx_export_batches_exported_at
  ON public.export_batches(exported_at DESC);

ALTER TABLE public.export_batches ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins read export batches"
  ON public.export_batches FOR SELECT
  USING ((SELECT role FROM public.app_users WHERE id = auth.uid()) IN ('admin', 'super_admin'));

CREATE POLICY "Admins write export batches"
  ON public.export_batches FOR INSERT
  WITH CHECK ((SELECT role FROM public.app_users WHERE id = auth.uid()) IN ('admin', 'super_admin'));
```

`previous_statuses` is a JSONB map `{order_id: old_status}` for every order whose status was changed by this batch. Enables undo.

### Supabase RPC (atomic)

Wrap the batch update in a Postgres function. Do NOT do this as multiple client-side calls — a partial failure mid-update corrupts data.

```sql
CREATE OR REPLACE FUNCTION public.finalize_export_batch(
  p_order_ids UUID[],
  p_line_item_ids_written TEXT[],
  p_mark_delivered BOOLEAN,
  p_batch_metadata JSONB
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_batch_id UUID;
  v_fully_exported_order_ids UUID[];
  v_previous_statuses JSONB;
BEGIN
  -- 1. Append written line item IDs to each order's exported_line_item_ids.
  UPDATE public.orders o
  SET exported_line_item_ids = (
    SELECT ARRAY(SELECT DISTINCT unnest(o.exported_line_item_ids || p_line_item_ids_written))
  )
  WHERE o.id = ANY(p_order_ids);

  -- 2. Identify fully-exported orders (all line items now in the array).
  SELECT ARRAY_AGG(o.id) INTO v_fully_exported_order_ids
  FROM public.orders o
  WHERE o.id = ANY(p_order_ids)
    AND (
      SELECT COUNT(*) FROM public.order_items oi WHERE oi.order_id = o.id
    ) = (
      SELECT COUNT(*) FROM unnest(o.exported_line_item_ids) AS line_id
      WHERE line_id IN (SELECT id::TEXT FROM public.order_items WHERE order_id = o.id)
    );

  -- 3. If admin confirmed, flip status to Delivered and capture previous_statuses.
  IF p_mark_delivered AND v_fully_exported_order_ids IS NOT NULL THEN
    SELECT jsonb_object_agg(id::TEXT, status) INTO v_previous_statuses
    FROM public.orders
    WHERE id = ANY(v_fully_exported_order_ids);

    UPDATE public.orders
    SET status = 'Delivered'
    WHERE id = ANY(v_fully_exported_order_ids)
      AND status != 'Delivered';
  END IF;

  -- 4. Write the audit row.
  INSERT INTO public.export_batches (
    exported_by_user_id, exported_by_name, invoice_date,
    ja_file_name, ma_file_name, ja_invoice_range, ma_invoice_range,
    status_filter, date_range_start, date_range_end,
    order_ids, line_item_ids_written,
    orders_marked_delivered, previous_statuses
  )
  VALUES (
    auth.uid(),
    (SELECT full_name FROM public.app_users WHERE id = auth.uid()),
    (p_batch_metadata->>'invoice_date')::DATE,
    p_batch_metadata->>'ja_file_name',
    p_batch_metadata->>'ma_file_name',
    p_batch_metadata->>'ja_invoice_range',
    p_batch_metadata->>'ma_invoice_range',
    p_batch_metadata->>'status_filter',
    (p_batch_metadata->>'date_range_start')::DATE,
    (p_batch_metadata->>'date_range_end')::DATE,
    p_order_ids,
    p_line_item_ids_written,
    COALESCE(v_fully_exported_order_ids, ARRAY[]::UUID[]),
    COALESCE(v_previous_statuses, '{}'::JSONB)
  )
  RETURNING id INTO v_batch_id;

  RETURN v_batch_id;
END;
$$;
```

### Client-side flow

1. `_downloadCsv()` builds and triggers BOTH CSV downloads (see Feature 2).
2. Collects all `order_items.id` values written across both files.
3. Shows the post-export dialog.
4. On confirm, calls `supabase.rpc('finalize_export_batch', ...)` with `p_mark_delivered = true`.
5. On cancel, still calls the RPC with `p_mark_delivered = false` so the line item tracking is recorded even if the status change is declined.

### Undo (optional but recommended)

Add a "View Recent Exports" button in admin_orders_tab that lists the last 20 rows of `export_batches`. Each row has an "Undo" button that runs:

```sql
CREATE OR REPLACE FUNCTION public.undo_export_batch(p_batch_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_batch RECORD;
  v_order_id TEXT;
  v_prev_status TEXT;
BEGIN
  SELECT * INTO v_batch FROM public.export_batches WHERE id = p_batch_id;
  IF v_batch IS NULL THEN RAISE EXCEPTION 'Batch not found'; END IF;

  -- Restore previous statuses.
  FOR v_order_id, v_prev_status IN SELECT * FROM jsonb_each_text(v_batch.previous_statuses) LOOP
    UPDATE public.orders SET status = v_prev_status WHERE id = v_order_id::UUID;
  END LOOP;

  -- Remove the line item IDs we wrote from exported_line_item_ids.
  UPDATE public.orders
  SET exported_line_item_ids = ARRAY(
    SELECT unnest(exported_line_item_ids)
    EXCEPT SELECT unnest(v_batch.line_item_ids_written)
  )
  WHERE id = ANY(v_batch.order_ids);

  -- Mark the batch as undone (soft — keep the row for history).
  UPDATE public.export_batches
  SET orders_marked_delivered = ARRAY[]::UUID[],
      previous_statuses = '{}'::JSONB
  WHERE id = p_batch_id;
END;
$$;
```

Undo should require super_admin role. Add a permission check.

---

## Feature 2: Dual-team export with per-customer Organic India routing

### Behavior

The "Export" button runs ONE flow that produces BOTH `JA2204.xls` and `MA2204.xls`. Admin never picks a team first — the team filter no longer gates the export.

### Flow changes to existing 4-step wizard

Current: status → beats → invoice number → export date.
New: status → beats → **Organic India picker (new)** → **dual invoice numbers** → export date → team-skip checkboxes → summary → download.

### New Step 3: Organic India per-customer routing dialog

After the beat picker, BEFORE the invoice number step:

1. Query: of all orders currently in the export filter, which contain Organic India line items?
2. Group those orders by customer.
3. Show a dialog:

```
┌──────────────────────────────────────────────────────────┐
│ Organic India Billing                                    │
├──────────────────────────────────────────────────────────┤
│ Organic India items found for 7 customers.               │
│ Pick which team each customer bills under:               │
│                                                          │
│ Apollo Pharmacy          (Pharmacy)     [●JA]  [ MA]     │
│ Sharma General Store     (General)      [ JA]  [●MA]     │
│ MedPlus                  (Pharmacy)     [●JA]  [ MA]     │
│ Big Bazaar               (Modern Trade) [ JA]  [●MA]     │
│ Local Kirana             (General)      [ JA]  [●MA]     │
│ Wellness Forever         (Pharmacy)     [●JA]  [ MA]     │
│ Reliance Smart           (Modern Trade) [ JA]  [●MA]     │
│                                                          │
│ [ All Pharmacy → JA ]    [ Set all to MA ]               │
│                                                          │
│ ☑ Remember these choices for next time                   │
│                                                          │
│              [ Cancel ]          [ Continue ]            │
└──────────────────────────────────────────────────────────┘
```

### Default selection logic (priority order)

For each customer with Organic India items in the batch:

1. **Lookup `customer_brand_routing`** for that customer + brand `'Organic India'`. If a row exists, use it as the default.
2. **If no row exists**, fall back to type-based default:
   - `Pharmacy` → JA
   - Everything else → MA
3. **Admin can override any default** by tapping the other button.
4. **On Continue**, if "Remember these choices" is checked, upsert all selections into `customer_brand_routing`.

### New table: `customer_brand_routing`

```sql
CREATE TABLE IF NOT EXISTS public.customer_brand_routing (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  brand_name TEXT NOT NULL,
  billing_team_id TEXT NOT NULL CHECK (billing_team_id IN ('JA', 'MA')),
  set_by_user_id UUID,
  set_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (customer_id, brand_name)
);

CREATE INDEX IF NOT EXISTS idx_customer_brand_routing_lookup
  ON public.customer_brand_routing(customer_id, brand_name);

ALTER TABLE public.customer_brand_routing ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins manage routing"
  ON public.customer_brand_routing FOR ALL
  USING ((SELECT role FROM public.app_users WHERE id = auth.uid()) IN ('admin', 'super_admin'));
```

Brand name comes from `products.category` (existing field). Start with `'Organic India'` as the only triggering brand. If another brand needs this treatment later, it's a data change, not a code change — see "Future-proofing" below.

### Identifying Organic India items in an order

```dart
bool isOrganicIndiaItem(OrderItemModel item, Map<String, ProductModel> productMap) {
  final product = productMap[item.productId];
  return product?.category?.trim().toLowerCase() == 'organic india';
}
```

Use product category, not SKU prefix or name match. Category is the authoritative field.

### Modified Step 4: dual invoice numbers

Two text fields instead of one:

- JA starting invoice (e.g. `INV420`)
- MA starting invoice (e.g. `INVM100` — whatever MA's billing software uses)

Either can be left blank if that team is being skipped (see summary step).

### Summary step (replaces current cross-team warning)

```
┌─────────────────────────────────────────────────────────┐
│ Export Summary                                          │
├─────────────────────────────────────────────────────────┤
│ ☑ JA2204.xls                                            │
│     • 34 orders booked under JA                         │
│     • 5 cross-team orders from MA reps with JA products │
│     • 4 customers' Organic India items routed to JA     │
│     • Starting invoice: INV420                          │
│                                                         │
│ ☑ MA2204.xls                                            │
│     • 18 orders booked under MA                         │
│     • 2 cross-team orders from JA reps with MA products │
│     • 3 customers' Organic India items routed to MA     │
│     • Starting invoice: INVM100                         │
│                                                         │
│ Uncheck a box above to skip that team's export.         │
│                                                         │
│              [ Cancel ]         [ Export ]              │
└─────────────────────────────────────────────────────────┘
```

Unchecking a team skips building that file entirely. No line items from that team are marked as exported either (tracked in `exported_line_item_ids` per Feature 1).

### Build logic (core function signature)

Replace `_buildCsv()` with a new function that builds both files in parallel:

```dart
class ExportResult {
  final String? jaCsv;
  final String? maCsv;
  final String jaFileName;
  final String maFileName;
  final List<String> writtenLineItemIds; // across both files
  final List<String> allInvolvedOrderIds;
}

Future<ExportResult> _buildDualTeamCsvs({
  required List<OrderModel> candidateOrders, // all orders matching filters, both teams
  required Map<String, ProductModel> productsById, // products from BOTH teams
  required Map<String, String> userIdToRole, // to determine sales_rep vs brand_rep
  required Map<String, String> userIdToName,
  required Map<String, CustomerModel> customersById,
  required Map<String, String> organicIndiaRoutingDecisions, // customerId -> 'JA' | 'MA'
  required DateTime invoiceDate,
  required String? jaInvoicePrefix,
  required int? jaInvoiceStartNum,
  required String? maInvoicePrefix,
  required int? maInvoiceStartNum,
  required bool buildJa,
  required bool buildMa,
})
```

### Line item routing algorithm (exact logic)

For each order, for each line item:

```
Let itemTeam = determine which CSV this line item belongs to:

  IF line_item.category == 'Organic India':
    itemTeam = organicIndiaRoutingDecisions[order.customerId]
    // Must exist — we asked in Step 3. If missing, default to order.teamId.

  ELSE IF product.team_id == 'JA' OR (shared via user_brand_access for JA):
    itemTeam = 'JA'

  ELSE IF product.team_id == 'MA' OR (shared via user_brand_access for MA):
    itemTeam = 'MA'

  ELSE:
    itemTeam = order.teamId  // fallback, should be rare

Write this line item into the CSV for itemTeam (if buildJa/buildMa is on for that team).
Record line_item.id in writtenLineItemIds.
```

### Filename helper

```dart
String _teamExportFilename(String teamCode, DateTime invoiceDate) {
  final dd = invoiceDate.day.toString().padLeft(2, '0');
  final mm = invoiceDate.month.toString().padLeft(2, '0');
  return '$teamCode$dd$mm.xls';
}
```

### Future-proofing

The Organic India picker is hardcoded to the brand name `'Organic India'`. To support future brands without a code change:

- Add a `routing_required_brands` setting (single row in a new `app_settings` table, or reuse an existing config table).
- Admin toggles which brand categories require the picker.
- Export flow iterates over all configured brands and shows one picker dialog per brand (or one combined dialog grouped by brand).

**Do NOT build this now.** Ship with Organic India hardcoded. When the second brand appears, the owner can request the generalization as a follow-up.

---

## Feature 3: Brand_rep order merging

### Behavior

Within each team's CSV (JA and MA built independently), orders are grouped into invoices using different rules depending on the rep type:

- **sales_rep orders:** one invoice per order. Unchanged.
- **brand_rep orders:** all orders for the same customer within the export filter merge into ONE invoice.
- **Mixed customer (sales_rep + brand_rep):** sales_rep's order is its own invoice; brand_rep's orders merge among themselves into a second invoice. Two invoices for that customer in the CSV.

### Grouping algorithm

For each team's CSV:

```
1. Split the team's orders into two buckets:
     bucket_sales = [o for o in orders if userRole[o.userId] == 'sales_rep']
     bucket_brand = [o for o in orders if userRole[o.userId] == 'brand_rep']

2. Write bucket_sales to CSV: one invoice per order (current behavior).
   Invoice number increments per order.

3. Group bucket_brand by customer_id:
     grouped = {customer_id: [orders...]}

4. For each customer group in grouped:
     Allocate ONE invoice number (next in sequence).
     Collect all line items from all orders in the group.
     Write merged line items under the single invoice number (see "line item combining" below).

5. Invoice numbers assigned in deterministic order:
     - First all sales_rep orders sorted by order_date ascending, then order_id.
     - Then brand_rep groups sorted by customer_name ascending.
```

### Line item combining rule (Edge Case 2)

Within a brand_rep merged invoice:

```
For each (product_id, unit_price) pair across the grouped orders:
  IF multiple line items share the same product_id AND same unit_price:
    Combine: sum quantities, sum line_totals. Single row in CSV.
  ELSE (different prices for same product, or different products):
    Keep as separate rows within the merged invoice.
```

This preserves price-change history while cleaning up identical repeat rows. Invoice line count is thereby minimized without fiction.

### CSV column values for merged invoices

| Column | Value on merged brand_rep invoice |
|---|---|
| Invoice No | Single number for the whole merge |
| Order ID | Comma-separated list of source order IDs |
| Order Date | The invoice date admin picked in Step 4 (same rule as current code) |
| Customer Name | Customer name (single — grouping key) |
| Qty | Per-line quantity (after combining) |
| Rep Name | Fixed string: `Brand Rep` |
| Item Name | Billing name (unchanged logic) |
| MRP, Unit Price, Gross Amount | Unchanged per-line |
| Notes | All source orders' notes concatenated with `; ` separator, sanitized |

`Order ID` as a comma list is important: it lets you trace a merged invoice back to its source orders if a question arises. Keep it even if DUA Clipper only reads the first value.

### Line item ID tracking (for Feature 1 integration)

When a merged invoice writes a combined row (sum of e.g. 3 original line items), record ALL 3 source `order_items.id` values in `writtenLineItemIds`. Do NOT skip. Feature 1's "fully exported" check needs every source ID.

### Modified OrderModel access

Brand_rep detection needs role lookup. Extend the user name map to also hold role:

```dart
final userRoleMap = <String, String>{};
for (final u in users) {
  userNameMap[u.id] = u.fullName;
  userRoleMap[u.id] = u.role;
}
```

`u.role` already exists on `AppUserModel` — no model changes.

---

## Phase order & risk

Ship in this order. Each phase is independently deployable and testable.

### Phase A — DB migrations (zero code risk)

Files to create:
- `supabase_migration_orders_exported_tracking.sql`
- `supabase_migration_export_batches.sql`
- `supabase_migration_customer_brand_routing.sql`
- `supabase_migration_export_rpcs.sql` (the `finalize_export_batch` and `undo_export_batch` functions)

Run on staging first. Verify RLS policies work for both admin and super_admin test users. No app code changes yet — the existing export continues to work untouched.

### Phase B — Dual-team export (Feature 2, without per-customer picker)

Modify `admin_orders_tab.dart` to build BOTH JA and MA CSVs in one flow. Use the team-skip checkboxes. Skip the Organic India picker for now — default all Organic India items to their product's home team (which is JA today).

At end of Phase B, admin gets two files in one click, but Organic India routing is not yet per-customer. Ship. Use it for a week. Verify filenames, verify cross-team line item logic still works, verify both files open cleanly in DUA Clipper.

### Phase C — Organic India per-customer picker (Feature 2, full)

Add the Step 3 dialog. Add `customer_brand_routing` reads/writes. Test with:
- A customer who has never been routed before (should use Pharmacy → JA default).
- A customer who was routed last export (should default to last choice).
- A customer whose type changed since last routing (should still honor the remembered override).
- Admin overrides "Remember these choices" unchecked — verify no row is written.

Ship Phase C only when Phase B has been stable for at least a week.

### Phase D — Brand_rep order merging (Feature 3)

This is the highest-risk phase because it changes how invoices look, not just what data goes through. Test thoroughly in staging:
- Customer with 3 brand_rep orders, same product, same price → merged into one line with summed quantity.
- Customer with 3 brand_rep orders, same product, one different price → 2 lines in merged invoice.
- Customer with 1 sales_rep order + 2 brand_rep orders → 2 invoices in CSV (sales stays separate, brand merges).
- Customer with only 1 brand_rep order → single-order "merged" invoice (degenerates to current behavior, verify nothing breaks).
- Brand_rep Organic India order for Pharmacy customer → correctly routed to JA AND correctly merged.

### Phase E — Post-export "Mark as Delivered" dialog (Feature 1)

Wire the dialog after the dual-file download. Integrate the line item tracking (populated during build in Phases B-D, now consumed here). Ship.

### Phase F — Undo / recent exports UI (optional)

Add a small "Recent Exports" button near the Export button that opens a modal listing the last 20 `export_batches` rows. Super_admin-only undo buttons on each row. Skip if not needed; the RPC is already in place for later.

---

## Testing checklist (run before marking a phase done)

- [ ] Current single-team export still works identically when only JA or MA is checked.
- [ ] Filenames match `{TEAM}{DD}{MM}.xls` exactly. No year, no dashes.
- [ ] Invoice numbers auto-increment correctly within each file. They do NOT share a counter across JA and MA.
- [ ] Cross-team line item logic unchanged: JA rep selling Organic India to a General Trade customer → line item goes to MA file (per Organic India picker), not JA.
- [ ] Brand_rep merging preserves total amounts: sum of merged invoice lines == sum of source orders' line totals.
- [ ] Same-product same-price combining: quantities sum correctly, line total is quantity × unit_price exactly.
- [ ] Same-product different-price: produces TWO rows in the merged invoice, each with its original price.
- [ ] `exported_line_item_ids` array on orders contains every written line item ID after export.
- [ ] Post-export dialog correctly identifies fully-exported vs partial orders.
- [ ] "Cancel" on post-export dialog still writes the batch row and line item tracking (just doesn't flip statuses).
- [ ] Undo restores previous statuses exactly and removes the written line item IDs.
- [ ] Skipping a team via checkbox: that team's line items are NOT marked as exported.
- [ ] Organic India picker shows all customers with Organic India items in the batch. None missing, none duplicated.
- [ ] "Remember these choices" writes correct rows to `customer_brand_routing`. Unchecked = no writes.
- [ ] Admin without super_admin role cannot undo a batch.
- [ ] RLS policies: sales_rep / brand_rep users cannot read `export_batches` or `customer_brand_routing`.
- [ ] Offline: if network drops mid-export, partial writes don't corrupt `exported_line_item_ids`. The RPC is atomic — this should be automatic, but verify.

---

## Things NOT to do

- Do NOT hardcode "Pharmacy → JA" anywhere in the code. It's only a default in the picker dialog, and only when no `customer_brand_routing` row exists.
- Do NOT merge sales_rep orders under any circumstance. They are always one-invoice-per-order.
- Do NOT write to `exported_line_item_ids` client-side. Only the `finalize_export_batch` RPC writes that column.
- Do NOT change the existing CSV column structure. DUA Clipper import will break silently. If a new column is genuinely needed for merged invoices, add it at the END and verify DUA ignores unknown trailing columns.
- Do NOT skip the `team_id` filter on any new Supabase query you add.
- Do NOT bypass `OfflineService` for any new mutation. The `finalize_export_batch` RPC is server-side so this is not an issue, but any new client-side writes must go through it.
- Do NOT remove or "refactor" existing cross-team SKU pickup logic. It works. Feature 2 extends it; it does not replace it.
- Do NOT add a "merge sales_rep orders too" option. The owner explicitly rejected this.
- Do NOT change the Rep Name literal from `Brand Rep` without asking. It was a specific decision.

---

## Handing this to Claude Code

Save this file as `ORDERS_EXPORT_OVERHAUL_PLAN.md` in your project root (next to `CLAUDE.md`). Commit it. Then in Claude Code, say:

> "Read ORDERS_EXPORT_OVERHAUL_PLAN.md. Start with Phase A only — the database migrations. Do not touch any Dart code in this session. Show me the SQL files before applying them."

Then review, apply, and move to Phase B in the next session. One phase per session.

After each phase ships to production and is stable for several days, start the next phase. Do not let Claude Code (or any other tool) skip phases or combine them.

---

## Open questions / follow-ups (not blocking)

These came up during spec but were deferred. Track them for after the main overhaul ships:

- **Brand_rep commission tracking:** the owner confirmed brand_reps are salaried so `Brand Rep` as a fixed rep name is fine. If this changes (i.e. brand_reps become commission-based), the merging logic will need a rep-name strategy. Current rep names on source orders are preserved in `export_batches.order_ids`, so reconstruction is possible but cumbersome.
- **Secondary brands needing per-customer routing:** generalize the picker when a second brand (e.g. Patanjali, Himalaya) needs similar treatment. See "Future-proofing" in Feature 2.
- **Partial-order visibility in the UI:** admins might want a filter in the Orders tab to see "orders with partial exports" (neither Pending nor Delivered, but some line items exported). Currently these stay Pending. A new indicator column or filter chip would help. Defer.
- **Excel .xlsx output:** the current `.xls` file is actually tab-separated text. A real `.xlsx` would allow formatting, formulas, multi-sheet. Only worth doing if DUA Clipper accepts .xlsx. Verify first.
