# Backend Acrobatica — immagine standard (niente Nixpacks: il Python di Nix
# non vede le librerie di sistema e rompe open3d; qui l'ambiente è controllato).
FROM python:3.12-slim

# Librerie di sistema per opencv-headless e open3d (detector piani v2)
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1 libglib2.0-0 libgomp1 libegl1 libusb-1.0-0 \
        libx11-6 libxext6 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

COPY . .

ENV PYTHONUNBUFFERED=1
# Railway inietta PORT; default 8000 per l'uso locale.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
