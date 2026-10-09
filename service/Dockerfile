# Stage 1: install the Python libraries into a virtualenv
FROM python:3.12.14-slim-trixie AS build
RUN python -m venv /opt/venv
COPY requirements.txt .
RUN /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

# Stage 2: final image with only the libraries and the app
FROM python:3.12.14-slim-trixie
RUN useradd --uid 10001 app
COPY --from=build /opt/venv /opt/venv
WORKDIR /app
COPY app.py .
USER 10001
EXPOSE 8080
CMD ["/opt/venv/bin/gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--worker-tmp-dir", "/dev/shm", "--access-logfile", "-", "app:app"]
