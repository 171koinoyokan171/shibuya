#!/usr/bin/env bash
# Cloud: gcloud, kubectl + gke-auth-plugin, helm, pulumi, k9s. Plus 3 GKE contexts.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

USER_NAME="$(target_user)"
USER_HOME="$(target_home)"

# ------------------------------------------------------------ gcloud ------
section "gcloud + kubectl"
if have gcloud; then
  skip "gcloud already installed: $(gcloud version 2>/dev/null | head -1)"
else
  add_apt_repo cloud-google \
    "https://packages.cloud.google.com/apt/doc/apt-key.gpg" \
    "https://packages.cloud.google.com/apt cloud-sdk main"
fi
apt_install google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin kubectl

# -------------------------------------------------------------- helm ------
# The official helm apt repository (baltocdn.com) serves an incomplete certificate
# chain that curl on this machine will not verify. The binary comes from
# get.helm.sh instead — the same official source, minus the broken CDN.
section "helm"
if have helm; then
  skip "helm already installed: $(helm version --short 2>/dev/null)"
else
  HELM_VER="$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name')"
  if [[ -n "$HELM_VER" && "$HELM_VER" != "null" ]]; then
    tmp="$(mktemp -d)"
    if curl -fsSL "https://get.helm.sh/helm-${HELM_VER}-linux-arm64.tar.gz" \
         | tar xz -C "$tmp" --strip-components=1 linux-arm64/helm; then
      install -m 0755 "${tmp}/helm" /usr/local/bin/helm
      ok "helm installed: $(helm version --short 2>/dev/null)"
    else
      warn "could not download helm ${HELM_VER}"
    fi
    rm -rf "$tmp"
  else
    warn "could not determine the latest helm version — skipping"
  fi
fi

# --------------------------------------------------------------- k9s ------
# On a phone screen k9s is plainly better than kubectl walls of output:
# arrow-key navigation instead of typing long commands.
section "k9s"
if have k9s; then
  skip "k9s already installed: $(k9s version -s 2>/dev/null | head -1)"
else
  K9S_URL="$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest \
    | jq -r '.assets[] | select(.name == "k9s_linux_arm64.deb") | .browser_download_url')"
  if [[ -n "$K9S_URL" && "$K9S_URL" != "null" ]]; then
    tmp="$(mktemp --suffix=.deb)"
    curl -fsSL "$K9S_URL" -o "$tmp"
    DEBIAN_FRONTEND=noninteractive dpkg -i "$tmp" >/dev/null 2>&1 || apt-get -f install -y -qq
    rm -f "$tmp"
    ok "k9s installed: $(k9s version -s 2>/dev/null | head -1)"
  else
    warn "no arm64 build of k9s in the latest release — skipping"
  fi
fi

# ------------------------------------------------------------ pulumi ------
section "pulumi"
if as_user test -x "${USER_HOME}/.pulumi/bin/pulumi"; then
  skip "pulumi already installed"
else
  as_user bash -c 'curl -fsSL https://get.pulumi.com | sh' >/dev/null 2>&1 \
    && ok "pulumi installed" \
    || warn "pulumi install failed"
fi
for rc in .bashrc .zshrc; do
  ensure_line "${USER_HOME}/${rc}" 'export PATH="$HOME/.pulumi/bin:$PATH"' '.pulumi/bin' || true
  chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/${rc}"
done

# --------------------------------------------------------- GKE contexts ---
# get-credentials only works after an interactive gcloud auth login, so this
# either configures them or says plainly what is missing.
section "GKE contexts"
GCLOUD_ACCT="$(as_user gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1 || true)"

if [[ -z "$GCLOUD_ACCT" ]]; then
  warn "gcloud is not authenticated — skipping context setup"
  warn "first:  gcloud auth login --no-launch-browser"
  warn "then repeat:  sudo ~/shibuya/bootstrap.sh --only 50"
else
  ok "gcloud authenticated as ${GCLOUD_ACCT}"
  # cluster|zone|project — exactly the three configured on the Mac.
  CLUSTERS=(
    "lvn-prod-gke-cluster-1b75d55|us-central1-a|resolutty-387615"
    "lvn-dev-gke-cluster-f197826|europe-west3-a|liven-development"
    "leaply-prod-gke-1|us-central1-a|central-surf-420115"
  )
  for entry in "${CLUSTERS[@]}"; do
    IFS='|' read -r cl zone proj <<< "$entry"
    ctx="gke_${proj}_${zone}_${cl}"
    if contains "$(as_user kubectl config get-contexts -o name 2>/dev/null || true)" "$ctx"; then
      skip "context already present: ${cl}"
    else
      if as_user gcloud container clusters get-credentials "$cl" \
           --zone "$zone" --project "$proj" >/dev/null 2>&1; then
        ok "context added: ${cl}"
      else
        warn "could not get credentials for ${cl} (project ${proj}) — check permissions"
      fi
    fi
  done
fi

ok "50-cloud done"
