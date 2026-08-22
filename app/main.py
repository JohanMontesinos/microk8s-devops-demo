import os
import socket

import psycopg2
from flask import Flask, render_template

app = Flask(__name__)

DB_HOST = os.environ.get("DB_HOST", "postgres-service")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "appdb")
DB_USER = os.environ.get("DB_USER", "appuser")
DB_PASS = os.environ.get("DB_PASS", "apppassword")

POD_NAME = os.environ.get("POD_NAME", socket.gethostname())
NODE_NAME = os.environ.get("NODE_NAME", "unknown")


def get_db_status():
    """Try a lightweight DB round-trip; return status string."""
    try:
        conn = psycopg2.connect(
            host=DB_HOST,
            port=DB_PORT,
            dbname=DB_NAME,
            user=DB_USER,
            password=DB_PASS,
            connect_timeout=3,
        )
        with conn.cursor() as cur:
            cur.execute("SELECT version();")
            version = cur.fetchone()[0].split(",")[0]
        conn.close()
        return f"OK — {version}"
    except Exception as exc:
        return f"ERROR — {exc}"


@app.route("/")
def index():
    return render_template(
        "index.html",
        pod_name=POD_NAME,
        node_name=NODE_NAME,
        db_status=get_db_status(),
    )


""" @app.route("/healthz")
def healthz():
    # Liveness probe — always returns 200 if process is alive
    return "ok", 200 """


@app.route("/healthz")
def healthz():
    return {"status": "ok", "pod": os.environ.get("HOSTNAME", "unknown")}, 200


if __name__ == "__main__":
    # Development only; production uses gunicorn (see Dockerfile CMD)
    app.run(host="0.0.0.0", port=5000, debug=False)
# Sun Agosto 18 20:05:00 -04 2026
