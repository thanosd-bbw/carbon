import { assertIsPost, error } from "@carbon/auth";
import { requirePermissions } from "@carbon/auth/auth.server";
import { flash } from "@carbon/auth/session.server";
import type { ActionFunctionArgs } from "react-router";
import { data } from "react-router";
import { isJobLocked } from "~/modules/production";
import { updateJobBatchNumber } from "~/modules/production/production.service";

export async function action({ request, params }: ActionFunctionArgs) {
  assertIsPost(request);
  const { client } = await requirePermissions(request, {
    update: "production",
    bypassRls: true
  });

  const { jobId } = params;
  if (!jobId) throw new Error("Could not find jobId");
  const formData = await request.formData();
  const trackedEntityId = String(formData.get("id"));
  const value = String(formData.get("value"));
  if (!value) throw new Error("Could not find value");

  const job = await client
    .from("job")
    .select("status")
    .eq("id", jobId)
    .single();

  if (job.error) {
    return data(
      job,
      await flash(request, error(job.error, "Failed to load job"))
    );
  }

  if (isJobLocked(job.data?.status)) {
    return data(
      {
        error: {
          message:
            "Completed and cancelled jobs cannot edit human-readable IDs from the job sidebar."
        }
      },
      await flash(
        request,
        error(
          null,
          "Completed and cancelled jobs cannot edit human-readable IDs from the job sidebar."
        )
      )
    );
  }

  const update = await updateJobBatchNumber(client, trackedEntityId, value);

  if (update.error) {
    return data(
      update,
      await flash(request, error(update.error, update.error.message))
    );
  }

  return update;
}
