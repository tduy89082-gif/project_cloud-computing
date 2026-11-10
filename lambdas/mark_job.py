"""Update the job state. Requires TABLE_NAME environment variable."""
import os
from datetime import datetime, timezone
import boto3
from botocore.exceptions import ClientError

TABLE = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])


def handler(event, context):
    job_id = str(event.get("jobId", "")).strip()
    status = str(event.get("status", "")).strip().upper()
    if not job_id or status not in {"SUCCEEDED", "FAILED"}:
        raise ValueError("Expected jobId and status SUCCEEDED or FAILED")

    values = {":status": status, ":updated": datetime.now(timezone.utc).isoformat()}
    update = "SET #s = :status, updatedAt = :updated"
    names = {"#s": "status"}
    if event.get("error"):
        values[":error"] = str(event["error"])[:1000]
        update += ", errorMessage = :error"
    try:
        TABLE.update_item(
            Key={"idempotencyKey": job_id},
            UpdateExpression=update,
            ExpressionAttributeNames=names,
            ExpressionAttributeValues=values,
            ConditionExpression="attribute_exists(idempotencyKey)",
        )
    except ClientError:
        raise
    return {"jobId": job_id, "status": status}
