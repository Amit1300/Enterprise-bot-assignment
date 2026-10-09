import os
import socket

from flask import Flask, jsonify

app = Flask(__name__)


def get_config(name):
    path = f"/etc/app-config/{name}"
    if os.path.exists(path):
        with open(path) as f:
            return f.read().strip()
    return os.getenv(name, "unknown")


@app.route("/")
def index():
    return jsonify(
        app=get_config("APP_NAME"),
        version=get_config("VERSION"),
        pod=socket.gethostname(),
    )


@app.route("/healthz")
def healthz():
    return jsonify(status="ok")
