# ============================================================================
#  Data generator — keeps the source database changing
# ============================================================================
#  A database that never changes produces no CDC events, no consumer lag and
#  flat graphs. This container is what makes the rest of the platform have
#  something to do.
#
#  Two modes, selected by the command:
#    seed    one-shot: fills the reference tables, then exits
#    churn   long-running: creates orders and mutates rows forever
# ============================================================================
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ /app/

# Unbuffered stdout, otherwise Python holds log lines in a buffer and
# `docker logs` shows nothing until the buffer fills — which, for a process
# that prints one line a minute, looks exactly like a hung container.
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "generate.py"]
CMD ["churn"]
