#!/usr/bin/env bash
#
# Adds DOCKER_GID to every stack that can be an entry point.
#
# ---------------------------------------------------------------------------
#  The bug this fixes
# ---------------------------------------------------------------------------
#  Prometheus is declared in 02-monitoring and reads the Docker socket through
#  group_add: ["${DOCKER_GID}"]. Compose resolves that variable from the .env
#  beside the file being RUN, not beside the file that declares the service.
#
#  So `make up` from 02-monitoring works, and the same Prometheus started from
#  05-minio or 06-spark gets the default of 0 — because those .env files have
#  no DOCKER_GID at all.
#
#  On Docker Desktop 0 is correct, so this never showed locally. On a CI
#  runner the socket is root:docker, group 0 grants nothing, and service
#  discovery finds zero containers while every static job keeps working:
#
#      === what prometheus discovered ===
#            2 "job":"cadvisor"
#            8 "job":"kafka-jmx"
#            2 "job":"kafka-lag"
#            2 "job":"node"
#            2 "job":"prometheus"
#
#  Five static jobs, no minio, no postgres, no airflow, no clickhouse. Nothing
#  logs an error. The same class of failure as POSTGRES_VERSION in step 8, and
#  for the identical reason.
#
# Run once from the repository root:
#     bash fix-docker-gid.sh
# ---------------------------------------------------------------------------
set -euo pipefail

test -d 01-kafka || { echo "run this from the repository root"; exit 1; }

GID_BLOCK='
# The gid that owns /var/run/docker.sock.
#
# Repeated in every stack rather than inherited. Compose resolves variables
# from the .env beside the file being run, so the value 02-monitoring sets is
# invisible when the same services are started from here — the substitution
# falls back to 0, Prometheus cannot read the socket, and service discovery
# finds nothing while every static target keeps working.
#
# 0 on Docker Desktop, where the socket inside the VM is root:root; usually
# 999 on a Linux host, where it is root:docker. Find yours:
#   stat -c '"'"'%g'"'"' /var/run/docker.sock
DOCKER_GID=0'

for stack in 02-monitoring 03-dbms 04-etl 05-minio 06-spark 07-dbt 08-superset; do
  f="${stack}/.env.example"
  test -f "$f" || { echo "  skip  ${f} (absent)"; continue; }
  if grep -q '^DOCKER_GID=' "$f"; then
    echo "  have  ${f}"
  else
    printf '%s\n' "$GID_BLOCK" >> "$f"
    echo "  add   ${f}"
  fi
  # The real .env too, so a stack already checked out keeps working.
  if [ -f "${stack}/.env" ] && ! grep -q '^DOCKER_GID=' "${stack}/.env"; then
    printf 'DOCKER_GID=0\n' >> "${stack}/.env"
    echo "  add   ${stack}/.env"
  fi
done

echo ""
echo "Now the workflows. Each must set the gid in its OWN .env as well as in"
echo "02-monitoring's, for the same reason."
echo ""

for wf in .github/workflows/0[2-8]-*.yml; do
  test -f "$wf" || continue
  if grep -q 'DOCKER_GID=\${DOCKER_GID}' "$wf" || grep -q 'own .env' "$wf"; then
    echo "  have  ${wf}"
    continue
  fi
  # Replace the single-file sed with one that writes both files.
  python3 - "$wf" <<'PY'
import re, sys
path = sys.argv[1]
s = open(path).read()

old = re.search(
    r'^([ ]+)sed -i "s/\^DOCKER_GID=\.\*/DOCKER_GID=\$\(stat -c \'%g\' /var/run/docker\.sock\)/" ([^\n]+)\n',
    s, re.M)
if not old:
    print(f"  ??    {path} — no sed line matched, edit by hand")
    sys.exit(0)

indent, target = old.group(1), old.group(2)
new = (
    f"{indent}# Set in BOTH files, and that is not redundancy.\n"
    f"{indent}#\n"
    f"{indent}# Compose resolves variables from the .env beside the file being\n"
    f"{indent}# run, not beside the one declaring the service. Prometheus is\n"
    f"{indent}# declared in 02-monitoring and started from here, so it reads\n"
    f"{indent}# this stack's .env — where the variable has to exist too, or it\n"
    f"{indent}# falls back to 0 and discovery silently finds nothing.\n"
    f"{indent}DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)\n"
    f'{indent}for f in .env {target}; do\n'
    f'{indent}  grep -q "^DOCKER_GID=" "$f" \\\n'
    f'{indent}    && sed -i "s/^DOCKER_GID=.*/DOCKER_GID=${{DOCKER_GID}}/" "$f" \\\n'
    f'{indent}    || echo "DOCKER_GID=${{DOCKER_GID}}" >> "$f"\n'
    f'{indent}done\n'
    f'{indent}echo "docker socket gid: ${{DOCKER_GID}}"\n'
)
s = s[:old.start()] + new + s[old.end():]
open(path, "w").write(s)
print(f"  fix   {path}")
PY
done

echo ""
echo "Check one:  grep -A10 'docker socket gid' .github/workflows/05-minio.yml"
