#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# release.sh — publica una nueva versión de QSO Logger en GitHub Releases
#
# Requisitos: git, gh (GitHub CLI autenticado), jq
#
# Uso:
#   1. Editar latest.json con la nueva versión y las notas de release
#   2. Copiar los binarios a staging/:
#        staging/qso_logger_linux
#        staging/qso_logger_windows.exe   (o .msi, o .exe instalador)
#   3. Ejecutar:  ./scripts/release.sh
# ---------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LATEST_JSON="$REPO_ROOT/latest.json"
STAGING_DIR="$REPO_ROOT/staging"
RELEASES_MD="$REPO_ROOT/RELEASES.md"

# ---- Colores ---------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ---- Dependencias ----------------------------------------------------------
for cmd in git gh jq; do
  command -v "$cmd" &>/dev/null || error "Falta el comando: $cmd"
done

# ---- Leer latest.json ------------------------------------------------------
VERSION=$(jq -r '.version' "$LATEST_JSON")
NOTES=$(jq -r '.notes'   "$LATEST_JSON")
TAG="v${VERSION}"

[[ "$VERSION" == "0.0.0" ]] && error "Actualizá la versión en latest.json antes de hacer el release."
[[ -z "$VERSION" ]]          && error "No se pudo leer 'version' de latest.json."

info "Versión detectada: $TAG"

# ---- Verificar que el tag no exista ya ------------------------------------
if git -C "$REPO_ROOT" rev-parse "$TAG" &>/dev/null; then
  error "El tag $TAG ya existe. Actualizá la versión en latest.json."
fi

# ---- Detectar binarios en staging/ -----------------------------------------
LINUX_BIN=$(find "$STAGING_DIR" -maxdepth 1 -type f \
  ! -name '.gitkeep' \
  \( -name '*linux*' -o -name '*Linux*' \) | head -1)

WIN_BIN=$(find "$STAGING_DIR" -maxdepth 1 -type f \
  ! -name '.gitkeep' \
  \( -name '*.exe' -o -name '*.msi' -o -name '*windows*' -o -name '*Windows*' \) | head -1)

[[ -z "$LINUX_BIN" && -z "$WIN_BIN" ]] && \
  error "No se encontraron binarios en staging/. Copiá al menos uno antes de continuar."

[[ -n "$LINUX_BIN" ]]  && info "Binario Linux  : $(basename "$LINUX_BIN")"
[[ -n "$WIN_BIN"   ]]  && info "Binario Windows: $(basename "$WIN_BIN")"

# ---- Confirmar -------------------------------------------------------------
echo ""
warn "Se va a crear el release $TAG. ¿Continuar? [s/N]"
read -r CONFIRM
[[ "$CONFIRM" =~ ^[sS]$ ]] || { info "Cancelado."; exit 0; }

# ---- Actualizar latest.json con la URL exacta del tag ----------------------
REPO_URL="https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo 'pbracc/qso_logger_app')"
LATEST_URL="${REPO_URL}/releases/latest"

jq --arg url "$LATEST_URL" '.url = $url' "$LATEST_JSON" > "${LATEST_JSON}.tmp" \
  && mv "${LATEST_JSON}.tmp" "$LATEST_JSON"

# ---- Actualizar RELEASES.md ------------------------------------------------
LINUX_FILENAME=$(basename "${LINUX_BIN:-}")
WIN_FILENAME=$(basename "${WIN_BIN:-}")

LINUX_LINK=""
WIN_LINK=""
[[ -n "$LINUX_BIN" ]] && LINUX_LINK="[⬇ Linux](${REPO_URL}/releases/download/${TAG}/${LINUX_FILENAME})"
[[ -n "$WIN_BIN"   ]] && WIN_LINK="[⬇ Windows](${REPO_URL}/releases/download/${TAG}/${WIN_FILENAME})"

NOTES_ESCAPED="${NOTES//$'\n'/ }"

# Filas para ambas tablas (español e inglés, mismos links)
ROW_ES="| ${TAG} | ${LINUX_LINK} | ${WIN_LINK} | ${NOTES_ESCAPED} |"
ROW_EN="| ${TAG} | ${LINUX_LINK} | ${WIN_LINK} | ${NOTES_ESCAPED} |"

# Insertar después de cada línea de separadores de tabla (|---|)
# La primera ocurrencia corresponde a la tabla en español, la segunda a la de inglés
awk -v row_es="$ROW_ES" -v row_en="$ROW_EN" '
  /^\|[-| ]+\|/ {
    count++
    print
    if (count == 1) { print row_es }
    if (count == 2) { print row_en }
    next
  }
  { print }
' "$RELEASES_MD" > "${RELEASES_MD}.tmp" && mv "${RELEASES_MD}.tmp" "$RELEASES_MD"

info "RELEASES.md actualizado."

# ---- Commit latest.json + RELEASES.md -------------------------------------
git -C "$REPO_ROOT" add latest.json RELEASES.md
git -C "$REPO_ROOT" commit -m "release: ${TAG}"
info "Commit creado."

# ---- Tag y push ------------------------------------------------------------
git -C "$REPO_ROOT" tag "$TAG"
git -C "$REPO_ROOT" push origin main
git -C "$REPO_ROOT" push origin "$TAG"
info "Tag $TAG pusheado."

# ---- Crear GitHub Release con los binarios ---------------------------------
UPLOAD_FILES=()
[[ -n "$LINUX_BIN" ]] && UPLOAD_FILES+=("$LINUX_BIN")
[[ -n "$WIN_BIN"   ]] && UPLOAD_FILES+=("$WIN_BIN")

RELEASE_NOTES="${NOTES:-Sin notas de release.}"

gh release create "$TAG" \
  "${UPLOAD_FILES[@]}" \
  --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)" \
  --title "QSO Logger ${TAG}" \
  --notes "$RELEASE_NOTES" \
  --latest

info "Release $TAG publicado exitosamente."
echo ""
info "URL: ${REPO_URL}/releases/tag/${TAG}"

# ---- Limpiar staging/ ------------------------------------------------------
warn "¿Limpiar los binarios de staging/? [s/N]"
read -r CLEAN
if [[ "$CLEAN" =~ ^[sS]$ ]]; then
  find "$STAGING_DIR" -maxdepth 1 -type f ! -name '.gitkeep' -delete
  info "staging/ limpiado."
fi
