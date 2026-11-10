"""Register a job once. Requires TABLE_NAME environment variable."""
import os
from datetime import datetime, timezone
import boto3
from botocore.exceptions import ClientError

TABLE = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])


def handler(event, context):
    job_id = str(event.get("jobId", "")).strip()
    if not job_id:
        raise ValueError("Input must contain a non-empty jobId")

    now = datetime.now(timezone.utc).isoformat()
    try:
        TABLE.put_item(
            Item={"idempotencyKey": job_id, "status": "IN_PROGRESS", "createdAt": now, "updatedAt": now},
            ConditionExpression="attribute_not_exists(idempotencyKey)",
        )
        return {**event, "duplicate": False, "status": "IN_PROGRESS"}
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
            raise
        existing = TABLE.get_item(Key={"idempotencyKey": job_id}, ConsistentRead=True).get("Item", {})
        return {
            **event,
            "duplicate": True,
            "status": existing.get("status", "UNKNOWN"),
        }
