#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# release.sh — publica una nueva versión de Open73 en GitHub Releases
#
# Requisitos: git, curl, jq
#
# Uso:
#   1. Editar latest.json con la nueva versión y las notas de release
#   2. Copiar los binarios a staging/:
#        staging/open73_X.Y.Z_amd64.AppImage
#        staging/open73_X.Y.Z_x64_en-US.msi
#   3. Ejecutar:  ./scripts/release.sh
# ---------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LATEST_JSON="$REPO_ROOT/latest.json"
STAGING_DIR="$REPO_ROOT/staging"
RELEASES_MD="$REPO_ROOT/RELEASES.md"
ENV_FILE="$REPO_ROOT/.env"

# ---- Colores ---------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ---- Dependencias ----------------------------------------------------------
for cmd in git curl jq; do
  command -v "$cmd" &>/dev/null || error "Falta el comando: $cmd"
done

# ---- Cargar token ----------------------------------------------------------
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi
[[ -z "${GITHUB_TOKEN:-}" ]] && error "No se encontró GITHUB_TOKEN. Agregalo en .env: GITHUB_TOKEN=ghp_..."

# ---- Leer latest.json ------------------------------------------------------
VERSION=$(jq -r '.version' "$LATEST_JSON")
NOTES=$(jq -r '.notes'     "$LATEST_JSON")
TAG="v${VERSION}"

[[ "$VERSION" == "0.0.0" ]] && error "Actualizá la versión en latest.json antes de hacer el release."
[[ -z "$VERSION" ]]          && error "No se pudo leer 'version' de latest.json."

info "Versión detectada: $TAG"

# ---- Obtener owner/repo desde el remote ------------------------------------
REMOTE_URL=$(git -C "$REPO_ROOT" remote get-url origin)
# Soporta tanto SSH (git@github.com:owner/repo.git) como HTTPS
REPO_PATH=$(echo "$REMOTE_URL" | sed -E 's#(git@github\.com:|https://github\.com/)##;s#\.git$##')
REPO_URL="https://github.com/${REPO_PATH}"
OWNER=$(echo "$REPO_PATH" | cut -d/ -f1)
REPO=$(echo "$REPO_PATH"  | cut -d/ -f2)

info "Repositorio: ${OWNER}/${REPO}"

# ---- Verificar que el tag no exista ya ------------------------------------
if git -C "$REPO_ROOT" rev-parse "$TAG" &>/dev/null; then
  error "El tag $TAG ya existe. Actualizá la versión en latest.json."
fi

# ---- Detectar binarios en staging/ -----------------------------------------
LINUX_BIN=$(find "$STAGING_DIR" -maxdepth 1 -type f -name "*.AppImage" | head -1)
WIN_BIN=$(find   "$STAGING_DIR" -maxdepth 1 -type f -name "*.msi"      | head -1)

[[ -z "$LINUX_BIN" && -z "$WIN_BIN" ]] && \
  error "No se encontraron binarios en staging/. Copiá al menos uno antes de continuar."

[[ -n "$LINUX_BIN" ]] && info "Binario Linux  : $(basename "$LINUX_BIN")"
[[ -n "$WIN_BIN"   ]] && info "Binario Windows: $(basename "$WIN_BIN")"

# ---- Confirmar -------------------------------------------------------------
echo ""
warn "Se va a crear el release $TAG. ¿Continuar? [s/N]"
read -r CONFIRM
[[ "$CONFIRM" =~ ^[sS]$ ]] || { info "Cancelado."; exit 0; }

# ---- Actualizar latest.json ------------------------------------------------
LATEST_URL="${REPO_URL}/releases/latest"
jq --arg url "$LATEST_URL" '.url = $url' "$LATEST_JSON" > "${LATEST_JSON}.tmp" \
  && mv "${LATEST_JSON}.tmp" "$LATEST_JSON"

# ---- Actualizar RELEASES.md ------------------------------------------------
LINUX_FILENAME=$(basename "${LINUX_BIN:-}")
WIN_FILENAME=$(basename "${WIN_BIN:-}")

LINUX_LINK=""
WIN_LINK=""
[[ -n "$LINUX_BIN" ]] && LINUX_LINK="[⬇ AppImage](${REPO_URL}/releases/download/${TAG}/${LINUX_FILENAME})"
[[ -n "$WIN_BIN"   ]] && WIN_LINK="[⬇ MSI](${REPO_URL}/releases/download/${TAG}/${WIN_FILENAME})"

