"""
orders-service
Owns the `orders` schema in PostgreSQL. Verifies JWTs locally using the
same SHARED_SECRET as auth-service (no network call needed to authenticate).

For every order line item it calls catalog-service over HTTP to confirm the
product exists, to use its authoritative current price (never trusts a price
sent by the client), and to decrement stock — this is the cross-service call
students should study and reproduce for other features. Cancelling an order
restores stock the same way.

Run standalone (development server; containers run gunicorn instead):
    python -m venv venv && source venv/bin/activate
    pip install -r requirements.txt
    python app.py
Listens on :5003. Requires catalog-service running (default http://localhost:5002).
"""
import os
import time
import datetime
import json

import jwt
import requests
import psycopg2
from psycopg2 import sql
from psycopg2.extras import RealDictCursor
from flask import Flask, jsonify, request

app = Flask(__name__)

# No default: a connection string is environment-specific and embedding one
# here would either hardcode an endpoint or commit a credential.
DATABASE_URL = os.environ.get("DATABASE_URL")
DB_SCHEMA = os.environ.get("DB_SCHEMA", "orders")
INIT_LOCK_KEY = 4711003

SHARED_SECRET = os.environ.get("SHARED_SECRET", "dev-shared-secret-change-me")
CATALOG_SERVICE_URL = os.environ.get("CATALOG_SERVICE_URL", "http://localhost:5002")
CORS_ALLOWED_ORIGIN = os.environ.get("CORS_ALLOWED_ORIGIN", "http://localhost:5173")

VALID_STATUSES = ["pending", "shipped", "delivered", "cancelled"]


@app.after_request
def add_security_and_cors_headers(response):
    response.headers["Access-Control-Allow-Origin"] = CORS_ALLOWED_ORIGIN
    response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization, X-CSRF-Token"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
    response.headers["Access-Control-Allow-Credentials"] = "true"
    response.headers["Vary"] = "Origin"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    return response


@app.route("/api/orders", methods=["OPTIONS"])
@app.route("/api/orders/<int:_unused>", methods=["OPTIONS"])
@app.route("/api/orders/<int:_unused>/cancel", methods=["OPTIONS"])
@app.route("/api/orders/<int:_unused>/status", methods=["OPTIONS"])
@app.route("/api/orders/all", methods=["OPTIONS"])
def cors_preflight(_unused=None):
    return "", 204


def connect(autocommit=True):
    if not DATABASE_URL:
        raise RuntimeError(
            "DATABASE_URL is not set. Point it at PostgreSQL, e.g. "
            "postgresql://user:password@host:5432/marketly"
        )
    conn = psycopg2.connect(
        DATABASE_URL,
        options=f"-c search_path={DB_SCHEMA}",
        cursor_factory=RealDictCursor,
    )
    conn.autocommit = autocommit
    return conn


def get_db():
    return connect()


def query_one(conn, sql_text, params=()):
    with conn.cursor() as cur:
        cur.execute(sql_text, params)
        return cur.fetchone()


def query_all(conn, sql_text, params=()):
    with conn.cursor() as cur:
        cur.execute(sql_text, params)
        return cur.fetchall()


def execute(conn, sql_text, params=()):
    with conn.cursor() as cur:
        cur.execute(sql_text, params)


def init_db(max_wait_seconds=60):
    """Creates the schema, tolerating a database that is not up yet and
    other replicas running the same statements concurrently."""
    deadline = time.monotonic() + max_wait_seconds
    while True:
        try:
            conn = connect(autocommit=False)
            break
        except psycopg2.OperationalError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(2)

    try:
        with conn:
            with conn.cursor() as cur:
                cur.execute("SELECT pg_advisory_xact_lock(%s)", (INIT_LOCK_KEY,))
                cur.execute(
                    sql.SQL("CREATE SCHEMA IF NOT EXISTS {}").format(
                        sql.Identifier(DB_SCHEMA)
                    )
                )
                cur.execute(
                    """
                    CREATE TABLE IF NOT EXISTS orders (
                        id SERIAL PRIMARY KEY,
                        username TEXT NOT NULL,
                        items_json TEXT NOT NULL,
                        total DOUBLE PRECISION NOT NULL,
                        status TEXT NOT NULL DEFAULT 'pending',
                        created_at TEXT NOT NULL,
                        updated_at TEXT NOT NULL
                    )
                    """
                )
                # Every customer-facing read filters by username.
                cur.execute(
                    "CREATE INDEX IF NOT EXISTS orders_username_idx ON orders (username)"
                )
    finally:
        conn.close()


