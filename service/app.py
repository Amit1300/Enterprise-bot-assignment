import os
import socket

from flask import Flask, jsonify

app = Flask(__name__)

# When running in Kubernetes the ConfigMap is also mounted here. Mounted files
# are refreshed by the kubelet when the ConfigMap changes; env vars are not.
CONFIG_DIR = os.environ.get("CONFIG_DIR", "/etc/app-config")


def setting(name, default):
    """Read a setting on every request: mounted file first, then env var."""
    try:
        with open(os.path.join(CONFIG_DIR, name)) as f:
            return f.read().strip()
    except OSError:
        return os.environ.get(name, default)


@app.get("/")
def index():
    return jsonify(
        app=setting("APP_NAME", "unknown"),
        version=setting("VERSION", "unknown"),
        pod=socket.gethostname(),
    )


@app.get("/healthz")
def healthz():
    return jsonify(status="ok"), 200
