{#
  ============================================================================
   Reading the other two systems from inside ClickHouse
  ============================================================================
   dbt is a single-database tool: the adapter is chosen once, and every model
   compiles to SQL for that engine. Reading Postgres and object storage from
   the same project therefore has to happen on ClickHouse's side, through its
   table functions.

   The alternative — a second dbt project per source — gives two sets of
   models that cannot be joined to each other, which defeats the purpose.

   Both functions take addresses and credentials as arguments, which would put
   them in the model text and therefore in git. These macros exist so that
   does not happen: the values come from the environment, and a model says
   what it wants rather than how to reach it.
  ============================================================================
#}


{#
  A table in the operational Postgres, read live.

  Not a duplicate of the CDC path. Change capture carries four tables into the
  warehouse; this reaches anything, including tables outside the publication,
  and it reads the source as it is right now rather than as it was when the
  last event arrived. That difference is what makes reconciliation possible —
  see the models that compare the two.

  Every read is a query against the operational database, so this belongs in
  models that run on a schedule and not in anything a dashboard touches.
#}
{% macro postgres_source(table_name, schema='public') %}
    postgresql(
        '{{ env_var("POSTGRES_HOST", "postgres") }}:{{ env_var("POSTGRES_PORT", "5432") }}',
        '{{ env_var("POSTGRES_DB", "shop") }}',
        '{{ table_name }}',
        '{{ env_var("POSTGRES_USER", "app") }}',
        '{{ env_var("POSTGRES_PASSWORD", "app") }}',
        '{{ schema }}'
    )
{% endmacro %}


{#
  Parquet in object storage, read where it lies.

  `path` is a glob relative to the bucket, so a model asks for
  'orders/dt=*/*.parquet' and gets every partition, or
  'orders/dt=2026-09-06/*.parquet' for one.

  Note what ClickHouse does NOT do here: it reads the files and infers their
  schema, but it does not derive columns from the directory names. Spark turns
  `dt=2026-09-06/` into a `dt` column automatically; ClickHouse hands back
  only what is inside the files, and the partition value has to be recovered
  from the path. The `_path` virtual column is how — see stg_s3_orders.

  That asymmetry is easy to miss precisely because the same layout works
  transparently in Spark, and the result is a model that silently loses its
  partitioning.
#}
{% macro s3_source(bucket, path, format='Parquet') %}
    s3(
        '{{ env_var("S3_ENDPOINT", "http://minio:9000") }}/{{ bucket }}/{{ path }}',
        '{{ env_var("S3_ACCESS_KEY", "minioadmin") }}',
        '{{ env_var("S3_SECRET_KEY", "minioadmin") }}',
        '{{ format }}'
    )
{% endmacro %}


{#
  The date out of a Hive-style path.

  `_path` is a virtual column the s3 function adds to every row, holding the
  full object key it came from. extractGroups pulls the value out of
  `dt=YYYY-MM-DD/`, which is the partitioning convention the export job in
  04-etl and the Spark job in 06-spark both write.

  Kept as a macro rather than repeated, because getting the expression subtly
  wrong yields nulls rather than an error — and a null partition column looks
  like missing data rather than a broken regex.
#}
{% macro partition_date_from_path(path_column='_path') %}
    toDate(
        arrayElement(
            extractGroups({{ path_column }}, 'dt=(\\d{4}-\\d{2}-\\d{2})'),
            1
        )
    )
{% endmacro %}
