# orders-service — Flask app, pure-Python deps, no compile step needed.
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
EXPOSE 5003

CMD ["python", "app.py"]