def decode_token():
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        return None
    token = auth_header.split(" ", 1)[1]
    try:
        return jwt.decode(token, SHARED_SECRET, algorithms=["HS256"])
    except jwt.PyJWTError:
        return None


def require_user():
    """Returns the username from a valid bearer token, or None."""
    payload = decode_token()
    return payload.get("sub") if payload else None


def require_admin():
    payload = decode_token()
    if not payload or payload.get("role") != "admin":
        return None
    return payload


def order_to_dict(row):
    return {
        "id": row["id"],
        "username": row["username"],
        "items": json.loads(row["items_json"]),
        "total": row["total"],
        "status": row["status"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def adjust_catalog_stock(product_id, delta):
    """Best-effort call to catalog-service to decrement/restore stock.
    Raises on failure so the caller can roll back the order it just made."""
    resp = requests.patch(
        f"{CATALOG_SERVICE_URL}/api/products/{product_id}/stock",
        json={"delta": delta},
        timeout=5,
    )
    resp.raise_for_status()
    return resp.json()


@app.route("/health")
def health():
    return jsonify(status="ok", service="orders-service"), 200


@app.route("/api/orders", methods=["POST"])
def create_order():
    username = require_user()
    if not username:
        return jsonify(error="missing or invalid bearer token"), 401

    data = request.get_json(force=True) or {}
    requested_items = data.get("items", [])  # [{product_id, quantity}]
    if not requested_items:
        return jsonify(error="items is required and must be non-empty"), 400

    order_items = []
    total = 0.0
    decremented = []  # track what we've already deducted, to roll back on failure

    for item in requested_items:
        product_id = item.get("product_id")
        quantity = item.get("quantity", 1)
        try:
            resp = requests.get(f"{CATALOG_SERVICE_URL}/api/products/{product_id}", timeout=5)
        except requests.RequestException as e:
            _rollback(decremented)
            return jsonify(error=f"catalog-service unreachable: {e}"), 502

        if resp.status_code == 404:
            _rollback(decremented)
            return jsonify(error=f"product {product_id} not found"), 400
        if resp.status_code != 200:
            _rollback(decremented)
            return jsonify(error="catalog-service error"), 502

        product = resp.json()
        if product["stock"] < quantity:
            _rollback(decremented)
            return jsonify(error=f"insufficient stock for {product['name']}"), 400

        # Reserve stock now so two concurrent checkouts can't both succeed
        # against the same last unit.
        try:
            adjust_catalog_stock(product_id, -quantity)
            decremented.append((product_id, quantity))
        except requests.RequestException as e:
            _rollback(decremented)
            return jsonify(error=f"could not reserve stock: {e}"), 502

        line_total = product["price"] * quantity
        total += line_total
        order_items.append(
            {
                "product_id": product["id"],
                "name": product["name"],
                "unit_price": product["price"],
                "quantity": quantity,
                "line_total": line_total,
            }
        )

    now = datetime.datetime.utcnow().isoformat()
    conn = get_db()
    row = query_one(
        conn,
        "INSERT INTO orders (username, items_json, total, status, created_at, updated_at) "
        "VALUES (%s, %s, %s, 'pending', %s, %s) RETURNING *",
        (username, json.dumps(order_items), total, now, now),
    )
    conn.close()

    return jsonify(order_to_dict(row)), 201


def _rollback(decremented):
    for product_id, quantity in decremented:
        try:
            adjust_catalog_stock(product_id, quantity)
        except requests.RequestException:
            pass  # best effort — nothing more we can do here


@app.route("/api/orders", methods=["GET"])
def list_orders():
    username = require_user()
    if not username:
        return jsonify(error="missing or invalid bearer token"), 401

    conn = get_db()
    rows = query_all(
        conn, "SELECT * FROM orders WHERE username = %s ORDER BY id DESC", (username,)
    )
    conn.close()
    return jsonify([order_to_dict(r) for r in rows]), 200


@app.route("/api/orders/<int:order_id>", methods=["GET"])
def get_order(order_id):
    username = require_user()
    if not username:
        return jsonify(error="missing or invalid bearer token"), 401

    conn = get_db()
    row = query_one(conn, "SELECT * FROM orders WHERE id = %s", (order_id,))
    conn.close()
    if not row or row["username"] != username:
        return jsonify(error="order not found"), 404
    return jsonify(order_to_dict(row)), 200


@app.route("/api/orders/<int:order_id>/cancel", methods=["PATCH"])
def cancel_order(order_id):
    username = require_user()
    if not username:
        return jsonify(error="missing or invalid bearer token"), 401

    conn = get_db()
    row = query_one(conn, "SELECT * FROM orders WHERE id = %s", (order_id,))
    if not row or row["username"] != username:
        conn.close()
        return jsonify(error="order not found"), 404
    if row["status"] != "pending":
        conn.close()
        return jsonify(error=f"cannot cancel an order with status '{row['status']}'"), 409

    # Claim the cancellation before restoring stock. Two concurrent cancels
    # of one order would otherwise both pass the check above and each restore
    # the same units, inflating stock.
    now = datetime.datetime.utcnow().isoformat()
    row = query_one(
        conn,
        "UPDATE orders SET status = 'cancelled', updated_at = %s "
        "WHERE id = %s AND status = 'pending' RETURNING *",
        (now, order_id),
    )
    if row is None:
        conn.close()
        return jsonify(error="cannot cancel an order that is no longer pending"), 409
    conn.close()

    for item in json.loads(row["items_json"]):
        try:
            adjust_catalog_stock(item["product_id"], item["quantity"])
        except requests.RequestException:
            pass  # stock restore is best-effort; cancellation still proceeds

    return jsonify(order_to_dict(row)), 200


@app.route("/api/orders/all", methods=["GET"])
def list_all_orders():
    if not require_admin():
        return jsonify(error="admin role required"), 403

    conn = get_db()
    rows = query_all(conn, "SELECT * FROM orders ORDER BY id DESC")
    conn.close()
    return jsonify([order_to_dict(r) for r in rows]), 200


@app.route("/api/orders/<int:order_id>/status", methods=["PATCH"])
def set_order_status(order_id):
    if not require_admin():
        return jsonify(error="admin role required"), 403

    data = request.get_json(force=True) or {}
    new_status = data.get("status")
    if new_status not in VALID_STATUSES:
        return jsonify(error=f"status must be one of {VALID_STATUSES}"), 400

    conn = get_db()
    now = datetime.datetime.utcnow().isoformat()
    row = query_one(
        conn,
        "UPDATE orders SET status = %s, updated_at = %s WHERE id = %s RETURNING *",
        (new_status, now, order_id),
    )
    conn.close()
    if not row:
        return jsonify(error="order not found"), 404
    return jsonify(order_to_dict(row)), 200


# gunicorn imports this module rather than executing it, so the schema
# bootstrap cannot live in the __main__ block below. With --preload (see the
# Dockerfile) it runs once in the gunicorn master, before any worker forks.
init_db()

if __name__ == "__main__":
    # Local development only. Containers are served by gunicorn: Flask's
    # built-in server is single-threaded and explicitly not for production.
    app.run(host="0.0.0.0", port=5003)
