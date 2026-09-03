"""Publish a Security Hub finding event to SNS, then set Workflow.Status = NOTIFIED.

Used as the single EventBridge target so that the status update happens only
after the notification was accepted by SNS (independent targets on one rule
give no ordering guarantee). The SNS message body is the EventBridge event
itself, which is what a direct EventBridge -> SNS target would deliver, so
Amazon Q Developer in chat applications renders it unchanged.

Security Hub emits "Findings - Imported" on every update; without the status
change a finding that stays FAILED is re-notified on every re-evaluation.
NOTIFIED is reset to NEW when compliance goes PASSED -> FAILED again, so
recurrences are still notified. The update emits one more Imported event with
status NOTIFIED, which the rules ignore.

Delivery semantics: the function raises only if the SNS publish itself fails,
i.e. before any side effect, so Lambda's asynchronous retries cannot duplicate a
notification. A failed status update is logged, not retried (retrying would
publish again). EventBridge itself delivers at least once; a rare duplicate
invocation therefore produces a duplicate notification, as a direct SNS target
would.
"""
import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TOPIC_ARN = os.environ["TOPIC_ARN"]
sns = boto3.client("sns")
securityhub = boto3.client("securityhub")


def handler(event, _context):
    findings = event.get("detail", {}).get("findings", [])
    if not findings:
        return {"published": False, "updated": 0}

    # 1. Notify. A failure here raises, so Lambda retries and finally dead-letters
    #    the event without marking anything.
    sns.publish(TopicArn=TOPIC_ARN, Message=json.dumps(event))

    # 2. Mark. Repeating this for the same finding is harmless (same value).
    identifiers = [
        {"Id": f["Id"], "ProductArn": f["ProductArn"]}
        for f in findings
        if f.get("Workflow", {}).get("Status") == "NEW"
    ]
    updated = 0
    for i in range(0, len(identifiers), 100):  # API limit per call
        try:
            resp = securityhub.batch_update_findings(
                FindingIdentifiers=identifiers[i : i + 100],
                Workflow={"Status": "NOTIFIED"},
            )
        except Exception:  # noqa: BLE001 - never raise after the publish (see module docstring)
            logger.exception("BatchUpdateFindings failed; findings stay NEW and will be re-notified")
            continue
        updated += len(resp.get("ProcessedFindings", []))
        for u in resp.get("UnprocessedFindings", []):
            logger.warning("not marked NOTIFIED: %s (%s)", u.get("FindingIdentifier", {}).get("Id"), u.get("ErrorMessage"))
    return {"published": True, "updated": updated}
