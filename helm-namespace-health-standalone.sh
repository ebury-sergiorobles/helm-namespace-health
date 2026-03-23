#!/usr/bin/env bash
# =============================================================================
# helm-namespace-health-standalone.sh
#
# Standalone version — no kubie required. Uses the active kubectl context from
# the default kubeconfig (~/.kube/config) or whichever file is pointed to by
# the KUBECONFIG environment variable.
#
# For every namespace that has at least one active Helm release, checks:
#   - Helm release status
#   - Deployment availability (desired vs ready replicas)
#   - StatefulSet availability (desired vs ready replicas, revision match)
#   - Pod health (phase, ready, restart count)
#   - ExternalSecret sync status
#   - Kubernetes Secret existence (referenced by ExternalSecrets)
#   - Ingress health (LB assigned, backend service exists, TLS configured)
#   - CronJob health (suspended, last run succeeded, stuck jobs)
#   - Warning events
#

# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
CONTEXT=""
FILTER_NS=""
RESTART_THRESHOLD=5
OUTPUT_FORMAT="pretty"

# Honour KUBECONFIG env var if set; kubectl picks it up automatically.
# We capture it here only for display purposes in the header.
KUBECONFIG_DISPLAY="${KUBECONFIG:-~/.kube/config}"

# ── Colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED="\033[0;31m"
  GREEN="\033[0;32m"
  YELLOW="\033[0;33m"
  BLUE="\033[0;34m"
  CYAN="\033[0;36m"
  BOLD="\033[1m"
  RESET="\033[0m"
else
  RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" RESET=""
fi

OK="${GREEN}✔${RESET}"
WARN="${YELLOW}⚠${RESET}"
FAIL="${RED}✖${RESET}"

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
  local B C Y G R RESET
  if [[ -t 1 ]]; then
    B="\033[1m"; C="\033[0;36m"; Y="\033[0;33m"; G="\033[0;32m"
    R="\033[0;31m"; RESET="\033[0m"
  else
    B=""; C=""; Y=""; G=""; R=""; RESET=""
  fi

  echo -e "
${B}USAGE${RESET}
    ./helm-namespace-health-standalone.sh [OPTIONS]

${B}DESCRIPTION${RESET}
    Standalone Helm namespace health checker — no kubie required.
    For every namespace that has at least one active Helm release, checks:

      ${G}✔${RESET}  Helm release status
      ${G}✔${RESET}  Deployment availability  (desired vs ready replicas)
      ${G}✔${RESET}  StatefulSet availability (desired vs ready replicas, revision match)
      ${G}✔${RESET}  Pod health               (phase, readiness, restart count)
      ${G}✔${RESET}  ExternalSecret sync status
      ${G}✔${RESET}  Kubernetes Secret existence (referenced by ExternalSecrets)
      ${G}✔${RESET}  Ingress health           (LB assigned, backend service exists)
      ${G}✔${RESET}  CronJob health           (suspended, last run result, stuck jobs)
      ${G}✔${RESET}  Warning events

${B}OPTIONS${RESET}
    ${C}-c, --context${RESET}   <ctx>   kubectl context name to use.
                            Default: current-context in the active kubeconfig.

    ${C}-n, --namespace${RESET} <ns>    Only check a specific namespace.
                            Default: all namespaces.

    ${C}-r, --restarts${RESET}  <n>     Restart count threshold to flag a pod as unhealthy.
                            Default: 5.

    ${C}-o, --output${RESET}    <fmt>   Output format: ${Y}pretty${RESET} | ${Y}json${RESET}.
                            Default: pretty.

    ${C}-h, --help${RESET}              Show this help message.

${B}ENVIRONMENT VARIABLES${RESET}
    ${Y}KUBECONFIG${RESET}   Path(s) to kubeconfig file(s), colon-separated.
                 When set, kubectl uses this instead of ~/.kube/config.
                 Can be combined with --context to select a specific context
                 within the merged config.

