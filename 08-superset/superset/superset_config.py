# ============================================================================
#  Superset configuration
# ============================================================================
#  Mounted rather than baked into the image: this is configuration, and it
#  changes independently of the driver the image exists to provide.
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

# Superset logs a warning on every start without this and defaults to False in
# a future version anyway.
SQLALCHEMY_TRACK_MODIFICATIONS = False

# ---------------------------------------------------------------------------
#  Caching
# ---------------------------------------------------------------------------
#  Redis, for three separate caches Superset keeps apart:
#
#    CACHE_CONFIG            rendered chart data
#    DATA_CACHE_CONFIG       query results
#    FILTER_STATE_CACHE      what a dashboard's filters are set to
#
#  The last one is not optional in practice. Without a backing store Superset
#  keeps filter state in the metadata database and the UI grows slower with
#  every dashboard interaction, which reads as Superset being slow rather than
#  as a missing cache.
#
#  No Celery worker here: that is for running long queries in the background,
#  and the marts this reads answer in milliseconds. Adding a worker would be
#  complexity for its own sake.
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
#  Features
# ---------------------------------------------------------------------------
FEATURE_FLAGS = {
    # Lets a dashboard be exported and imported as files, which is what makes
    # the next parts of this stack possible: a dashboard that exists only in
    # someone's browser is not part of the project and does not survive
    # `make clean`.
    "VERSIONED_EXPORT": True,
    # Cross-filters: clicking a bar filters the rest of the dashboard.
    "DASHBOARD_CROSS_FILTERS": True,
    # Lets a query result be saved as a virtual dataset without writing to the
    # warehouse. Useful here because the warehouse is read-only from
    # Superset's point of view.
    "ENABLE_TEMPLATE_PROCESSING": True,
}

# How long a query may run before Superset gives up. The default of 60s is
# generous for these marts; a query that exceeds it has gone wrong rather than
# being slow.
SUPERSET_WEBSERVER_TIMEOUT = 60
SQLLAB_TIMEOUT = 60

# ---------------------------------------------------------------------------
#  Behind nothing, for now
# ---------------------------------------------------------------------------
#  Superset is reached directly on its published port. If it is ever put
#  behind a proxy, ENABLE_PROXY_FIX has to be set or every generated link
#  points at the container's own address.
# ---------------------------------------------------------------------------
ENABLE_PROXY_FIX = False

# The row limit applied when a chart does not set its own. Low on purpose: a
# chart that needs a hundred thousand rows is a chart that should be
# aggregating in the warehouse instead.
ROW_LIMIT = 50000
