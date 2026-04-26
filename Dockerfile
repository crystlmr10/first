# FastAPI flood routing service — Cloud Run / Artifact Registry
# Build:  docker build -t ROUTING_API_IMAGE .
# Push:   docker push (to Artifact Registry recommended, not legacy gcr.io)

FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

RUN useradd --create-home --shell /bin/bash appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

USER appuser

# Cloud Run sets PORT; default 8080 for local docker run -p 8080:8080
ENV PORT=8080
EXPOSE 8080

CMD ["sh", "-c", "exec uvicorn main:app --host 0.0.0.0 --port ${PORT}"]