${B}EXAMPLES${RESET}
    ${B}# Use whatever context is currently active${RESET}
    ./helm-namespace-health-standalone.sh

    ${B}# Point to a specific kubeconfig file (its current-context is used)${RESET}
    KUBECONFIG=~/.kube/config-prod-core-002.yml \\
      ./helm-namespace-health-standalone.sh

    ${B}# Override the context within the active kubeconfig${RESET}
    ./helm-namespace-health-standalone.sh --context prod-core-002

    ${B}# Filter to a single namespace${RESET}
    ./helm-namespace-health-standalone.sh --namespace beneficiaries

    ${B}# Combine KUBECONFIG + namespace filter${RESET}
    KUBECONFIG=~/.kube/config-prod-core-002.yml \\
      ./helm-namespace-health-standalone.sh --namespace backoffice-pricing

    ${B}# Merge two configs and pick a specific context${RESET}
    KUBECONFIG=~/.kube/config-prod-core-001.yml:~/.kube/config-prod-core-002.yml \\
      ./helm-namespace-health-standalone.sh --context prod-core-001

    ${B}# Machine-readable JSON output${RESET}
    KUBECONFIG=~/.kube/config-prod-core-002.yml \\
      ./helm-namespace-health-standalone.sh --output json | jq '.[] | select(.healthy == false)'

    ${B}# Raise the restart alert threshold to 10${RESET}
    ./helm-namespace-health-standalone.sh --restarts 10

    ${B}# Sweep all clusters by looping over kubeconfig files${RESET}
    for cfg in ~/.kube/config-*.yml; do
      KUBECONFIG=\"\$cfg\" ./helm-namespace-health-standalone.sh
    done

    ${B}# Sweep all clusters and collect a combined JSON report${RESET}
    for cfg in ~/.kube/config-*.yml; do
      KUBECONFIG=\"\$cfg\" ./helm-namespace-health-standalone.sh --output json
    done | jq -s 'add'
"
  exit 0
}

log_header() {
  echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${BLUE}  $*${RESET}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════${RESET}"
}

log_section() {
  echo -e "\n  ${CYAN}${BOLD}▶ $*${RESET}"
}

log_ok()   { echo -e "    ${OK}  $*"; }
log_warn() { echo -e "    ${WARN}  $*"; }
log_fail() { echo -e "    ${FAIL}  $*"; }

# Run kubectl with an optional --context flag.
# KUBECONFIG is inherited from the environment automatically by kubectl.
kube() {
  if [[ -n "$CONTEXT" ]]; then
    kubectl --context="$CONTEXT" "$@" 2>/dev/null
  else
    kubectl "$@" 2>/dev/null
  fi
}

# ── JSON aggregator ───────────────────────────────────────────────────────────
JSON_OUTPUT="[]"

json_append() {
  JSON_OUTPUT=$(echo "$JSON_OUTPUT" | jq --argjson obj "$1" '. += [$obj]')
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--context)   CONTEXT="$2";           shift 2 ;;
    -n|--namespace) FILTER_NS="$2";         shift 2 ;;
    -r|--restarts)  RESTART_THRESHOLD="$2"; shift 2 ;;
    -o|--output)    OUTPUT_FORMAT="$2";     shift 2 ;;
    -h|--help)      usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# ── Validate dependencies ─────────────────────────────────────────────────────
for dep in kubectl jq; do
  if ! command -v "$dep" &>/dev/null; then
    echo "Error: '$dep' is required but not found in PATH." >&2
    exit 1
  fi
done

# Resolve the effective context name for display (falls back to current-context
# in the active kubeconfig when --context is not passed).
if [[ -z "$CONTEXT" ]]; then
  CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")
fi

# ── Resolve namespaces ────────────────────────────────────────────────────────
if [[ -n "$FILTER_NS" ]]; then
  NAMESPACES=("$FILTER_NS")
else
  ns_raw=$(kube get namespaces -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort)
  IFS=$'\n' read -r -d '' -a NAMESPACES <<< "$ns_raw" || true
fi

