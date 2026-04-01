CREATE OR REPLACE FUNCTION validate_human_readable_id_prefix_conflicts()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_prefix TEXT;
  v_conflicting_readable_id TEXT;
BEGIN
  v_prefix := NULLIF(btrim(NEW."serialReadableIdPrefix"), '');

  IF v_prefix IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT te."readableId"
  INTO v_conflicting_readable_id
  FROM "trackedEntity" te
  LEFT JOIN "item" i
    ON i.id = te."sourceDocumentId"
  WHERE te."companyId" = NEW."companyId"
    AND te."readableId" IS NOT NULL
    AND left(te."readableId", char_length(v_prefix)) = v_prefix
    AND substring(te."readableId" FROM char_length(v_prefix) + 1) ~ '^[0-9]+$'
    AND COALESCE(i."readableId", '') <> NEW."id"
  LIMIT 1;

  IF v_conflicting_readable_id IS NOT NULL THEN
    RAISE EXCEPTION
      'Human Readable ID Prefix conflicts with existing human-readable IDs already used elsewhere in this company.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "part_validate_human_readable_id_prefix_trigger" ON "part";
CREATE TRIGGER "part_validate_human_readable_id_prefix_trigger"
BEFORE INSERT OR UPDATE OF "serialReadableIdPrefix", "companyId", "id"
ON "part"
FOR EACH ROW
EXECUTE FUNCTION validate_human_readable_id_prefix_conflicts();

CREATE OR REPLACE FUNCTION allocate_part_serial_readable_ids(
  p_item_id TEXT,
  p_company_id TEXT,
  p_count INTEGER
)
RETURNS TABLE ("readableId" TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_part_id TEXT;
  v_prefix TEXT;
  v_saved_next INTEGER;
  v_effective_next INTEGER;
  v_max_existing INTEGER;
  v_index INTEGER;
BEGIN
  IF p_count IS NULL OR p_count < 1 THEN
    RAISE EXCEPTION 'Count must be at least 1';
  END IF;

  SELECT i."readableId"
  INTO v_part_id
  FROM "item" i
  WHERE i.id = p_item_id
    AND i."companyId" = p_company_id
    AND i."type" = 'Part';

  IF v_part_id IS NULL THEN
    RAISE EXCEPTION 'Part item % not found for company %', p_item_id, p_company_id;
  END IF;

  SELECT
    p."serialReadableIdPrefix",
    p."nextSerialReadableIdNumber"
  INTO
    v_prefix,
    v_saved_next
  FROM "part" p
  WHERE p.id = v_part_id
    AND p."companyId" = p_company_id
  FOR UPDATE;

  IF v_prefix IS NULL OR btrim(v_prefix) = '' THEN
    RAISE EXCEPTION 'Part % is missing a Human Readable ID Prefix', v_part_id;
  END IF;

  SELECT MAX((substring(te."readableId" FROM char_length(v_prefix) + 1))::INTEGER)
  INTO v_max_existing
  FROM "trackedEntity" te
  INNER JOIN "item" i
    ON i.id = te."sourceDocumentId"
  WHERE te."companyId" = p_company_id
    AND i."companyId" = p_company_id
    AND i."type" = 'Part'
    AND i."readableId" = v_part_id
    AND te."readableId" IS NOT NULL
    AND left(te."readableId", char_length(v_prefix)) = v_prefix
    AND substring(te."readableId" FROM char_length(v_prefix) + 1) ~ '^[0-9]+$';

  v_effective_next := GREATEST(
    COALESCE(v_saved_next, 1),
    COALESCE(v_max_existing, 0) + 1,
    1
  );

  UPDATE "part"
  SET
    "nextSerialReadableIdNumber" = v_effective_next + p_count,
    "updatedAt" = NOW(),
    "updatedBy" = COALESCE(auth.uid()::TEXT, 'system')
  WHERE id = v_part_id
    AND "companyId" = p_company_id;

  FOR v_index IN 0..(p_count - 1) LOOP
    "readableId" := v_prefix || lpad((v_effective_next + v_index)::TEXT, 3, '0');
    RETURN NEXT;
  END LOOP;
END;
$$;