NOTES_ESCAPED="${NOTES//$'\n'/ }"
ROW="| ${TAG} | ${LINUX_LINK} | ${WIN_LINK} | ${NOTES_ESCAPED} |"

awk -v row="$ROW" '
  /^\|[-| ]+\|/ {
    count++
    print
    if (count == 1 || count == 2) { print row }
    next
  }
  { print }
' "$RELEASES_MD" > "${RELEASES_MD}.tmp" && mv "${RELEASES_MD}.tmp" "$RELEASES_MD"

info "RELEASES.md actualizado."

# ---- Actualizar links de descarga en README.md -----------------------------
README="$REPO_ROOT/README.md"
if [[ -n "$LINUX_BIN" ]]; then
  LINUX_URL="${REPO_URL}/releases/download/${TAG}/${LINUX_FILENAME}"
  sed -i "s|\\[⬇ Descargar\\]([^)]*) <!-- LINUX_ASSET -->|[⬇ Descargar](${LINUX_URL}) <!-- LINUX_ASSET -->|g" "$README"
  sed -i "s|\\[⬇ Download\\]([^)]*) <!-- LINUX_ASSET -->|[⬇ Download](${LINUX_URL}) <!-- LINUX_ASSET -->|g" "$README"
fi
if [[ -n "$WIN_BIN" ]]; then
  WIN_URL="${REPO_URL}/releases/download/${TAG}/${WIN_FILENAME}"
  sed -i "s|\\[⬇ Descargar\\]([^)]*) <!-- WIN_ASSET -->|[⬇ Descargar](${WIN_URL}) <!-- WIN_ASSET -->|g" "$README"
  sed -i "s|\\[⬇ Download\\]([^)]*) <!-- WIN_ASSET -->|[⬇ Download](${WIN_URL}) <!-- WIN_ASSET -->|g" "$README"
fi
info "README.md actualizado."

# ---- Commit + tag + push ---------------------------------------------------
git -C "$REPO_ROOT" add latest.json RELEASES.md README.md
git -C "$REPO_ROOT" commit -m "release: ${TAG}"
git -C "$REPO_ROOT" tag "$TAG"
git -C "$REPO_ROOT" push origin main
git -C "$REPO_ROOT" push origin "$TAG"
info "Commit y tag $TAG pusheados."

# ---- Crear GitHub Release via API ------------------------------------------
info "Creando GitHub Release..."
RELEASE_BODY="${NOTES:-Sin notas de release.}"

RELEASE_RESPONSE=$(curl -sf \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"tag_name\": \"${TAG}\",
    \"name\": \"Open73 ${TAG}\",
    \"body\": $(echo "$RELEASE_BODY" | jq -Rs .),
    \"draft\": false,
    \"prerelease\": false,
    \"make_latest\": \"true\"
  }" \
  "https://api.github.com/repos/${OWNER}/${REPO}/releases")

RELEASE_ID=$(echo "$RELEASE_RESPONSE" | jq -r '.id')
[[ -z "$RELEASE_ID" || "$RELEASE_ID" == "null" ]] && \
  error "No se pudo crear el release. Respuesta: $RELEASE_RESPONSE"

info "Release creado (id: $RELEASE_ID). Subiendo binarios..."

# ---- Subir binarios como assets --------------------------------------------
upload_asset() {
  local filepath="$1"
  local filename
  filename=$(basename "$filepath")
  local mime="application/octet-stream"

  info "Subiendo: $filename"
  RESULT=$(curl -sf \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Content-Type: ${mime}" \
    --data-binary @"$filepath" \
    "https://uploads.github.com/repos/${OWNER}/${REPO}/releases/${RELEASE_ID}/assets?name=${filename}")

  local state
  state=$(echo "$RESULT" | jq -r '.state // "error"')
  [[ "$state" == "uploaded" ]] || error "Falló la subida de $filename. Respuesta: $RESULT"
  info "$filename subido correctamente."
}

[[ -n "$LINUX_BIN" ]] && upload_asset "$LINUX_BIN"
[[ -n "$WIN_BIN"   ]] && upload_asset "$WIN_BIN"

echo ""
info "Release $TAG publicado exitosamente."
info "URL: ${REPO_URL}/releases/tag/${TAG}"

# ---- Limpiar staging/ ------------------------------------------------------
warn "¿Limpiar los binarios de staging/? [s/N]"
read -r CLEAN
if [[ "$CLEAN" =~ ^[sS]$ ]]; then
  find "$STAGING_DIR" -maxdepth 1 -type f ! -name '.gitkeep' -delete
  info "staging/ limpiado."
fi