if [[ ${#NAMESPACES[@]} -eq 0 ]]; then
  echo "No namespaces found." >&2
  exit 1
fi

# ── Per-namespace check ───────────────────────────────────────────────────────
check_namespace() {
  local ns="$1"

  # ── Find deployed Helm releases ───────────────────────────────────────────
  local releases_raw
  releases_raw=$(kube get secret -n "$ns" \
    -l "owner=helm,status=deployed" \
    -o jsonpath='{range .items[*]}{.metadata.labels.name}{"\n"}{end}' \
    | sort -u)

  local RELEASES=()
  IFS=$'\n' read -r -d '' -a RELEASES <<< "$releases_raw" || true

  # Skip namespace if no active Helm releases
  if [[ ${#RELEASES[@]} -eq 0 ]]; then
    return
  fi

  # ── Collect namespace-wide data once (reduces API calls) ─────────────────
  local deployments statefulsets pods externalsecrets ingresses cronjobs jobs services events

  deployments=$(  kube get deployment    -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')
  statefulsets=$(  kube get statefulset  -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')
  pods=$(          kube get pod          -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')
  externalsecrets=$(kube get externalsecret -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')
  ingresses=$(     kube get ingress      -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')
  cronjobs=$(      kube get cronjob      -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')
  jobs=$(          kube get job          -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')
  services=$(      kube get service      -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')
  events=$(        kube get event        -n "$ns" \
    --field-selector type=Warning \
    -o json 2>/dev/null || echo '{"items":[]}')

  # ── Pretty output header ──────────────────────────────────────────────────
  if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
    log_header "Namespace: ${ns}  (context: ${CONTEXT})"
  fi

  for release in "${RELEASES[@]}"; do

    local ns_result
    ns_result=$(jq -n \
      --arg context "${CONTEXT:-current}" \
      --arg namespace "$ns" \
      --arg release  "$release" \
      '{context: $context, namespace: $namespace, release: $release, checks: {}}')

    if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
      log_section "Release: ${BOLD}${release}${RESET}"
    fi

    # ── 1. Helm release status ──────────────────────────────────────────────
    local helm_status helm_version helm_updated
    helm_status=$(kube get secret -n "$ns" \
      -l "owner=helm,status=deployed,name=${release}" \
      -o jsonpath='{.items[0].metadata.labels.status}' 2>/dev/null || echo "unknown")
    helm_version=$(kube get secret -n "$ns" \
      -l "owner=helm,status=deployed,name=${release}" \
      -o jsonpath='{.items[0].metadata.labels.version}' 2>/dev/null || echo "?")
    helm_updated=$(kube get secret -n "$ns" \
      -l "owner=helm,status=deployed,name=${release}" \
      -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null || echo "?")

    if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
      if [[ "$helm_status" == "deployed" ]]; then
        log_ok  "Helm release status: ${helm_status}  (revision: ${helm_version}, last deployed: ${helm_updated})"
      else
        log_fail "Helm release status: ${helm_status}  (revision: ${helm_version})"
      fi
    fi

    ns_result=$(echo "$ns_result" | jq \
      --arg status  "$helm_status" \
      --arg version "$helm_version" \
      --arg updated "$helm_updated" \
      '.checks.helm = {status: $status, revision: $version, lastDeployed: $updated, ok: ($status == "deployed")}')

    # ── 2. Deployments ─────────────────────────────────────────────────────
    if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
      echo -e "\n    ${BOLD}Deployments:${RESET}"
    fi

    local deploy_json deploy_check_list
    deploy_json=$(echo "$deployments" | jq --arg rel "$release" \
      '[.items[] | select(
          (.metadata.labels["app.kubernetes.io/instance"] // "" == $rel) or
          ((.metadata.labels["helm.sh/chart"] // "") | startswith($rel)) or
          (.metadata.name | startswith($rel))
       )]')
    deploy_check_list="[]"

    local deploy_count
    deploy_count=$(echo "$deploy_json" | jq 'length')

    if [[ "$deploy_count" -eq 0 ]]; then
      if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
        log_warn "No deployments found for release '${release}'"
      fi
      deploy_check_list=$(echo "$deploy_check_list" | jq \
        '. += [{name: "none", ok: null, warning: "no deployments found"}]')
    else
      while IFS=$'\t' read -r name desired ready available updated; do
        local deploy_ok=true deploy_msg=""
        desired=${desired:-0}; ready=${ready:-0}
        available=${available:-0}; updated=${updated:-0}

        if [[ "$ready" -lt "$desired" ]]; then
          deploy_ok=false
          deploy_msg="${ready}/${desired} replicas ready"
        elif [[ "$updated" -lt "$desired" ]]; then
          deploy_ok=false
          deploy_msg="${updated}/${desired} replicas updated (rollout in progress?)"
        else
          deploy_msg="${ready}/${desired} replicas ready"
        fi

        if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
          if $deploy_ok; then
            log_ok  "${name}: ${deploy_msg}"
          else
            log_fail "${name}: ${deploy_msg}"
          fi
        fi

        deploy_check_list=$(echo "$deploy_check_list" | jq \
          --arg n   "$name" \
          --argjson d "$desired" \
          --argjson r "$ready" \
          --argjson a "$available" \
          --argjson u "$updated" \
          --argjson ok "$($deploy_ok && echo true || echo false)" \
          --arg msg "$deploy_msg" \
          '. += [{name: $n, desired: $d, ready: $r, available: $a, updated: $u, ok: $ok, message: $msg}]')

      done < <(echo "$deploy_json" | jq -r '.[] |
        [.metadata.name,
         (.spec.replicas // 0),
         (.status.readyReplicas // 0),
         (.status.availableReplicas // 0),
         (.status.updatedReplicas // 0)
        ] | @tsv')
    fi

    ns_result=$(echo "$ns_result" | jq --argjson dl "$deploy_check_list" '.checks.deployments = $dl')

    # ── 3. StatefulSets ────────────────────────────────────────────────────
    if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
      echo -e "\n    ${BOLD}StatefulSets:${RESET}"
    fi

    local sts_json sts_check_list
    sts_json=$(echo "$statefulsets" | jq --arg rel "$release" \
      '[.items[] | select(
          (.metadata.labels["app.kubernetes.io/instance"] // "" == $rel) or
          ((.metadata.labels["helm.sh/chart"] // "") | startswith($rel)) or
          (.metadata.name | startswith($rel))
       )]')
    sts_check_list="[]"

    local sts_count
    sts_count=$(echo "$sts_json" | jq 'length')

    if [[ "$sts_count" -eq 0 ]]; then
      if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
        log_warn "No StatefulSets found for release '${release}'"
      fi
      sts_check_list=$(echo "$sts_check_list" | jq \
        '. += [{name: "none", ok: null, warning: "no StatefulSets found"}]')
    else
      while IFS=$'\t' read -r name desired ready current updated current_rev update_rev; do
        local sts_ok=true sts_msg="" sts_issues=""
        desired=${desired:-0}; ready=${ready:-0}
        current=${current:-0}; updated=${updated:-0}

        [[ "$ready"   -lt "$desired" ]] && sts_ok=false && sts_issues+="${ready}/${desired} replicas ready "
        [[ "$updated" -lt "$desired" ]] && sts_ok=false && sts_issues+="${updated}/${desired} replicas updated "
        [[ "$current_rev" != "$update_rev" ]] && sts_ok=false && sts_issues+="revision mismatch (rollout in progress?) "

        if $sts_ok; then
          sts_msg="${ready}/${desired} replicas ready  revision=${current_rev}"
        else
          sts_msg="${sts_issues% }"
        fi

        if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
          if $sts_ok; then
            log_ok  "${name}: ${sts_msg}"
          else
            log_fail "${name}: ${sts_msg}"
          fi
        fi

        sts_check_list=$(echo "$sts_check_list" | jq \
          --arg n    "$name" \
          --argjson d  "$desired" \
          --argjson r  "$ready" \
          --argjson cu "$current" \
          --argjson up "$updated" \
          --arg cr   "$current_rev" \
          --arg ur   "$update_rev" \
          --argjson ok "$($sts_ok && echo true || echo false)" \
          --arg msg  "$sts_msg" \
          '. += [{name: $n, desired: $d, ready: $r, current: $cu, updated: $up,
                  currentRevision: $cr, updateRevision: $ur, ok: $ok, message: $msg}]')

      done < <(echo "$sts_json" | jq -r '.[] |
        [.metadata.name,
         (.spec.replicas // 0),
         (.status.readyReplicas // 0),
         (.status.currentReplicas // 0),
         (.status.updatedReplicas // 0),
         (.status.currentRevision // "N/A"),
         (.status.updateRevision  // "N/A")
        ] | @tsv')
    fi

    ns_result=$(echo "$ns_result" | jq --argjson sl "$sts_check_list" '.checks.statefulSets = $sl')

    # ── 4. Pods ────────────────────────────────────────────────────────────
    if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
      echo -e "\n    ${BOLD}Pods:${RESET}"
    fi

    local pod_json pod_check_list
    pod_json=$(echo "$pods" | jq --arg rel "$release" \
      '[.items[] | select(
          (.metadata.labels["app.kubernetes.io/instance"] // "" == $rel) or
          (.metadata.name | startswith($rel))
       ) | select(.status.phase != "Succeeded")]')
    pod_check_list="[]"

    local pod_count
    pod_count=$(echo "$pod_json" | jq 'length')

    if [[ "$pod_count" -eq 0 ]]; then
      if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
        log_warn "No running pods found for release '${release}'"
      fi
      pod_check_list=$(echo "$pod_check_list" | jq \
        '. += [{name: "none", ok: null, warning: "no running pods found"}]')
    else
      while IFS=$'\t' read -r pod_name phase ready restarts container_name; do
        local pod_ok=true pod_msg="" pod_issues=""

        [[ "$phase"    != "Running" ]] && pod_ok=false && pod_issues+="phase=${phase} "
        [[ "$ready"    != "true"   ]] && pod_ok=false && pod_issues+="not-ready "
        [[ "$restarts" -ge "$RESTART_THRESHOLD" ]] && \
          pod_ok=false && pod_issues+="restarts=${restarts} "

        pod_msg="phase=${phase} ready=${ready} restarts=${restarts} container=${container_name}"
        [[ -n "$pod_issues" ]] && pod_msg+=" [${pod_issues% }]"

        if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
          if $pod_ok; then
            log_ok  "${pod_name}: ${pod_msg}"
          elif [[ "$restarts" -ge "$RESTART_THRESHOLD" ]]; then
            log_warn "${pod_name}: ${pod_msg}"
          else
            log_fail "${pod_name}: ${pod_msg}"
          fi
        fi

        pod_check_list=$(echo "$pod_check_list" | jq \
          --arg pn  "$pod_name" \
          --arg ph  "$phase" \
          --arg rd  "$ready" \
          --argjson rs "$restarts" \
          --arg cn  "$container_name" \
          --argjson ok "$($pod_ok && echo true || echo false)" \
          --arg msg "$pod_msg" \
          '. += [{name: $pn, phase: $ph, ready: $rd, restarts: $rs, container: $cn, ok: $ok, message: $msg}]')

      done < <(echo "$pod_json" | jq -r '.[] |
        .metadata.name as $pod |
        .status.phase as $phase |
        (.status.containerStatuses // []) | .[] |
        [$pod, $phase, (.ready | tostring), (.restartCount // 0), .name] | @tsv')
    fi

    ns_result=$(echo "$ns_result" | jq --argjson pl "$pod_check_list" '.checks.pods = $pl')

    # ── 5. ExternalSecrets ─────────────────────────────────────────────────
    if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
      echo -e "\n    ${BOLD}ExternalSecrets:${RESET}"
    fi

    local es_json es_check_list
    es_json=$(echo "$externalsecrets" | jq --arg rel "$release" \
      '[.items[] | select(.metadata.name | startswith($rel))]')
    es_check_list="[]"

    local es_count
    es_count=$(echo "$es_json" | jq 'length')

    if [[ "$es_count" -eq 0 ]]; then
      if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
        log_warn "No ExternalSecrets found for release '${release}'"
      fi
      es_check_list=$(echo "$es_check_list" | jq \
        '. += [{name: "none", ok: null, warning: "no ExternalSecrets found"}]')
    else
      while IFS=$'\t' read -r es_name es_ready es_reason es_message; do
        local es_ok=true
        [[ "$es_ready" != "True" ]] && es_ok=false

        if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
          if $es_ok; then
            log_ok  "${es_name}: Ready=${es_ready} (${es_reason})"
          else
            log_fail "${es_name}: Ready=${es_ready} reason=${es_reason} — ${es_message}"
          fi
        fi

        es_check_list=$(echo "$es_check_list" | jq \
          --arg n   "$es_name" \
          --arg rdy "$es_ready" \
          --arg rsn "$es_reason" \
          --arg msg "$es_message" \
          --argjson ok "$($es_ok && echo true || echo false)" \
          '. += [{name: $n, ready: $rdy, reason: $rsn, message: $msg, ok: $ok}]')

      done < <(echo "$es_json" | jq -r '.[] |
        .metadata.name as $name |
        (.status.conditions // []) |
        ( map(select(.type == "Ready")) | first )
          // {status: "Unknown", reason: "NoCondition", message: "no conditions reported"} |
        [$name, .status, .reason, .message] | @tsv')
    fi

    ns_result=$(echo "$ns_result" | jq --argjson esl "$es_check_list" '.checks.externalSecrets = $esl')

    # ── 6. Kubernetes Secrets referenced by ExternalSecrets ────────────────
    if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
      echo -e "\n    ${BOLD}Secrets (referenced by ExternalSecrets):${RESET}"
    fi

    local secret_check_list="[]"

    if [[ "$es_count" -gt 0 ]]; then
      while IFS=$'\t' read -r es_name secret_name; do
        [[ -z "$secret_name" ]] && continue
        local secret_exists
        secret_exists=$(kube get secret -n "$ns" "$secret_name" \
          -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

        local sec_ok=true
        [[ -z "$secret_exists" ]] && sec_ok=false

        if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
          if $sec_ok; then
            log_ok  "Secret '${secret_name}' (from ExternalSecret '${es_name}'): exists"
          else
            log_fail "Secret '${secret_name}' (from ExternalSecret '${es_name}'): NOT FOUND"
          fi
        fi

        secret_check_list=$(echo "$secret_check_list" | jq \
          --arg sn  "$secret_name" \
          --arg esn "$es_name" \
          --argjson ok "$($sec_ok && echo true || echo false)" \
          '. += [{name: $sn, fromExternalSecret: $esn, exists: $ok, ok: $ok}]')

      done < <(echo "$es_json" | jq -r '.[] |
        [.metadata.name, (.spec.target.name // .metadata.name)] | @tsv')
    else
      if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
        log_warn "Skipped — no ExternalSecrets to reference"
      fi
      secret_check_list=$(echo "$secret_check_list" | jq \
        '. += [{name: "none", ok: null, warning: "skipped, no ExternalSecrets"}]')
    fi

    ns_result=$(echo "$ns_result" | jq --argjson sl "$secret_check_list" '.checks.secrets = $sl')

    # ── 7. Ingresses ───────────────────────────────────────────────────────
    if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
      echo -e "\n    ${BOLD}Ingresses:${RESET}"
    fi

    local ing_json ing_check_list
    ing_json=$(echo "$ingresses" | jq --arg rel "$release" \
      '[.items[] | select(
          (.metadata.labels["app.kubernetes.io/instance"] // "" == $rel) or
          (.metadata.name | startswith($rel))
       )]')
    ing_check_list="[]"

    local ing_count
    ing_count=$(echo "$ing_json" | jq 'length')

    if [[ "$ing_count" -eq 0 ]]; then
      if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
        log_warn "No Ingresses found for release '${release}'"
      fi
      ing_check_list=$(echo "$ing_check_list" | jq \
        '. += [{name: "none", ok: null, warning: "no Ingresses found"}]')
    else
      # Collect all service names in the namespace for backend validation
      local svc_names
      svc_names=$(echo "$services" | jq -r '[.items[].metadata.name]')

      while IFS=$'\t' read -r ing_name ing_class ing_host lb_hostname tls_count; do
        local ing_ok=true ing_issues=""

        # Check 1 — LB has been assigned
        if [[ "$lb_hostname" == "no-lb-assigned" ]]; then
          ing_ok=false
          ing_issues+="no LB hostname assigned "
        fi

        # Check 2 — ingressClassName is set
        if [[ "$ing_class" == "N/A" || -z "$ing_class" ]]; then
          ing_issues+="no ingressClassName set "
          # treat as warning, not hard failure — keeps consistent with migration report
        fi

        # Check 3 — backend services exist
        local missing_backends
        missing_backends=$(echo "$ing_json" | jq -r --arg name "$ing_name" --argjson svcs "$svc_names" \
          '.[] | select(.metadata.name == $name) |
           .spec.rules[]?.http.paths[]?.backend.service.name // empty |
           select(. as $svc | $svcs | index($svc) == null)')

        if [[ -n "$missing_backends" ]]; then
          ing_ok=false
          while IFS= read -r svc; do
            ing_issues+="missing backend service '${svc}' "
          done <<< "$missing_backends"
        fi

        local tls_info=""
        [[ "$tls_count" -gt 0 ]] && tls_info=" tls=${tls_count}cert(s)"

        local ing_msg
        if $ing_ok; then
          ing_msg="class=${ing_class} host=${ing_host} lb=${lb_hostname}${tls_info}"
          [[ -n "$ing_issues" ]] && ing_msg+=" [${ing_issues% }]"
        else
          ing_msg="class=${ing_class} host=${ing_host} [${ing_issues% }]"
        fi

        if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
          if $ing_ok && [[ -z "$ing_issues" ]]; then
            log_ok   "${ing_name}: ${ing_msg}"
          elif $ing_ok && [[ -n "$ing_issues" ]]; then
            log_warn "${ing_name}: ${ing_msg}"
          else
            log_fail "${ing_name}: ${ing_msg}"
          fi
        fi

        ing_check_list=$(echo "$ing_check_list" | jq \
          --arg n    "$ing_name" \
          --arg cls  "$ing_class" \
          --arg host "$ing_host" \
          --arg lb   "$lb_hostname" \
          --argjson tls "$tls_count" \
          --argjson ok "$($ing_ok && echo true || echo false)" \
          --arg msg  "$ing_msg" \
          '. += [{name: $n, class: $cls, host: $host, lb: $lb, tlsCerts: $tls, ok: $ok, message: $msg}]')

      done < <(echo "$ing_json" | jq -r '.[] |
        [.metadata.name,
         (.spec.ingressClassName // "N/A"),
         (.spec.rules[0]?.host  // "N/A"),
         (.status.loadBalancer.ingress[0]?.hostname // .status.loadBalancer.ingress[0]?.ip // "no-lb-assigned"),
         (.spec.tls // [] | length)
        ] | @tsv')
    fi

    ns_result=$(echo "$ns_result" | jq --argjson il "$ing_check_list" '.checks.ingresses = $il')

    # ── 8. CronJobs ────────────────────────────────────────────────────────
    if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
      echo -e "\n    ${BOLD}CronJobs:${RESET}"
    fi

    local cj_json cj_check_list
    cj_json=$(echo "$cronjobs" | jq --arg rel "$release" \
      '[.items[] | select(
          (.metadata.labels["app.kubernetes.io/instance"] // "" == $rel) or
          (.metadata.name | startswith($rel))
       )]')
    cj_check_list="[]"

    local cj_count
    cj_count=$(echo "$cj_json" | jq 'length')

    if [[ "$cj_count" -eq 0 ]]; then
      if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
        log_warn "No CronJobs found for release '${release}'"
      fi
      cj_check_list=$(echo "$cj_check_list" | jq \
        '. += [{name: "none", ok: null, warning: "no CronJobs found"}]')
    else
      # Build a lookup of the most recent job per cronjob from the jobs list
      local last_jobs
      last_jobs=$(echo "$jobs" | jq '
        [.items[]
          | select(.metadata.ownerReferences != null)
          | select(.metadata.ownerReferences[] | .kind == "CronJob")
          | {
              cronjob:    (.metadata.ownerReferences[] | select(.kind=="CronJob") | .name),
              job:        .metadata.name,
              succeeded:  (.status.succeeded  // 0),
              failed:     (.status.failed     // 0),
              active:     (.status.active     // 0),
              startTime:  (.status.startTime  // ""),
              finishTime: (.status.completionTime // "in-progress")
            }
        ]
        | group_by(.cronjob)[]
        | sort_by(.startTime)
        | last')

      while IFS=$'\t' read -r cj_name schedule suspended last_schedule last_success active_count; do
        local cj_ok=true cj_issues="" cj_msg=""

        # Check 1 — not suspended
        if [[ "$suspended" == "true" ]]; then
          cj_ok=false
          cj_issues+="SUSPENDED "
        fi

        # Check 2 — last run result (look up most recent job)
        local last_job_info
        last_job_info=$(echo "$last_jobs" | jq -r \
          --arg cj "$cj_name" \
          'if type == "array" then
             .[] | select(.cronjob == $cj)
           else
             select(.cronjob == $cj)
           end |
           [.job, (.succeeded|tostring), (.failed|tostring), (.active|tostring), .finishTime] | @tsv' \
          2>/dev/null || echo "")

        if [[ -n "$last_job_info" ]]; then
          local lj_name lj_succeeded lj_failed lj_active lj_finish
          IFS=$'\t' read -r lj_name lj_succeeded lj_failed lj_active lj_finish <<< "$last_job_info"

          if [[ "$lj_failed" -gt 0 && "$lj_succeeded" -eq 0 && "$lj_active" -eq 0 ]]; then
            cj_ok=false
            cj_issues+="last job failed (${lj_name} failed=${lj_failed}) "
          fi
          if [[ "$lj_active" -gt 0 && "$lj_finish" == "in-progress" ]]; then
            # active job — treat as warning not failure (could be legitimately running)
            cj_issues+="job running (${lj_name}) "
          fi
        fi

        # Check 3 — never ran (no lastScheduleTime)
        if [[ "$last_schedule" == "never" ]]; then
          cj_issues+="never scheduled "
        fi

        if $cj_ok; then
          cj_msg="schedule='${schedule}' suspended=${suspended} lastSchedule=${last_schedule} lastSuccess=${last_success}"
          [[ -n "$cj_issues" ]] && cj_msg+=" [${cj_issues% }]"
        else
          cj_msg="schedule='${schedule}' [${cj_issues% }]"
        fi

        if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
          if $cj_ok && [[ -z "$cj_issues" ]]; then
            log_ok   "${cj_name}: ${cj_msg}"
          elif $cj_ok && [[ -n "$cj_issues" ]]; then
            log_warn "${cj_name}: ${cj_msg}"
          else
            log_fail "${cj_name}: ${cj_msg}"
          fi
        fi

        cj_check_list=$(echo "$cj_check_list" | jq \
          --arg n    "$cj_name" \
          --arg sch  "$schedule" \
          --arg susp "$suspended" \
          --arg ls   "$last_schedule" \
          --arg lsuc "$last_success" \
          --argjson ac "$active_count" \
          --argjson ok "$($cj_ok && echo true || echo false)" \
          --arg msg  "$cj_msg" \
          '. += [{name: $n, schedule: $sch, suspended: $susp, lastSchedule: $ls,
                  lastSuccess: $lsuc, activeJobs: $ac, ok: $ok, message: $msg}]')

      done < <(echo "$cj_json" | jq -r '.[] |
        [.metadata.name,
         .spec.schedule,
         (.spec.suspend // false | tostring),
         (.status.lastScheduleTime     // "never"),
         (.status.lastSuccessfulTime   // "never"),
         (.status.active // [] | length)
        ] | @tsv')
    fi

    ns_result=$(echo "$ns_result" | jq --argjson cl "$cj_check_list" '.checks.cronJobs = $cl')

    # ── 9. Warning events ──────────────────────────────────────────────────
    if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
      echo -e "\n    ${BOLD}Warning Events:${RESET}"
    fi

    local warn_json warn_check_list
    warn_json=$(echo "$events" | jq --arg rel "$release" \
      '[.items[] | select(
          ((.involvedObject.name // "") | startswith($rel)) or
          ((.involvedObject.name // "") | contains($rel))
       )]')
    warn_check_list="[]"

    local warn_count
    warn_count=$(echo "$warn_json" | jq 'length')

    if [[ "$warn_count" -eq 0 ]]; then
      if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
        log_ok "No warning events"
      fi
    else
      if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
        log_warn "${warn_count} warning event(s) found:"
      fi

      while IFS=$'\t' read -r obj_kind obj_name reason message count last_time; do
        if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
          log_warn "  [${obj_kind}/${obj_name}] ${reason}: ${message} (x${count} last: ${last_time})"
        fi

        warn_check_list=$(echo "$warn_check_list" | jq \
          --arg kind    "$obj_kind" \
          --arg obj     "$obj_name" \
          --arg reason  "$reason" \
          --arg msg     "$message" \
          --argjson cnt "$count" \
          --arg last    "$last_time" \
          '. += [{kind: $kind, object: $obj, reason: $reason, message: $msg, count: $cnt, lastTime: $last}]')
      done < <(echo "$warn_json" | jq -r '.[] |
        [.involvedObject.kind,
         .involvedObject.name,
         .reason,
         .message,
         (.count // 1),
         (.lastTimestamp // .eventTime // "unknown")
        ] | @tsv')
    fi

    ns_result=$(echo "$ns_result" | jq \
      --argjson wl "$warn_check_list" \
      --argjson wc "$warn_count" \
      '.checks.warningEvents = {count: $wc, events: $wl}')

    # ── 10. Overall release health ─────────────────────────────────────────
    local overall_ok
    overall_ok=$(echo "$ns_result" | jq '
      .checks.helm.ok == true and
      ([.checks.deployments[]  | select(.ok != null) | .ok] | all) and
      ([.checks.statefulSets[] | select(.ok != null) | .ok] | all) and
      ([.checks.pods[]         | select(.ok != null) | .ok] | all) and
      ([.checks.externalSecrets[] | select(.ok != null) | .ok] | all) and
      ([.checks.secrets[]      | select(.ok != null) | .ok] | all) and
      ([.checks.ingresses[]    | select(.ok != null) | .ok] | all) and
      ([.checks.cronJobs[]     | select(.ok != null) | .ok] | all)
    ')

    ns_result=$(echo "$ns_result" | jq --argjson ok "$overall_ok" '.healthy = $ok')

    if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
      echo ""
      if [[ "$overall_ok" == "true" ]]; then
        echo -e "    ${GREEN}${BOLD}● Release '${release}' is HEALTHY${RESET}"
      else
        echo -e "    ${RED}${BOLD}● Release '${release}' has ISSUES${RESET}"
      fi
    fi

    json_append "$ns_result"

  done # releases
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║       Helm Namespace Health Check                ║"
    echo "  ║       Context    : ${CONTEXT}"
    echo "  ║       Kubeconfig : ${KUBECONFIG_DISPLAY}"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${RESET}"
  fi

  local checked=0
  for ns in "${NAMESPACES[@]}"; do
    check_namespace "$ns"
    ((checked++)) || true
  done

  if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
    local total_releases healthy_releases unhealthy_releases
    total_releases=$(    echo "$JSON_OUTPUT" | jq 'length')
    healthy_releases=$(  echo "$JSON_OUTPUT" | jq '[.[] | select(.healthy == true)]  | length')
    unhealthy_releases=$(echo "$JSON_OUTPUT" | jq '[.[] | select(.healthy == false)] | length')

    echo ""
    log_header "Summary  (context: ${CONTEXT})"
    echo -e "  Namespaces scanned : ${checked}"
    echo -e "  Releases found     : ${total_releases}"
    echo -e "  ${GREEN}Healthy            : ${healthy_releases}${RESET}"
    if [[ "$unhealthy_releases" -gt 0 ]]; then
      echo -e "  ${RED}Unhealthy          : ${unhealthy_releases}${RESET}"
      echo ""
      echo -e "  ${RED}${BOLD}Unhealthy releases:${RESET}"
      echo "$JSON_OUTPUT" | jq -r \
        '.[] | select(.healthy == false) | "  \(.context) / \(.namespace) / \(.release)"'
    else
      echo -e "  Unhealthy          : 0"
    fi
    echo ""
  else
    echo "$JSON_OUTPUT" | jq '.'
  fi
}

main
