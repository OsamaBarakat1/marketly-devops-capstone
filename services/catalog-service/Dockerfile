# catalog-service — Flask app, pure-Python deps, no compile step needed.
FROM python:3.12-slim

WORKDIR /app

RUN groupadd --system app && useradd --system --gid app --home /app app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

RUN chown -R app:app /app
USER app

ENV PYTHONUNBUFFERED=1
EXPOSE 5002

CMD ["python", "app.py"]
