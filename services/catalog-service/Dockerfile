# catalog-service — Flask app, pure-Python deps, no compile step needed.
FROM python:3.12-slim

WORKDIR /app

# Fixed numeric UID: Kubernetes cannot verify runAsNonRoot against a
# username, and refuses to start the container with CreateContainerConfigError.
RUN groupadd --gid 10001 app && useradd --uid 10001 --gid app --home /app app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

RUN chown -R app:app /app
USER 10001

ENV PYTHONUNBUFFERED=1
EXPOSE 5002

# Served by gunicorn, not Flask's development server.
#
# These handlers are I/O-bound on PostgreSQL and hold no per-process state, so
# workers and threads both scale freely.
#
# --preload imports the module (and so runs init_db) once in the master before
# forking, instead of once per worker.
CMD ["gunicorn", \
     "--bind", "0.0.0.0:5002", \
     "--worker-class", "gthread", \
     "--workers", "2", \
     "--threads", "4", \
     "--preload", \
     "--timeout", "60", \
     "--graceful-timeout", "30", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "app:app"]
