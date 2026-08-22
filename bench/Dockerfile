FROM python:3.12-slim
RUN pip install --no-cache-dir httpx==0.27.2
WORKDIR /app
COPY benchmark.py /app/benchmark.py
ENTRYPOINT ["python", "-u", "/app/benchmark.py"]
