# ============================================================================
#  Spark with the jars needed to talk S3
# ============================================================================
#  The base image cannot read s3a:// at all. Two jars are missing, and their
#  versions are not free choices:
#
#    hadoop-aws           must match the Hadoop version compiled into this
#                         Spark build exactly. Spark 3.5.9 bundles Hadoop
#                         3.3.4, so hadoop-aws is 3.3.4 and nothing else.
#    aws-java-sdk-bundle  must match what that hadoop-aws was built against.
#                         For 3.3.4 that is the v1 SDK at 1.12.262.
#
#  Getting either wrong produces NoSuchMethodError or ClassNotFoundException
#  from deep inside the call stack, mentioning neither S3 nor versions. It is
#  the single most common way this integration fails.
#
#  Baked in at build time rather than fetched with --packages at runtime, so a
#  wrong version fails here, loudly, instead of a minute into a job.
#
#  The same image runs the master, the workers and the jobs. Workers execute
#  the tasks that actually read S3, so the jars have to be on every node —
#  putting them only in the submitting image gives a job that plans correctly
#  and fails on the first executor.
# ============================================================================
ARG SPARK_IMAGE
FROM ${SPARK_IMAGE}

# The base image runs as a non-root user. Writing into /opt/spark/jars needs
# root, so switch and switch back.
USER root

ARG HADOOP_AWS_VERSION=3.3.4
ARG AWS_SDK_VERSION=1.12.262

ARG HADOOP_AWS_VERSION=3.3.4
ARG AWS_SDK_VERSION=1.12.262
ARG SPARK_VERSION_FULL=3.5.9
ARG SCALA_BINARY=2.12

RUN set -eux; \
    cd /opt/spark/jars; \
    curl -fsSL -O "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar"; \
    curl -fsSL -O "https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/${AWS_SDK_VERSION}/aws-java-sdk-bundle-${AWS_SDK_VERSION}.jar"; \
    # spark-hadoop-cloud, and the reason it is a third jar rather than part of
    # Spark: it is an optional module, published separately and absent from
    # every official Spark image. It holds PathOutputCommitProtocol and
    # BindingParquetOutputCommitter — the two classes spark-defaults.conf
    # names to avoid the rename-based committer that S3 cannot do atomically.
    #
    # Without it the cluster starts, reads S3 perfectly, and fails only when a
    # job first writes, with ClassNotFoundException naming a class that sounds
    # like it should be built in.
    #
    # Versioned with Spark itself, not with Hadoop: the artifact is
    # spark-hadoop-cloud_<scala>:<spark version>.
    curl -fsSL -O "https://repo1.maven.org/maven2/org/apache/spark/spark-hadoop-cloud_${SCALA_BINARY}/${SPARK_VERSION_FULL}/spark-hadoop-cloud_${SCALA_BINARY}-${SPARK_VERSION_FULL}.jar"; \
    test -s "hadoop-aws-${HADOOP_AWS_VERSION}.jar"; \
    test -s "aws-java-sdk-bundle-${AWS_SDK_VERSION}.jar"; \
    test -s "spark-hadoop-cloud_${SCALA_BINARY}-${SPARK_VERSION_FULL}.jar"; \    
    # A jar that downloaded successfully is not necessarily the jar you wanted.
    # Checking that the class Spark will look for is actually inside it turns
    # a runtime ClassNotFoundException into a failed build.
    python3 -c "\
import zipfile, sys; \
z = zipfile.ZipFile('hadoop-aws-${HADOOP_AWS_VERSION}.jar'); \
assert 'org/apache/hadoop/fs/s3a/S3AFileSystem.class' in z.namelist(), 'S3AFileSystem missing'; \
z = zipfile.ZipFile('aws-java-sdk-bundle-${AWS_SDK_VERSION}.jar'); \
assert any(n.startswith('com/amazonaws/services/s3/') for n in z.namelist()), 'aws s3 client missing'; \
z = zipfile.ZipFile('spark-hadoop-cloud_${SCALA_BINARY}-${SPARK_VERSION_FULL}.jar'); \
assert 'org/apache/spark/internal/io/cloud/PathOutputCommitProtocol.class' in z.namelist(), 'PathOutputCommitProtocol missing'; \
print('all three jars contain what Spark will look for')"

# Configuration shared by every node and every job. Kept in the image rather
# than mounted, so a job submitted from anywhere gets the same defaults.
COPY spark-defaults.conf /opt/spark/conf/spark-defaults.conf
COPY metrics.properties  /opt/spark/conf/metrics.properties

# The event log directory has to exist before Spark starts, and it has to
# exist in the IMAGE rather than only where the compose file mounts a volume.
#
# spark.eventLog.dir is set in spark-defaults.conf, which every container
# built from this image reads — including a job container, which gets no
# volume. Spark does not create the directory: it checks for it and refuses
# to start the context, with FileNotFoundException naming a path the operator
# never chose.
#
# Where the compose file does mount spark-events, the volume covers this and
# the history is shared. Where it does not, the job writes locally and the
# logs vanish with the container, which for a job that has already printed
# its results is the right trade.
RUN mkdir -p /opt/spark/events && chown spark:spark /opt/spark/events

USER spark
