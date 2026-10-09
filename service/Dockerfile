# ---- build stage: install dependencies into an isolated virtualenv ----
FROM python:3.12.14-slim-trixie AS build

ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install -r requirements.txt

# ---- runtime stage: only the venv and the app, no pip cache or build files ----
FROM python:3.12.14-slim-trixie

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

# Fixed numeric UID so Kubernetes can enforce runAsNonRoot.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app

COPY --from=build /opt/venv /opt/venv
WORKDIR /app
COPY app.py .

USER 10001
EXPOSE 8080

# gunicorn instead of Flask's dev server; --worker-tmp-dir in /dev/shm so the
# container works with a read-only root filesystem.
CMD ["sh", "-c", "exec gunicorn --bind 0.0.0.0:${PORT} --workers 2 --worker-tmp-dir /dev/shm --access-logfile - app:app"]
