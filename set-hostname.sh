#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTNAME_FILE="${REPO_ROOT}/.hostname"

if [[ "$#" -ne 1 ]]; then
  printf 'Usage: %s <domain-suffix-or-url>\n' "$0" >&2
  printf 'Examples: %s .localhost | %s https://1.2.3.4.sslip.io\n' "$0" "$0" >&2
  exit 2
fi

python3 - "${REPO_ROOT}" "${HOSTNAME_FILE}" "$1" <<'PY'
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

repository = Path(sys.argv[1])
hostname_file = Path(sys.argv[2])
raw_value = sys.argv[3].strip()

if "://" in raw_value:
    parsed = urlsplit(raw_value)
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment or parsed.port:
        raise SystemExit("the hostname URL must not contain a port, path, query, or fragment")
    domain = parsed.hostname or ""
else:
    domain = raw_value.lstrip(".").rstrip("/")

if not domain or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", domain):
    raise SystemExit(f"invalid hostname suffix: {raw_value!r}")
domain = domain.lower()
old_domain = hostname_file.read_text().strip() if hostname_file.exists() else "localhost"
if not old_domain:
    old_domain = "localhost"

service_names = (
    "api", "argocd", "grafana", "harbor", "id", "litellm",
    "rabbitmq", "rustfs", "unique",
)
tracked = subprocess.run(
    ["git", "-C", str(repository), "ls-files", "versions.yaml", "1-system", "2-applications"],
    check=True,
    capture_output=True,
    text=True,
).stdout.splitlines()

changed = []
for relative_path in tracked:
    path = repository / relative_path
    try:
        content = path.read_text()
    except UnicodeDecodeError:
        continue
    updated = content
    for service in service_names:
        updated = updated.replace(f"{service}.{old_domain}", f"{service}.{domain}")
        scheme = "http" if domain == "localhost" else "https"
        updated = re.sub(
            rf"https?://{re.escape(service)}\.{re.escape(domain)}(?=[:/\s\"']|$)",
            f"{scheme}://{service}.{domain}",
            updated,
        )
    if updated != content:
        path.write_text(updated)
        changed.append(relative_path)

zitadel_app = repository / "1-system/7-zitadel/app.yaml"
content = zitadel_app.read_text()
secure = "false" if domain == "localhost" else "true"
updated = re.sub(r"(ExternalSecure:\s*)(?:true|false)", rf"\g<1>{secure}", content)
if updated != content:
    zitadel_app.write_text(updated)
    if "1-system/7-zitadel/app.yaml" not in changed:
        changed.append("1-system/7-zitadel/app.yaml")

harbor_virtual_service = repository / "1-system/5-harbor/harbor.virtual-service.yaml"
content = harbor_virtual_service.read_text()
forwarded_proto = "http" if domain == "localhost" else "https"
updated = re.sub(
    r"(x-forwarded-proto:\s*)(?:http|https)",
    rf"\g<1>{forwarded_proto}",
    content,
)
if updated != content:
    harbor_virtual_service.write_text(updated)
    if "1-system/5-harbor/harbor.virtual-service.yaml" not in changed:
        changed.append("1-system/5-harbor/harbor.virtual-service.yaml")

hostname_file.write_text(domain + "\n")
print(f"Configured hostname suffix: .{domain}")
print(f"Argo CD: {'http' if domain == 'localhost' else 'https'}://argocd.{domain}")
print(f"Updated {len(changed)} deployment files.")
PY
