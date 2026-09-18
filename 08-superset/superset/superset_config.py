# ============================================================================
#  Superset configuration
# ============================================================================
#  Mounted rather than baked into the image: this is configuration, and it
#  changes independently of the drivers the image exists to provide.
#
#  Superset reads whatever Python file PYTHONPATH exposes as
#  superset_config.py. It is executed, not parsed, so everything here is
#  ordinary Python and reads from the environment.
# ============================================================================
import os


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


# ---------------------------------------------------------------------------
#  The secret key
# ---------------------------------------------------------------------------
#  Encrypts database connection passwords in the metadata database, and signs
#  session cookies.
#
#  Changing it after the fact makes every stored connection password
#  unreadable — Superset starts, the connections are listed, and every query
#  through them fails to decrypt. Pinned in .env for that reason, the same
#  argument as Airflow's Fernet key.
# ---------------------------------------------------------------------------
SECRET_KEY = env("SUPERSET_SECRET_KEY")

# ---------------------------------------------------------------------------
#  Metadata
# ---------------------------------------------------------------------------
#  Its own Postgres, not the operational one in 03-dbms and not Airflow's.
#  Superset writes constantly — every dashboard edit, every query log — and
#  none of that belongs in a database being captured, or in one whose schema
#  another tool migrates.
#
#  The default is SQLite, which Superset itself warns against: it serialises
#  writes and loses them under any concurrency.
# ---------------------------------------------------------------------------
SQLALCHEMY_DATABASE_URI = (
    f"postgresql+psycopg2://{env('SUPERSET_DB_USER')}:{env('SUPERSET_DB_PASSWORD')}"
    f"@superset-postgres:5432/{env('SUPERSET_DB_NAME')}"
)

SQLALCHEMY_TRACK_MODIFICATIONS = False

# ---------------------------------------------------------------------------
#  Caching
# ---------------------------------------------------------------------------
#  Redis, for four caches Superset keeps apart: rendered chart data, query
#  results, dashboard filter state and explore form state.
#
#  Filter state is not optional in practice. Without a backing store Superset
#  keeps it in the metadata database and the UI grows slower with every
#  dashboard interaction — which reads as Superset being slow rather than as a
#  missing cache.
#
#  No Celery worker: that is for running long queries in the background, and
#  the marts this reads answer in milliseconds.
# ---------------------------------------------------------------------------
REDIS_URL = f"redis://{env('REDIS_HOST', 'superset-redis')}:6379"

CACHE_CONFIG = {
    "CACHE_TYPE": "RedisCache",
    "CACHE_DEFAULT_TIMEOUT": 300,
    "CACHE_KEY_PREFIX": "superset_",
    "CACHE_REDIS_URL": f"{REDIS_URL}/0",
}

DATA_CACHE_CONFIG = {
    "CACHE_TYPE": "RedisCache",
    "CACHE_DEFAULT_TIMEOUT": 600,
    "CACHE_KEY_PREFIX": "superset_data_",
    "CACHE_REDIS_URL": f"{REDIS_URL}/1",
}

FILTER_STATE_CACHE_CONFIG = {
    "CACHE_TYPE": "RedisCache",
    "CACHE_DEFAULT_TIMEOUT": 86400,
    "CACHE_KEY_PREFIX": "superset_filter_",
    "CACHE_REDIS_URL": f"{REDIS_URL}/2",
}

EXPLORE_FORM_DATA_CACHE_CONFIG = {
    "CACHE_TYPE": "RedisCache",
    "CACHE_DEFAULT_TIMEOUT": 86400,
    "CACHE_KEY_PREFIX": "superset_explore_",
    "CACHE_REDIS_URL": f"{REDIS_URL}/3",
}

# ---------------------------------------------------------------------------
#  Metrics
# ---------------------------------------------------------------------------
#  Superset speaks StatsD, like Airflow and unlike everything else here. A
#  second exporter translates — its own rather than Airflow's, because the
#  two tools name things differently and a shared mapping file would
#  interleave their conventions until nobody could tell which rule belonged
#  to which.
#
#  StatsD is fire-and-forget over UDP. Superset does not notice whether
#  anything is listening, so a missing exporter costs nothing at runtime and
#  shows up only as an absence in Grafana — which is why there is an alert for
#  the exporter itself and not only for Superset.
# ---------------------------------------------------------------------------
if env("SUPERSET_STATSD_ENABLED", "1") == "1":
    from superset.stats_logger import StatsdStatsLogger

    try:
        STATS_LOGGER = StatsdStatsLogger(
            host=env("SUPERSET_STATSD_HOST", "superset-statsd"),
            port=int(env("SUPERSET_STATSD_PORT", "9125")),
            prefix=env("SUPERSET_STATSD_PREFIX", "superset"),
        )
    except Exception as exc:  # noqa: BLE001
        import logging

        logging.getLogger(__name__).warning(
            "StatsD logger not configured (%s); metrics will not be emitted", exc
        )

# ---------------------------------------------------------------------------
#  Features
# ---------------------------------------------------------------------------
FEATURE_FLAGS = {
    # Lets a dashboard be exported and imported as files. Not how this stack
    # builds its dashboard — dashboard.py does that from code — but worth
    # having for anyone who wants to take one elsewhere.
    "VERSIONED_EXPORT": True,
    # Cross-filters: clicking a bar filters the rest of the dashboard.
    "DASHBOARD_CROSS_FILTERS": True,
    # Jinja in SQL Lab and in virtual datasets.
    "ENABLE_TEMPLATE_PROCESSING": True,
}

# How long a query may run before Superset gives up. The default of 60s is
# generous for these marts; a query that exceeds it has gone wrong rather than
# being slow.
SUPERSET_WEBSERVER_TIMEOUT = 60
SQLLAB_TIMEOUT = 60

# Superset is reached directly on its published port. Behind a proxy this has
# to be True or every generated link points at the container's own address.
ENABLE_PROXY_FIX = False

# The row limit applied when a chart does not set its own. Low on purpose: a
# chart that needs a hundred thousand rows is a chart that should be
# aggregating in the warehouse instead.
ROW_LIMIT = 50000
