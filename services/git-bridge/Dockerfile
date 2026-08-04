FROM python:3.11-slim

# git est l'outil principal de ce service
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .

ENV GIT_ROOT=/workspace

CMD ["python", "main.py"]