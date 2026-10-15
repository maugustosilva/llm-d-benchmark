#!/usr/bin/env bash
# Download a HuggingFace model to a hostPath directory on ONE node (the
# "seed" pod), then fan it out to every other node with a DaemonSet that
# rsyncs from the seed pod. Only one node ever talks to HuggingFace.
#
# Only nodes where the hostPath directory is an actual mount point (e.g. a
# dedicated NVMe mounted at /var/model-cache) are used: a probe DaemonSet
# checks the host's /proc/1/mountinfo first, and both the seed and the sync
# DaemonSet are pinned to the nodes that pass.
#
# Layout on every node: <host-path>/models/<HF_MODEL_ID>/ plus a
# .download-complete marker (same layout the standup hostPath download uses).
#
# With --pv, the seed pod first downloads into a PVC bound to that PV (same
# models/<HF_MODEL_ID>/ layout and marker), then copies it to the seed node's
# hostPath. The PVC is kept after the run, so the PV acts as a persistent
# cache: a later run that finds the model on it skips the HF download.
#
# Usage:
#   util/distribute_model_hostpath.sh -m <hf-model-id> [options]
#
# Options:
#   -m, --model ID            HuggingFace model id (required), e.g. facebook/opt-125m
#   -n, --namespace NS        Namespace (default: current kubectl context namespace)
#   -s, --seed-node NODE      Node that downloads from HF (default: first node with the mount)
#   -p, --host-path DIR       hostPath mount point on the nodes (default: /var/model-cache)
#   -l, --node-selector K=V   Only consider nodes with this label (repeatable)
#   -v, --pv NAME             Download to a PVC bound to this (Filesystem) PV first, then
#                             copy to the hostPath. The PVC (model-seed-<NAME>) is created
#                             if missing and never deleted by this script. If the PV has
#                             node affinity and --seed-node is not set, the scheduler picks
#                             the seed among the mounted nodes the PV can attach to.
#   -t, --hf-secret NAME      Secret holding key HF_TOKEN (default: llm-d-hf-token).
#                             Created from $HF_TOKEN if it does not exist.
#   -a, --service-account SA  Service account for the pods (default: default)
#   -i, --image IMAGE         Image with hf, rsync and chcon (default: ghcr.io/llm-d/llm-d-benchmark:nightly)
#   -c, --max-connections N   Concurrent rsync clients the seed serves (default: 4)
#   -T, --timeout DURATION    Wait timeout for download and sync (default: 3600s)
#   -k, --keep                Keep seed pod and DaemonSet after the sync finishes
#   -d, --delete              Only delete the seed pod and DaemonSets, then exit
#   -D, --dry-run             Run the (read-only) mount probe, then print the seed pod and
#                             sync DaemonSet manifests and validate them with
#                             'kubectl apply --dry-run=server' instead of applying them
#   -h, --help                Show this help

set -euo pipefail

MODEL=""
NAMESPACE=$(kubectl config view --minify -o 'jsonpath={..namespace}' 2>/dev/null || true)
NAMESPACE=${NAMESPACE:-default}
SEED_NODE=""
HOST_PATH=/var/model-cache
NODE_SELECTORS=()
PV_NAME=""
HF_SECRET=llm-d-hf-token #pragma: allowlist secret
SERVICE_ACCOUNT=default
IMAGE=ghcr.io/llm-d/llm-d-benchmark:nightly
MAX_CONNECTIONS=4
RSYNC_PORT=8873
TIMEOUT=3600s
KEEP=0
DELETE_ONLY=0
DRY_RUN=0

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model) MODEL=$2; shift 2 ;;
    -n|--namespace) NAMESPACE=$2; shift 2 ;;
    -s|--seed-node) SEED_NODE=$2; shift 2 ;;
    -p|--host-path) HOST_PATH=$2; shift 2 ;;
    -l|--node-selector) NODE_SELECTORS+=("$2"); shift 2 ;;
    -v|--pv) PV_NAME=$2; shift 2 ;;
    -t|--hf-secret) HF_SECRET=$2; shift 2 ;;
    -a|--service-account) SERVICE_ACCOUNT=$2; shift 2 ;;
    -i|--image) IMAGE=$2; shift 2 ;;
    -c|--max-connections) MAX_CONNECTIONS=$2; shift 2 ;;
    -T|--timeout) TIMEOUT=$2; shift 2 ;;
    -k|--keep) KEEP=1; shift ;;
    -d|--delete) DELETE_ONLY=1; shift ;;
    -D|--dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

