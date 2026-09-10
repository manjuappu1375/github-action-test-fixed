import json
import os


def handler(event, context):
    print("Received event:", json.dumps(event))
    queue_url = os.environ.get("QUEUE_URL", "")
    for record in event.get("Records", []):
        print("Processing message body:", record.get("body"))
    return {"statusCode": 200, "queueUrl": queue_url}
