FROM python:3.12.14-slim-trixie AS build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12.14-slim-trixie
RUN useradd --uid 10001 app
COPY --from=build /install /usr/local
WORKDIR /app
COPY app.py .
USER 10001
EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--worker-tmp-dir", "/dev/shm", "app:app"]
