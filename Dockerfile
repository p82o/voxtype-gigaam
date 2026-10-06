# syntax=docker/dockerfile:1
FROM python:3.14-slim-trixie AS base

FROM base AS tools
COPY --from=ghcr.io/astral-sh/uv:0.12.23 /uv /usr/local/bin/uv
COPY audit-requirements.lock /build/audit-requirements.lock
RUN uv venv --python /usr/local/bin/python --no-python-downloads /opt/tools \
    && uv pip install --python /opt/tools/bin/python --no-cache --require-hashes -r /build/audit-requirements.lock
ENV PATH=/opt/tools/bin:$PATH

FROM base AS dependencies
COPY --from=ghcr.io/astral-sh/uv:0.12.23 /uv /usr/local/bin/uv
COPY requirements.lock build-requirements.lock /build/
RUN uv venv --python /usr/local/bin/python --no-python-downloads /opt/venv \
    && uv pip install --python /opt/venv/bin/python --no-cache --require-hashes -r /build/build-requirements.lock \
    && uv pip install --python /opt/venv/bin/python --no-cache --require-hashes --no-build-isolation --index-strategy unsafe-best-match -r /build/requirements.lock \
    && uv pip uninstall --python /opt/venv/bin/python wheel \
    && uv pip check --python /opt/venv/bin/python

FROM base AS source
COPY .build/gigaam.tar.gz model/source.SHA256SUMS /build/
RUN cd /build && sha256sum --check --status source.SHA256SUMS \
    && mkdir /opt/upstream \
    && tar -xzf gigaam.tar.gz --strip-components=1 -C /opt/upstream

FROM base AS runtime-os
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/* /usr/local/lib/python3.14/site-packages/*

FROM runtime-os AS runtime
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONPATH=/opt/upstream \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    MODEL_DIR=/opt/model \
    ASR_HOST=0.0.0.0 \
    XDG_CACHE_HOME=/tmp/cache \
    OMP_NUM_THREADS=8
COPY --from=dependencies /opt/venv /opt/venv
COPY --from=source /opt/upstream/gigaam/ /opt/upstream/gigaam/
COPY model/revision.txt /opt/upstream/revision.txt
COPY .build/model-native/ /opt/model/
COPY model/SHA256SUMS /opt/model/SHA256SUMS
RUN cd /opt/model && sha256sum --check --status SHA256SUMS
COPY server/server.py /app/server.py
WORKDIR /app
USER 10001:10001
EXPOSE 8394
CMD ["python", "/app/server.py"]