KCMD="kubectl -n ${NAMESPACE}"
SEED_POD=model-seed
DS_NAME=model-sync-ds
PROBE_DS_NAME=model-mount-probe
LABEL_SELECTOR="app=llm-d-benchmark-harness,component=model-distribute"
PVC_NAME=${PV_NAME:+model-seed-${PV_NAME}}

cleanup() {
  echo "==> Deleting seed pod ${SEED_POD} and DaemonSets ${DS_NAME}, ${PROBE_DS_NAME} in ${NAMESPACE}"
  ${KCMD} delete daemonset "${DS_NAME}" "${PROBE_DS_NAME}" --ignore-not-found --wait=true
  ${KCMD} delete pod "${SEED_POD}" --ignore-not-found --wait=true
  # Deleting a DaemonSet does not wait for its pods; wait so a rerun never
  # sees (or verifies through) a previous run's terminating pods.
  ${KCMD} wait --for=delete pod -l component=model-distribute --timeout=120s 2>/dev/null || true
}

# Apply the manifest on stdin. In --dry-run, print it and have the API
# server validate it (schema, admission/SCC) without persisting anything.
apply_manifest() {
  if [[ ${DRY_RUN} -eq 1 ]]; then
    local manifest
    manifest=$(cat)
    printf -- '---\n%s\n' "${manifest}"
    printf '%s\n' "${manifest}" | ${KCMD} apply --dry-run=server -f - >&2
  else
    ${KCMD} apply -f -
  fi
}

if [[ ${DELETE_ONLY} -eq 1 ]]; then
  cleanup
  exit 0
fi

if [[ -z "${MODEL}" ]]; then
  echo "ERROR: --model is required" >&2
  usage 1
fi
MODEL_PATH="models/${MODEL}"

# --- PV: validate before touching the nodes --------------------------------
if [[ -n "${PV_NAME}" ]]; then
  PV_INFO=$(kubectl get pv "${PV_NAME}" -o 'jsonpath={.status.phase}|{.spec.claimRef.namespace}|{.spec.claimRef.name}|{.spec.volumeMode}|{.spec.storageClassName}|{.spec.capacity.storage}|{.spec.accessModes}' 2>/dev/null) || {
    echo "ERROR: PV ${PV_NAME} not found" >&2
    exit 1
  }
  IFS='|' read -r PV_PHASE PV_CLAIM_NS PV_CLAIM_NAME PV_VOLUME_MODE PV_STORAGE_CLASS PV_CAPACITY PV_ACCESS_MODES <<< "${PV_INFO}"
  if [[ "${PV_VOLUME_MODE:-Filesystem}" != "Filesystem" ]]; then
    echo "ERROR: PV ${PV_NAME} has volumeMode ${PV_VOLUME_MODE}; only Filesystem is supported" >&2
    exit 1
  fi
  if [[ -n "${PV_CLAIM_NAME}" && "${PV_CLAIM_NS}/${PV_CLAIM_NAME}" != "${NAMESPACE}/${PVC_NAME}" ]]; then
    echo "ERROR: PV ${PV_NAME} (${PV_PHASE}) is claimed by ${PV_CLAIM_NS}/${PV_CLAIM_NAME}, not ${NAMESPACE}/${PVC_NAME}" >&2
    if [[ "${PV_PHASE}" == "Released" ]]; then
      echo "       If that claim is gone and the data may be reused, free the PV with:" >&2
      echo "       kubectl patch pv ${PV_NAME} --type json -p '[{\"op\":\"remove\",\"path\":\"/spec/claimRef\"}]'" >&2
    fi
    exit 1
  fi
  if [[ "${PV_PHASE}" == "Released" || "${PV_PHASE}" == "Failed" ]]; then
    echo "ERROR: PV ${PV_NAME} is ${PV_PHASE}; it cannot be bound until its claimRef is cleared" >&2
    exit 1
  fi
