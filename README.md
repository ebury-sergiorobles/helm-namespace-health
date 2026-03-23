# helm-namespace-health


This script help to check all the resources under a namespace where we have applied a helm release.

Help into the script (need bash) and it will run pointing to the current kubectl context or KUBECONFIG env var.

#(Use it under your risk)



USAGE
    ./helm-namespace-health-standalone.sh [OPTIONS]

DESCRIPTION
    Standalone Helm namespace health checker — no kubie required.
    For every namespace that has at least one active Helm release, checks:

      ✔  Helm release status
      ✔  Deployment availability  (desired vs ready replicas)
      ✔  StatefulSet availability (desired vs ready replicas, revision match)
      ✔  Pod health               (phase, readiness, restart count)
      ✔  ExternalSecret sync status
      ✔  Kubernetes Secret existence (referenced by ExternalSecrets)
      ✔  Ingress health           (LB assigned, backend service exists)
      ✔  CronJob health           (suspended, last run result, stuck jobs)
      ✔  Warning events

OPTIONS
    -c, --context   <ctx>   kubectl context name to use.
                            Default: current-context in the active kubeconfig.

    -n, --namespace <ns>    Only check a specific namespace.
                            Default: all namespaces.

    -r, --restarts  <n>     Restart count threshold to flag a pod as unhealthy.
                            Default: 5.

    -o, --output    <fmt>   Output format: pretty | json.
                            Default: pretty.

    -h, --help              Show this help message.

ENVIRONMENT VARIABLES
    KUBECONFIG   Path(s) to kubeconfig file(s), colon-separated.
                 When set, kubectl uses this instead of ~/.kube/config.
                 Can be combined with --context to select a specific context
                 within the merged config.

EXAMPLES
    # Use whatever context is currently active
    ./helm-namespace-health-standalone.sh

    # Point to a specific kubeconfig file (its current-context is used)
    KUBECONFIG=~/.kube/config-prod-core-002.yml \
      ./helm-namespace-health-standalone.sh

    # Override the context within the active kubeconfig
    ./helm-namespace-health-standalone.sh --context prod-core-002

    # Filter to a single namespace
    ./helm-namespace-health-standalone.sh --namespace beneficiaries

    # Combine KUBECONFIG + namespace filter
    KUBECONFIG=~/.kube/config-prod-core-002.yml \
      ./helm-namespace-health-standalone.sh --namespace backoffice-pricing

    # Merge two configs and pick a specific context
    KUBECONFIG=~/.kube/config-prod-core-001.yml:~/.kube/config-prod-core-002.yml \
      ./helm-namespace-health-standalone.sh --context prod-core-001

    # Machine-readable JSON output
    KUBECONFIG=~/.kube/config-prod-core-002.yml \
      ./helm-namespace-health-standalone.sh --output json | jq '.[] | select(.healthy == false)'

    # Raise the restart alert threshold to 10
    ./helm-namespace-health-standalone.sh --restarts 10

    # Sweep all clusters by looping over kubeconfig files
    for cfg in ~/.kube/config-*.yml; do
      KUBECONFIG="$cfg" ./helm-namespace-health-standalone.sh
    done

    # Sweep all clusters and collect a combined JSON report
    for cfg in ~/.kube/config-*.yml; do
      KUBECONFIG="$cfg" ./helm-namespace-health-standalone.sh --output json
    done | jq -s 'add'

