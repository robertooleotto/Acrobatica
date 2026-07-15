# Backend Acrobatica — immagine standard (niente Nixpacks: il Python di Nix
# non vede le librerie di sistema e rompe open3d; qui l'ambiente è controllato).
FROM python:3.12-slim AS cgal-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake make g++ libcgal-dev libeigen3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY fused_planes/native ./native
RUN cmake -S native/regiongrow -B build/regiongrow -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build/regiongrow --parallel 2 \
    && cmake -S native/slice_contours -B build/slice_contours -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build/slice_contours --parallel 2

FROM python:3.12-slim

# Librerie di sistema per opencv-headless e open3d (detector piani v2)
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1 libglib2.0-0 libgomp1 libegl1 libusb-1.0-0 \
        libx11-6 libxext6 libgmp10 libmpfr6 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu \
        torch==2.2.2+cpu torchvision==0.17.2+cpu \
    && pip install --no-cache-dir -r requirements.txt

COPY . .
COPY --from=cgal-builder /src/build/regiongrow/rg /usr/local/bin/acro-regiongrow
COPY --from=cgal-builder /src/build/slice_contours/slice_contours /usr/local/bin/acro-slice-contours

ENV PYTHONUNBUFFERED=1 \
    HF_HOME=/tmp/huggingface \
    HF_HUB_DISABLE_XET=1 \
    ACRO_ENABLE_FUSED=1
# Railway inietta PORT; default 8000 per l'uso locale.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
