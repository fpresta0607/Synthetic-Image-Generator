from flask import Flask
app = Flask(__name__)

@app.get("/")
def root():
    return "OK", 200

@app.get("/api/backend/health")
def health():
    return "OK", 200

if __name__ == "__main__":
    # No debug mode; keep it minimal
    app.run(host="0.0.0.0", port=3000)
