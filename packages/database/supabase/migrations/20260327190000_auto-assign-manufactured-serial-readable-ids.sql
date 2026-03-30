ALTER TABLE "companySettings"
ADD COLUMN "autoAssignManufacturedSerialReadableIdsOnReceipt" BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE "part"
ADD COLUMN "serialReadableIdPrefix" TEXT,
ADD COLUMN "nextSerialReadableIdNumber" INTEGER;

ALTER TABLE "part"
ADD CONSTRAINT "part_serialReadableIdPrefix_format_check"
CHECK (
  "serialReadableIdPrefix" IS NULL OR
  "serialReadableIdPrefix" ~ '^[A-Z0-9_-]+$'
);

ALTER TABLE "part"
ADD CONSTRAINT "part_nextSerialReadableIdNumber_check"
CHECK (
  "nextSerialReadableIdNumber" IS NULL OR
  "nextSerialReadableIdNumber" >= 1
);

CREATE UNIQUE INDEX "part_serialReadableIdPrefix_companyId_unique"
ON "part" ("companyId", "serialReadableIdPrefix")
WHERE "serialReadableIdPrefix" IS NOT NULL;

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
    RAISE EXCEPTION 'Part % is missing a serial readable ID prefix', v_part_id;
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

DROP FUNCTION IF EXISTS get_part_details;
CREATE OR REPLACE FUNCTION get_part_details(item_id TEXT)
RETURNS TABLE (
    "active" BOOLEAN,
    "assignee" TEXT,
    "defaultMethodType" "methodType",
    "description" TEXT,
    "itemTrackingType" "itemTrackingType",
    "name" TEXT,
    "replenishmentSystem" "itemReplenishmentSystem",
    "unitOfMeasureCode" TEXT,
    "notes" JSONB,
    "thumbnailPath" TEXT,
    "modelId" TEXT,
    "modelPath" TEXT,
    "modelName" TEXT,
    "modelSize" BIGINT,
    "id" TEXT,
    "companyId" TEXT,
    "unitOfMeasure" TEXT,
    "readableId" TEXT,
    "revision" TEXT,
    "readableIdWithRevision" TEXT,
    "serialReadableIdPrefix" TEXT,
    "nextSerialReadableIdNumber" INTEGER,
    "revisions" JSON,
    "customFields" JSONB,
    "tags" TEXT[],
    "itemPostingGroupId" TEXT,
    "createdBy" TEXT,
    "createdAt" TIMESTAMP WITH TIME ZONE,
    "updatedBy" TEXT,
    "updatedAt" TIMESTAMP WITH TIME ZONE
) AS $$
DECLARE
  v_readable_id TEXT;
  v_company_id TEXT;
BEGIN
  SELECT i."readableId", i."companyId" INTO v_readable_id, v_company_id
  FROM "item" i
  WHERE i.id = item_id;

  RETURN QUERY
  WITH item_revisions AS (
    SELECT
      json_agg(
        json_build_object(
          'id', i.id,
          'revision', i."revision",
          'methodType', i."defaultMethodType",
          'type', i."type"
        ) ORDER BY
          i."createdAt" DESC
      ) AS "revisions"
    FROM "item" i
    WHERE i."readableId" = v_readable_id
      AND i."companyId" = v_company_id
  )
  SELECT
    i."active",
    i."assignee",
    i."defaultMethodType",
    i."description",
    i."itemTrackingType",
    i."name",
    i."replenishmentSystem",
    i."unitOfMeasureCode",
    i."notes",
    CASE
      WHEN i."thumbnailPath" IS NULL AND mu."thumbnailPath" IS NOT NULL THEN mu."thumbnailPath"
      ELSE i."thumbnailPath"
    END AS "thumbnailPath",
    mu.id AS "modelId",
    mu."modelPath",
    mu."name" AS "modelName",
    mu."size" AS "modelSize",
    i."id",
    i."companyId",
    uom.name AS "unitOfMeasure",
    i."readableId",
    i."revision",
    i."readableIdWithRevision",
    p."serialReadableIdPrefix",
    p."nextSerialReadableIdNumber",
    ir."revisions",
    p."customFields",
    p."tags",
    ic."itemPostingGroupId",
    i."createdBy",
    i."createdAt",
    i."updatedBy",
    i."updatedAt"
  FROM "part" p
  LEFT JOIN "item" i ON i."readableId" = p."id" AND i."companyId" = p."companyId"
  LEFT JOIN item_revisions ir ON true
  LEFT JOIN (
    SELECT
      ps."itemId",
      string_agg(ps."supplierPartId", ',') AS "supplierIds"
    FROM "supplierPart" ps
    GROUP BY ps."itemId"
  ) ps ON ps."itemId" = i.id
  LEFT JOIN "modelUpload" mu ON mu.id = i."modelUploadId"
  LEFT JOIN "unitOfMeasure" uom ON uom.code = i."unitOfMeasureCode" AND uom."companyId" = i."companyId"
  LEFT JOIN "itemCost" ic ON ic."itemId" = i.id
  WHERE i."id" = item_id;
END;
$$ LANGUAGE plpgsql;
