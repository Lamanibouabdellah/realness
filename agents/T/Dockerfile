FROM python:3.12-slim
# Cross-compilers pour ARM, RISC-V, x86
RUN apt-get update && apt-get install -y --no-install-recommends \
    git gcc \
    gcc-aarch64-linux-gnu \
    gcc-riscv64-linux-gnu \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["python", "-u", "main.py"]
