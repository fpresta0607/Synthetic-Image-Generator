from flask import Flask, jsonify
app = Flask(__name__)

@app.get("/api/backend/health")
def health():
    return jsonify(status="bootstrap-ok"), 200

# Provide a catch-all root so manual ALB tests also succeed
@app.get("/")
def root():
    return "OK", 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=3000)
