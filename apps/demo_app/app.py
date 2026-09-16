"""Aplicație demo: pagină de autentificare, cu utilizatori stocați în PostgreSQL.

Scopul exercițiului nu e complexitatea aplicației, ci procesul din jurul ei
(containerizare, configurare prin variabile de mediu, securizare, livrare,
operare) — codul e intenționat minimal.
"""

import os
import time

import bcrypt
import psycopg2
from flask import Flask, redirect, render_template, request, session, url_for

app = Flask(__name__)

# SECRET_KEY vine dintr-un Kubernetes Secret montat ca variabilă de mediu -
# niciodată hardcodat în cod sau în imagine.
app.config["SECRET_KEY"] = os.environ["FLASK_SECRET_KEY"]
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SECURE=True,  # aplicația e expusă doar prin HTTPS (vezi Gateway)
    SESSION_COOKIE_SAMESITE="Lax",
)

DB_CONFIG = {
    "host": os.environ["DB_HOST"],
    "port": os.environ.get("DB_PORT", "5432"),
    "dbname": os.environ["DB_NAME"],
    "user": os.environ["DB_USER"],
    "password": os.environ["DB_PASSWORD"],
}


def get_db():
    return psycopg2.connect(**DB_CONFIG)


def init_db():
    """Creează schema la pornire dacă nu există deja (idempotent)."""
    with get_db() as conn, conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS users (
                id SERIAL PRIMARY KEY,
                username TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL
            )
            """
        )
        conn.commit()


@app.get("/healthz")
def healthz():
    """Verificare de sănătate pentru probele Kubernetes (liveness/readiness)."""
    try:
        with get_db() as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
        return {"status": "ok"}, 200
    except psycopg2.OperationalError:
        return {"status": "db unavailable"}, 503


@app.get("/")
def index():
    if "username" not in session:
        return redirect(url_for("login"))
    return render_template("index.html", username=session["username"])


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = request.form.get("username", "")
        password = request.form.get("password", "").encode("utf-8")

        # Interogare parametrizată - nicio concatenare de string, nicio
        # expunere la SQL injection.
        with get_db() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT password_hash FROM users WHERE username = %s", (username,)
            )
            row = cur.fetchone()

        if row and bcrypt.checkpw(password, row[0].encode("utf-8")):
            session.clear()
            session["username"] = username
            return redirect(url_for("index"))

        return render_template("login.html", error="Utilizator sau parolă incorectă"), 401

    return render_template("login.html")


@app.route("/register", methods=["GET", "POST"])
def register():
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "").encode("utf-8")

        if not username or not password:
            return render_template("register.html", error="Completează toate câmpurile"), 400

        password_hash = bcrypt.hashpw(password, bcrypt.gensalt()).decode("utf-8")

        try:
            with get_db() as conn, conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO users (username, password_hash) VALUES (%s, %s)",
                    (username, password_hash),
                )
                conn.commit()
        except psycopg2.errors.UniqueViolation:
            return render_template("register.html", error="Utilizator existent deja"), 409

        return redirect(url_for("login"))

    return render_template("register.html")


@app.post("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# Postgres poate porni puțin mai târziu decât aplicația (nicio ordine
# garantată între StatefulSet și Deployment) - se încearcă timp de ~30s în loc
# de a crăpa procesul la primul eșec, ceea ce ar declanșa CrashLoopBackOff
# chiar și pentru o întârziere normală de câteva secunde.
for attempt in range(10):
    try:
        init_db()
        break
    except psycopg2.OperationalError:
        if attempt == 9:
            raise
        time.sleep(3)

if __name__ == "__main__":
    # Doar pentru dezvoltare locală - în cluster rulează prin gunicorn (vezi Dockerfile).
    app.run(host="0.0.0.0", port=8080)
