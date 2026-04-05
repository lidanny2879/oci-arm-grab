FROM python:3.12-slim

RUN pip install --no-cache-dir oci-cli && \
    apt-get update && apt-get install -y --no-install-recommends curl bash && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY grab.sh .
RUN chmod +x grab.sh

CMD ["bash", "./grab.sh"]
