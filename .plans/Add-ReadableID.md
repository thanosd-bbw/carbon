# Auto-Assign Manufactured Serial Readable IDs at Job Receipt

## Summary
Add an opt-in production setting that assigns `trackedEntity.readableId` automatically when a serial-tracked manufactured part is received into inventory via job completion. The generated format will be `PREFIXNNN`, where `PREFIX` is configured on the part definition and `NNN` is a zero-padded integer with a minimum width of 3. The assignment happens inside the job inventory receipt path so receipt + serial registration remain one backend step; no separate serial-entry step is introduced.

## Key Changes
### Data model and DB logic
- Add `companySettings.autoAssignManufacturedSerialReadableIdsOnReceipt BOOLEAN NOT NULL DEFAULT false`.
- Add `part.serialReadableIdPrefix TEXT NULL` and `part.nextSerialReadableIdNumber INTEGER NULL`.
- Add a partial unique index on `part(companyId, serialReadableIdPrefix)` where the prefix is not null, so a prefix belongs to only one part family in a company.
- Store the prefix on `part`, not `item`, so all revisions of the same part family share one prefix/counter.
- Add a DB allocator function, e.g. `allocate_part_serial_readable_ids(item_id, company_id, count)`, that:
  - resolves the part family from the item revision,
  - locks the part row,
  - computes the effective next number as `max(saved_next, highest_existing_suffix + 1, 1)`,
  - returns `count` new IDs in order,
  - updates `nextSerialReadableIdNumber` atomically.
- When the prefix changes, clear `nextSerialReadableIdNumber` back to `NULL` so the next allocation re-seeds from existing tracked entities that already use the new prefix.
- Extend the current part detail/query layer so part summary/detail payloads include the new prefix field.

### ERP settings and part definition UI
- Add a new boolean to Production Settings in ERP for “Auto-assign manufactured serial readable IDs on receipt”.
- Extend part create/edit validation to accept `serialReadableIdPrefix`.
- Expose the prefix in part definition flows:
  - new part form,
  - part details edit flow,
  - part properties/sidebar if that route is expected to be the main inline editing path.
- Validate and normalize the prefix before save:
  - normalize to uppercase,
  - allow letters, digits, `-`, and `_`,
  - reject whitespace and empty-string values,
  - enforce uniqueness through both UI validation and DB constraint handling.
- Show helper text that the prefix is used only for auto-generated readable IDs on serial-tracked manufactured parts.

### Receipt-time assignment behavior
- Update `jobCompleteInventory` in the `issue` function to check the company setting and apply the feature only when:
  - the completed job item is a `Part`,
  - the job make method requires serial tracking,
  - the setting is enabled.
- In that path, limit processing to the tracked entities actually being received now:
  - use serial-tracked entities for the job make method,
  - require `status = 'Available'`,
  - exclude any entity already received to inventory via existing `itemLedger` history,
  - preserve deterministic ordering by `createdAt`.
- For each entity in the receipt set:
  - if `readableId` is already populated, keep it,
  - if `readableId` is blank, allocate the next generated ID and write it before inserting the receipt ledger entry.
- If the setting is enabled but the part has no prefix, fail the receipt transaction with a user-facing error and do not partially complete the job.
- Leave behavior unchanged when the setting is off, or for batch/non-serial jobs.

## Public Interfaces / Types
- `companySettings.autoAssignManufacturedSerialReadableIdsOnReceipt: boolean`
- `part.serialReadableIdPrefix: string | null`
- `part.nextSerialReadableIdNumber: number | null`
- New DB allocator function for atomic multi-ID reservation during receipt.
- Part validators / loaders / detail RPC output updated to include `serialReadableIdPrefix`.

## Test Plan
- Setting off: serial-tracked job receipt behaves exactly as today and does not auto-fill readable IDs.
- Setting on + serial-tracked part + valid prefix: receipt assigns readable IDs in order and inserts inventory ledger successfully.
- Missing prefix with setting on: receipt is blocked and no job/ledger/tracked-entity partial updates persist.
- Existing readable IDs on some tracked entities: only blank ones are auto-assigned.
- Existing historical IDs across part revisions: next number starts after the highest matching suffix already present for that part family and prefix.
- Prefix change after prior usage: existing tracked entities keep old IDs; next allocation uses the new prefix and seeds from the highest existing value for that new prefix.
- Counter growth past `999`: output becomes `PREFIX1000` rather than failing.
- Concurrent receipts for the same part family: allocated IDs remain unique and ordered with no collisions.

## Assumptions
- v1 applies only to manufactured `Part` jobs; `Tool`, `Material`, and other item families are unchanged.
- The numeric portion is minimum-width 3, not fixed-width 3 forever.
- Prefix input allows uppercase letters, digits, `-`, and `_`; lowercase input is normalized to uppercase.
- This plan changes the receipt-time backend boundary; it does not add a brand-new MES job-closeout screen. Any MES closeout flow that calls the same receipt path will get the behavior automatically.


==

closeout 

--

Implemented a part-level readable ID mode that matches the flow you described.

Parts can now opt into retaining the upstream readable ID from a consumed tracked entity via the part definition UI in [PartForm.tsx](./carbon/apps/erp/app/modules/items/ui/Parts/PartForm.tsx) and [PartProperties.tsx](./carbon/apps/erp/app/modules/items/ui/Parts/PartProperties.tsx). The new flag is stored on `part` in [20260327203000_part-readable-id-retention.sql](./carbon/packages/database/supabase/migrations/20260327203000_part-readable-id-retention.sql), wired through validation/service/update paths in [items.models.ts](./carbon/apps/erp/app/modules/items/items.models.ts), [items.service.ts](./carbon/apps/erp/app/modules/items/items.service.ts), and [update.tsx](./carbon/apps/erp/app/routes/x+/items+/update.tsx).

The backend behavior is in [issue/index.ts](./carbon/packages/database/supabase/functions/issue/index.ts). If the produced part is set to retain upstream IDs, tracked consumption now copies the consumed tracked entity’s `readableId` onto the parent output entity and prevents mixing multiple different readable IDs into one retained-ID output. On unconsume, that retained ID is cleared back off the parent. At receipt, retained-ID parts must already have a readable ID and will not auto-generate one; generate-mode parts still use the prefix/counter logic you asked for earlier. Auto-generated increments still stay unique and never get reissued because allocation is based on historical tracked-entity usage, including consumed/scrapped parts.

I also migrated the local DB, regenerated Supabase types in [types.ts](./carbon/packages/database/src/types.ts) and [types.ts](./carbon/packages/database/supabase/functions/lib/types.ts), and ran a targeted Biome check on the touched files. I did not run the ERP-scoped TypeScript check because you declined that command.