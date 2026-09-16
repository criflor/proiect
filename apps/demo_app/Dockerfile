# syntax=docker/dockerfile:1

# --- Stage 1: build dependencies (compilatoare/headers rămân aici, nu ajung în imaginea finală)
FROM python:3.13-slim AS builder

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# --- Stage 2: imagine finală, minimală
FROM python:3.13-slim

# Actualizează pachetele de sistem (imagine de bază proaspătă la fiecare build)
# și elimină cache-ul apt, ca să nu rămână în layer.
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*

# Utilizator non-root dedicat - containerul nu rulează niciodată ca root.
RUN groupadd --gid 10001 appuser && \
    useradd --uid 10001 --gid appuser --no-create-home --shell /usr/sbin/nologin appuser

COPY --from=builder /install /usr/local

WORKDIR /app
COPY app.py .
COPY templates ./templates

USER appuser

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz')" || exit 1

# gunicorn în loc de serverul de dezvoltare Flask - singurul proces, fără reload,
# potrivit pentru rulare în container/producție. Înfășurat cu
# "opentelemetry-instrument" - auto-instrumentare Flask/psycopg2 (trace-uri
# trimise via OTLP, cerința 10), fără nicio modificare în app.py.
CMD ["opentelemetry-instrument", "gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
