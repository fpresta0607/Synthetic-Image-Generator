import os, time, json, base64, threading, requests, tempfile, glob, shutil
import boto3
from botocore.config import Config
from http import HTTPStatus

REGION = os.environ.get("AWS_REGION", "us-east-1")
DATASETS_BUCKET = os.environ["DATASETS_BUCKET"]
OUTPUTS_BUCKET  = os.environ["OUTPUTS_BUCKET"]
MODELS_BUCKET   = os.environ["MODELS_BUCKET"]
JOBS_TABLE      = os.environ["JOBS_TABLE"]
JOBS_QUEUE_URL  = os.environ["JOBS_QUEUE_URL"]
SAM_CHECKPOINT  = os.environ.get("SAM_CHECKPOINT", "/app/py/models/sam_vit_b.pth")

s3  = boto3.client("s3", region_name=REGION, config=Config(retries={'max_attempts': 5}))
sqs = boto3.client("sqs", region_name=REGION)
ddb = boto3.resource("dynamodb", region_name=REGION).Table(JOBS_TABLE)

def ensure_model():
    if not os.path.exists(SAM_CHECKPOINT):
        os.makedirs(os.path.dirname(SAM_CHECKPOINT), exist_ok=True)
        print("[worker] downloading SAM model from S3...")
        # Key could be parameterized; default to sam_vit_b.pth
        s3.download_file(MODELS_BUCKET, "sam_vit_b.pth", SAM_CHECKPOINT)

def start_backend():
    from app import app  # reuse existing Flask app
    def run():
        app.run(host="127.0.0.1", port=5001, debug=False, use_reloader=False)
    t = threading.Thread(target=run, daemon=True)
    t.start()
    for _ in range(60):
        try:
            r = requests.get("http://127.0.0.1:5001/health", timeout=1.5)
            if r.status_code == 200:
                print("[worker] backend ready")
                return
        except Exception:
            pass
        time.sleep(1)
    raise RuntimeError("Backend failed to start inside worker")

def update_job(job_id: str, **attrs):
    expr = "SET " + ", ".join(f"{k}=:{k}" for k in attrs)
    ddb.update_item(
        Key={"job_id": job_id},
        UpdateExpression=expr,
        ExpressionAttributeValues={f":{k}": v for k, v in attrs.items()}
    )

def handle_job(msg):
    body = json.loads(msg["Body"])
    job_id = body["job_id"]
    dataset_prefix = body["dataset_prefix"]
    output_prefix  = body["output_prefix"]
    templates = body.get("templates", [])
    edits = body.get("edits", {})

    workdir = tempfile.mkdtemp(prefix=f"job-{job_id}-")
    in_dir  = os.path.join(workdir, "in")
    out_dir = os.path.join(workdir, "out")
    os.makedirs(in_dir, exist_ok=True); os.makedirs(out_dir, exist_ok=True)

    print(f"[worker] downloading dataset: {dataset_prefix}")
    resp = s3.list_objects_v2(Bucket=DATASETS_BUCKET, Prefix=dataset_prefix)
    keys = [o["Key"] for o in resp.get("Contents", []) if o["Key"].lower().endswith((".jpg",".jpeg",".png",".bmp",".webp"))]
    for k in keys:
        fn = os.path.join(in_dir, os.path.basename(k))
        s3.download_file(DATASETS_BUCKET, k, fn)

    if not keys:
        update_job(job_id, status="failed", error="no images", updated_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        return

    # Init dataset
    files = [("images", (os.path.basename(p), open(p,'rb'))) for p in glob.glob(os.path.join(in_dir, "*"))]
    try:
        r = requests.post("http://127.0.0.1:5001/sam/dataset/init", files=files, timeout=120)
    finally:
        for _,fh in files: fh[1].close()
    if r.status_code != HTTPStatus.OK:
        update_job(job_id, status="failed", error=f"init {r.text}", updated_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        return
    dataset_id = r.json()["dataset_id"]

    # Save templates
    for t in templates:
        payload = {
            "dataset_id": dataset_id,
            "image_filename": t["image_filename"],
            "points": t["points"],
            "name": t.get("name")
        }
        try:
            requests.post("http://127.0.0.1:5001/sam/dataset/template/save", json=payload, timeout=30)
        except Exception:
            pass

    # Precompute removed: embeddings generated lazily per image

    # Build apply payload
    templ_payload = []
    for t in templates:
        # If template_id is not known (fresh), backend enumerates; we skip until we can fetch templates list if needed
        templ_payload.append({"template_id": t.get("template_id"), "edits": t.get("edits", edits)})
    apply_payload = {"dataset_id": dataset_id, "templates": templ_payload}

    processed = 0
    try:
        with requests.post("http://127.0.0.1:5001/sam/dataset/apply_stream", json=apply_payload, stream=True, timeout=3600) as resp:
            for line in resp.iter_lines():
                if not line or not line.startswith(b"data:"): continue
                event = json.loads(line[5:])
                fn = event["filename"]
                b64 = event["variant_png"]
                out_path = os.path.join(out_dir, fn)
                with open(out_path, "wb") as f:
                    f.write(base64.b64decode(b64))
                s3.upload_file(out_path, OUTPUTS_BUCKET, f"{output_prefix}{fn}")
                processed += 1
                update_job(job_id, status="processing", progress=processed, updated_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    except Exception as e:
        update_job(job_id, status="failed", error=str(e), updated_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        return

    update_job(job_id, status="succeeded", updated_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    try:
        shutil.rmtree(workdir, ignore_errors=True)
    except Exception:
        pass

def main():
    ensure_model()
    start_backend()
    while True:
        resp = sqs.receive_message(QueueUrl=JOBS_QUEUE_URL, MaxNumberOfMessages=1, WaitTimeSeconds=20, VisibilityTimeout=3600)
        msgs = resp.get("Messages", [])
        if not msgs:
            time.sleep(2); continue
        for m in msgs:
            try:
                handle_job(m)
                sqs.delete_message(QueueUrl=JOBS_QUEUE_URL, ReceiptHandle=m["ReceiptHandle"])
            except Exception as e:
                print("[worker] job failed:", e)

if __name__ == "__main__":
    main()