fi

# --- HF token secret -------------------------------------------------------
if ! ${KCMD} get secret "${HF_SECRET}" >/dev/null 2>&1; then
  if [[ -z "${HF_TOKEN:-}" ]]; then
    echo "ERROR: secret ${HF_SECRET} not found in ${NAMESPACE} and HF_TOKEN is not set" >&2
    exit 1
  fi
  if [[ ${DRY_RUN} -eq 1 ]]; then
    echo "==> [dry-run] Would create secret ${HF_SECRET} from \$HF_TOKEN"
  else
    echo "==> Creating secret ${HF_SECRET} from \$HF_TOKEN"
    ${KCMD} create secret generic "${HF_SECRET}" --from-literal=HF_TOKEN="${HF_TOKEN}"
  fi
fi

# --- Probe: which nodes have HOST_PATH as a real mount point --------------
# A hostPath with DirectoryOrCreate would silently land on the root disk of
# nodes without the dedicated mount, so find the mounted nodes first. The
# probe mounts nothing; it only reads the host's mount table (hostPID).
NODE_SELECTOR_YAML=""
if [[ ${#NODE_SELECTORS[@]} -gt 0 ]]; then
  NODE_SELECTOR_YAML="      nodeSelector:"
  for kv in "${NODE_SELECTORS[@]}"; do
    NODE_SELECTOR_YAML+=$'\n'"        \"${kv%%=*}\": \"${kv#*=}\""
  done
fi

echo "==> Probing nodes for a mount at ${HOST_PATH}"
cat <<EOF | ${KCMD} apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${PROBE_DS_NAME}
  labels:
    app: llm-d-benchmark-harness
    component: model-distribute
    role: probe
spec:
  selector:
    matchLabels:
      app: llm-d-benchmark-harness
      component: model-distribute
      role: probe
  template:
    metadata:
      labels:
        app: llm-d-benchmark-harness
        component: model-distribute
        role: probe
    spec:
${NODE_SELECTOR_YAML}
      hostPID: true
      serviceAccountName: ${SERVICE_ACCOUNT}
      terminationGracePeriodSeconds: 0
      containers:
      - name: probe
        image: ${IMAGE}
        imagePullPolicy: IfNotPresent
        securityContext:
          privileged: true
        command: ["/bin/sh", "-c"]
        args:
        - |
          if awk -v p="${HOST_PATH}" '\$5 == p { found = 1 } END { exit !found }' /proc/1/mountinfo; then
            echo MOUNTED
          else
            echo NOT_MOUNTED
          fi
          exec sleep infinity
EOF

if ! ${KCMD} rollout status "daemonset/${PROBE_DS_NAME}" --timeout=300s; then
  echo "WARNING: not every probe pod started; nodes without a running probe are skipped" >&2
fi

MOUNTED_NODES=()
UNMOUNTED_NODES=()
while read -r pod node; do
  [[ -z "${pod}" ]] && continue
  if [[ "$(${KCMD} logs "${pod}" 2>/dev/null | head -1)" == "MOUNTED" ]]; then
    MOUNTED_NODES+=("${node}")
  else
    UNMOUNTED_NODES+=("${node}")
  fi
done < <(${KCMD} get pods -l role=probe,component=model-distribute \
           --field-selector=status.phase=Running \
           -o 'jsonpath={range .items[*]}{.metadata.name} {.spec.nodeName}{"\n"}{end}' | sort -k2)
${KCMD} delete daemonset "${PROBE_DS_NAME}" --ignore-not-found --wait=true

if [[ ${#UNMOUNTED_NODES[@]} -gt 0 ]]; then
  echo "==> Skipping nodes without a mount at ${HOST_PATH}: ${UNMOUNTED_NODES[*]}"
fi
if [[ ${#MOUNTED_NODES[@]} -eq 0 ]]; then
  echo "ERROR: no schedulable node has a mount at ${HOST_PATH}" >&2
  exit 1
fi
echo "==> Nodes with ${HOST_PATH} mounted (${#MOUNTED_NODES[@]}): ${MOUNTED_NODES[*]}"

# --- Seed node -------------------------------------------------------------
if [[ -n "${SEED_NODE}" && " ${MOUNTED_NODES[*]} " != *" ${SEED_NODE} "* ]]; then
  echo "ERROR: seed node ${SEED_NODE} does not have a mount at ${HOST_PATH}" >&2
  exit 1
fi

# Without a PV, pin the seed with nodeName. With a PV, let the scheduler
# place it among the candidates so the PV's own node affinity (e.g. a local
# PV) is honoured; nodeName would bypass that check.
if [[ -z "${PV_NAME}" ]]; then
  SEED_NODE=${SEED_NODE:-${MOUNTED_NODES[0]}}
  SEED_PLACEMENT_YAML="  nodeName: ${SEED_NODE}"
else
  if [[ -n "${SEED_NODE}" ]]; then
    SEED_CANDIDATES=("${SEED_NODE}")
  else
    SEED_CANDIDATES=("${MOUNTED_NODES[@]}")
  fi
  SEED_PLACEMENT_YAML="  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:"
  for node in "${SEED_CANDIDATES[@]}"; do
    SEED_PLACEMENT_YAML+="
        - matchFields:
          - key: metadata.name
            operator: In
            values: [\"${node}\"]"
  done
fi

echo "==> Model:      ${MODEL}"
echo "==> Namespace:  ${NAMESPACE}"
echo "==> Seed node:  ${SEED_NODE:-<scheduler picks a mounted node the PV can attach to>}"
echo "==> Host path:  ${HOST_PATH}/${MODEL_PATH}"
if [[ -n "${PV_NAME}" ]]; then
  echo "==> PV:         ${PV_NAME} (${PV_CAPACITY}) via PVC ${PVC_NAME}"
fi

# Serving pods mount the node directory directly, so on SELinux nodes the
# files need a label non-spc_t containers can read. Non-SELinux nodes reject
# chcon; that is not an error there.
RELABEL='chcon -R -t container_file_t /var/model-cache || echo "chcon failed (SELinux not enabled?); continuing."'

# --- Seed download step ----------------------------------------------------
# Spliced into the seed pod script's download branch below (8-space indent;
# the heredoc does not re-expand the ${...} inside it).
if [[ -z "${PV_NAME}" ]]; then
  SEED_DOWNLOAD='        echo "Downloading model to ${TARGET_DIR}..."
        mkdir -p "${TARGET_DIR}"
        hf download "${HF_MODEL_ID}" --local-dir "${TARGET_DIR}"'
  SEED_PVC_MOUNT_YAML=""
  SEED_PVC_VOLUME_YAML=""
else
  # Download to the PVC (skipped when an earlier run left the model there),
  # then copy to the hostPath. --inplace avoids a 2x temp copy of shards.
  SEED_DOWNLOAD='        PVC_DIR="/var/model-pvc/${MODEL_PATH}"
        if [ -f "${PVC_DIR}/.download-complete" ]; then
          echo "Model already present on PVC at ${PVC_DIR}, skipping HF download."
        else
          echo "Downloading model to PVC at ${PVC_DIR}..."
          mkdir -p "${PVC_DIR}"
          hf download "${HF_MODEL_ID}" --local-dir "${PVC_DIR}"
          touch "${PVC_DIR}/.download-complete"
        fi
        echo "Copying model from PVC to ${TARGET_DIR}..."
        mkdir -p "${TARGET_DIR}"
        rsync -a --inplace --exclude=.download-complete "${PVC_DIR}/" "${TARGET_DIR}/"'
  SEED_PVC_MOUNT_YAML="
    - name: model-pvc-storage
      mountPath: /var/model-pvc"
  SEED_PVC_VOLUME_YAML="
  - name: model-pvc-storage
    persistentVolumeClaim:
      claimName: ${PVC_NAME}"

  # --- PVC pre-bound to the PV (reused across runs) ------------------------
  if ${KCMD} get pvc "${PVC_NAME}" >/dev/null 2>&1; then
    echo "==> Reusing PVC ${PVC_NAME}"
  else
    echo "==> Creating PVC ${PVC_NAME} bound to PV ${PV_NAME}"
    # An empty storageClassName must be explicit, or the default class
    # would be injected and the PVC would never match the PV.
    cat <<EOF | apply_manifest
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  labels:
    app: llm-d-benchmark-harness
    component: model-distribute
spec:
  volumeName: ${PV_NAME}
  storageClassName: "${PV_STORAGE_CLASS}"
  accessModes: ${PV_ACCESS_MODES}
  volumeMode: Filesystem
  resources:
    requests:
      storage: ${PV_CAPACITY}
EOF
  fi
  if [[ ${DRY_RUN} -eq 0 ]] && ! ${KCMD} wait --for=jsonpath='{.status.phase}'=Bound "pvc/${PVC_NAME}" --timeout=120s; then
    echo "ERROR: PVC ${PVC_NAME} did not bind to PV ${PV_NAME}:" >&2
    ${KCMD} describe pvc "${PVC_NAME}" | tail -n 15 >&2 || true
    exit 1
  fi
fi

# --- Seed pod: download from HF, then serve over rsync daemon -------------
cat <<EOF | apply_manifest
apiVersion: v1
kind: Pod
metadata:
  name: ${SEED_POD}
  labels:
    app: llm-d-benchmark-harness
    component: model-distribute
    role: seed
spec:
${SEED_PLACEMENT_YAML}
  restartPolicy: Always
  serviceAccountName: ${SERVICE_ACCOUNT}
  # The container idles in 'sleep infinity', which ignores SIGTERM.
  terminationGracePeriodSeconds: 5
  securityContext:
    seLinuxOptions:
      type: spc_t
  containers:
  - name: seed
    image: ${IMAGE}
    imagePullPolicy: IfNotPresent
    # Explicitly privileged so OpenShift admits it under the privileged SCC
    # (otherwise a more restrictive SCC with a read-only rootfs may win).
    securityContext:
      privileged: true
    command: ["/bin/sh", "-c"]
    args:
    - |
      set -e
      TARGET_DIR="/var/model-cache/\${MODEL_PATH}"
      MARKER="\${TARGET_DIR}/.download-complete"
      if [ -f "\${MARKER}" ]; then
        echo "Model already present at \${TARGET_DIR}, skipping download."
      else
${SEED_DOWNLOAD}
        echo "Relabelling for non-spc_t readers..."
        ${RELABEL}
        touch "\${MARKER}"
        echo "Download complete."
      fi
      cat > /tmp/rsyncd.conf <<CONF
      pid file = /tmp/rsyncd.pid
      lock file = /tmp/rsyncd.lock
      use chroot = no
      uid = 0
      gid = 0
      port = ${RSYNC_PORT}
      max connections = ${MAX_CONNECTIONS}
      [models]
        path = /var/model-cache/models
        read only = yes
        list = yes
      CONF
      echo "Serving /var/model-cache/models over rsync on port ${RSYNC_PORT}"
      exec rsync --daemon --no-detach --log-file=/dev/stdout --config=/tmp/rsyncd.conf
    env:
    - name: MODEL_PATH
      value: ${MODEL_PATH}
    - name: HF_MODEL_ID
      value: ${MODEL}
    - name: HF_HOME
      value: /tmp/huggingface
    - name: HOME
      value: /tmp
    - name: HF_TOKEN
      valueFrom:
        secretKeyRef:
          name: ${HF_SECRET}
          key: HF_TOKEN
    ports:
    - name: rsync
      containerPort: ${RSYNC_PORT}
    readinessProbe:
      tcpSocket:
        port: ${RSYNC_PORT}
      periodSeconds: 10
    volumeMounts:
    - name: model-host-storage
      mountPath: /var/model-cache${SEED_PVC_MOUNT_YAML}
  volumes:
  - name: model-host-storage
    hostPath:
      path: ${HOST_PATH}
      type: Directory${SEED_PVC_VOLUME_YAML}
EOF

if [[ ${DRY_RUN} -eq 1 ]]; then
  # The seed pod does not exist, so there is no IP to sync from yet.
  SEED_IP="<seed-pod-ip>"
  SEED_NODE=${SEED_NODE:-<scheduled>}
else
  if [[ -n "${PV_NAME}" ]]; then
    # Fail fast when no candidate node can attach the PV, instead of
    # sitting Pending for the whole download timeout.
    if ! ${KCMD} wait --for=condition=PodScheduled "pod/${SEED_POD}" --timeout=120s; then
      echo "ERROR: seed pod could not be scheduled on a mounted node the PV ${PV_NAME} can attach to:" >&2
      ${KCMD} get events --field-selector "involvedObject.name=${SEED_POD}" --sort-by=.lastTimestamp | tail -n 5 >&2 || true
      exit 1
    fi
    SEED_NODE=$(${KCMD} get pod "${SEED_POD}" -o 'jsonpath={.spec.nodeName}')
    echo "==> Seed pod scheduled on ${SEED_NODE}"
  fi
  echo "==> Waiting for seed pod to download ${MODEL} (timeout ${TIMEOUT})"
  if ! ${KCMD} wait --for=condition=Ready "pod/${SEED_POD}" --timeout="${TIMEOUT}"; then
    echo "ERROR: seed pod did not become Ready; last logs:" >&2
    ${KCMD} logs "${SEED_POD}" --tail=50 >&2 || true
    exit 1
  fi
  SEED_IP=$(${KCMD} get pod "${SEED_POD}" -o 'jsonpath={.status.podIP}')
  echo "==> Seed pod ready at ${SEED_IP}"
fi

# --- DaemonSet: rsync from seed to every other mounted node ----------------
# Pin by node name: only the nodes the probe found with the mount. A
# metadata.name matchField takes a single value, so emit one (ORed) term
# per node.
NODE_AFFINITY_YAML="      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:"
for node in "${MOUNTED_NODES[@]}"; do
  NODE_AFFINITY_YAML+="
            - matchFields:
              - key: metadata.name
                operator: In
                values: [\"${node}\"]"
done

cat <<EOF | apply_manifest
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${DS_NAME}
  labels:
    app: llm-d-benchmark-harness
    component: model-distribute
    role: sync
spec:
  selector:
    matchLabels:
      app: llm-d-benchmark-harness
      component: model-distribute
      role: sync
  template:
    metadata:
      labels:
        app: llm-d-benchmark-harness
        component: model-distribute
        role: sync
    spec:
${NODE_AFFINITY_YAML}
      serviceAccountName: ${SERVICE_ACCOUNT}
      terminationGracePeriodSeconds: 5
      securityContext:
        seLinuxOptions:
          type: spc_t
      containers:
      - name: sync
        image: ${IMAGE}
        imagePullPolicy: IfNotPresent
        securityContext:
          privileged: true
        command: ["/bin/sh", "-c"]
        args:
        - |
          TARGET_DIR="/var/model-cache/\${MODEL_PATH}"
          MARKER="\${TARGET_DIR}/.download-complete"
          if [ -f "\${MARKER}" ]; then
            echo "Model already present at \${TARGET_DIR} on \${NODE_NAME}, skipping sync."
            exec sleep infinity
          fi
          mkdir -p "\${TARGET_DIR}"
          # The seed caps concurrent clients (max connections), so retry
          # until a slot frees up. --inplace writes straight into the final
          # files (no temp copy, so no 2x space for large shards) and lets a
          # retry continue from what an interrupted run already wrote. The
          # marker is only touched after rsync succeeds, so a half-written
          # model is never reported as ready.
          until rsync -a --inplace --exclude=.download-complete \
                "rsync://\${SEED_IP}:${RSYNC_PORT}/models/\${MODEL}/" "\${TARGET_DIR}/"; do
            echo "rsync from \${SEED_IP} failed or seed busy; retrying in 15s..."
            sleep 15
          done
          echo "Relabelling for non-spc_t readers..."
          ${RELABEL}
          touch "\${MARKER}"
          echo "Sync complete on \${NODE_NAME}."
          exec sleep infinity
        env:
        - name: MODEL
          value: ${MODEL}
        - name: MODEL_PATH
          value: ${MODEL_PATH}
        - name: SEED_IP
          value: "${SEED_IP}"
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        readinessProbe:
          exec:
            command: ["/bin/sh", "-c", "test -f \"/var/model-cache/\${MODEL_PATH}/.download-complete\""]
          periodSeconds: 10
        volumeMounts:
        - name: model-host-storage
          mountPath: /var/model-cache
      volumes:
      - name: model-host-storage
        hostPath:
          path: ${HOST_PATH}
          type: Directory
EOF

if [[ ${DRY_RUN} -eq 1 ]]; then
  echo "==> [dry-run] Nothing applied. Would seed on ${SEED_NODE} and sync ${#MOUNTED_NODES[@]} nodes: ${MOUNTED_NODES[*]}"
  exit 0
fi

echo "==> Waiting for DaemonSet ${DS_NAME} to sync ${#MOUNTED_NODES[@]} nodes (timeout ${TIMEOUT})"
if ! ${KCMD} rollout status "daemonset/${DS_NAME}" --timeout="${TIMEOUT}"; then
  echo "ERROR: DaemonSet did not finish; pods not ready:" >&2
  ${KCMD} get pods -l role=sync,component=model-distribute -o wide | grep -v ' 1/1 ' >&2 || true
  exit 1
fi

# --- Verify: check the model on every node and report per worker node ----
# Rollout status only says the readiness probes passed; look at the files on
# each node directly (marker, size, file count) through its sync pod.
declare -A SYNC_POD_ON NODE_STATUS NODE_SIZE NODE_FILES
# Skip pods being deleted (e.g. left over from a previous run).
while read -r pod node deleting; do
  [[ -n "${pod}" && -z "${deleting}" ]] && SYNC_POD_ON[${node}]=${pod}
done < <(${KCMD} get pods -l role=sync,component=model-distribute \
           -o 'jsonpath={range .items[*]}{.metadata.name} {.spec.nodeName} {.metadata.deletionTimestamp}{"\n"}{end}')

VERIFIED=0
FAILED=0
for node in "${MOUNTED_NODES[@]}"; do
  NODE_SIZE[${node}]="-"
  NODE_FILES[${node}]="-"
  pod=${SYNC_POD_ON[${node}]:-}
  if [[ -z "${pod}" ]]; then
    NODE_STATUS[${node}]="FAILED (no sync pod)"
    FAILED=$((FAILED + 1))
    continue
  fi
  # Prints "<size> <file count>" when the marker is present, nothing otherwise.
  result=$(${KCMD} exec "${pod}" -- sh -c '
    d="/var/model-cache/'"${MODEL_PATH}"'"
    [ -f "$d/.download-complete" ] || exit 1
    echo "$(du -sh "$d" | cut -f1) $(find "$d" -type f ! -name .download-complete ! -path "*/.cache/*" | wc -l)"
  ' 2>/dev/null || true)
  if [[ -n "${result}" && "${result##* }" -gt 0 ]]; then
    NODE_STATUS[${node}]="downloaded"
    NODE_SIZE[${node}]=${result%% *}
    NODE_FILES[${node}]=${result##* }
    VERIFIED=$((VERIFIED + 1))
  else
    NODE_STATUS[${node}]="FAILED (model missing)"
    FAILED=$((FAILED + 1))
  fi
done
for node in "${UNMOUNTED_NODES[@]}"; do
  NODE_STATUS[${node}]="skipped (no mount at ${HOST_PATH})"
done

# Worker nodes (narrowed by --node-selector); fall back to all nodes on
# clusters that do not label workers.
worker_selector="node-role.kubernetes.io/worker"
if [[ ${#NODE_SELECTORS[@]} -gt 0 ]]; then
  worker_selector+=",$(IFS=,; echo "${NODE_SELECTORS[*]}")"
fi
mapfile -t WORKER_NODES < <(kubectl get nodes -l "${worker_selector}" -o name | sed 's|^node/||' | sort)
if [[ ${#WORKER_NODES[@]} -eq 0 ]]; then
  mapfile -t WORKER_NODES < <(kubectl get nodes -o name | sed 's|^node/||' | sort)
fi
SKIPPED=0
for node in "${WORKER_NODES[@]}"; do
  if [[ -z "${NODE_STATUS[${node}]:-}" ]]; then
    NODE_STATUS[${node}]="skipped (not schedulable: tainted, cordoned or NotReady)"
  fi
  [[ "${NODE_STATUS[${node}]}" == skipped* ]] && SKIPPED=$((SKIPPED + 1))
done

echo
echo "==> Download summary: ${MODEL} at ${HOST_PATH}/${MODEL_PATH}"
printf '    %-28s %-8s %-6s %s\n' NODE SIZE FILES STATUS
for node in $(printf '%s\n' "${!NODE_STATUS[@]}" | sort); do
  printf '    %-28s %-8s %-6s %s\n' "${node}" "${NODE_SIZE[${node}]:--}" "${NODE_FILES[${node}]:--}" "${NODE_STATUS[${node}]}"
done
echo

if [[ ${KEEP} -eq 0 ]]; then
  cleanup
else
  echo "==> Keeping seed pod and DaemonSet (--keep). Remove with: $0 -n ${NAMESPACE} --delete"
fi
if [[ -n "${PV_NAME}" ]]; then
  echo "==> Keeping PVC ${PVC_NAME} (model cached on PV ${PV_NAME}). Remove with: kubectl -n ${NAMESPACE} delete pvc ${PVC_NAME}"
fi

if [[ ${FAILED} -gt 0 ]]; then
  echo "==> ERROR: ${MODEL} is missing on ${FAILED} of ${#MOUNTED_NODES[@]} nodes with ${HOST_PATH} mounted (see summary above)" >&2
  exit 1
fi
if [[ ${SKIPPED} -eq 0 ]]; then
  echo "==> SUCCESS: ${MODEL} is downloaded on all ${VERIFIED} worker nodes"
else
  echo "==> SUCCESS: ${MODEL} is downloaded on all ${VERIFIED} worker nodes with ${HOST_PATH} mounted" \
       "(${SKIPPED} of ${#WORKER_NODES[@]} worker nodes skipped, see summary above)"
fi
