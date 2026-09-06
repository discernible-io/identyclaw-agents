# IdentyClaw Passport host helpers (enroll → purchase → ensure_session).
# Pattern: init creates -app; setup populates it; last step is automatic NEAR enroll.

# Stop agent containers and restore host ownership so we can write near-credentials.
# Mirrors hermes setup stopping the gateway before idcp-setup.
_idcp_prepare_host_write() {
  local ids="${1:-}"
  local id container dir
  load_env
  [[ -n "$ids" ]] || ids="$(configured_agent_ids)"
  for id in $ids; do
    container="$(agent_container "$id")"
    if podman container exists "$container" 2>/dev/null; then
      if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
        echo "==> Stopping ${container} for Passport setup"
        podman stop "$container" >/dev/null 2>&1 || true
      fi
      podman rm -f "$container" >/dev/null 2>&1 || true
    fi
    dir="$(agent_home "$id")"
    if [[ -d "$dir" ]]; then
      restore_pod_path_for_host "$dir" 2>/dev/null || true
    fi
  done
}

ensure_idcp_layout_for_agent() {
  local id="${1:?}"
  local home
  home="$(agent_home "$id")"
  mkdir -p \
    "$home/secrets/near-credentials" \
    "$home/secrets/identyclaw" \
    2>/dev/null || true
  chmod 700 "$home/secrets" "$home/secrets/near-credentials" "$home/secrets/identyclaw" 2>/dev/null || true
}

_idcp_install_core() {
  if ! command -v npm >/dev/null 2>&1; then
    echo "npm required on host for IdentyClaw (idcp-install)" >&2
    return 1
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "node required on host for IdentyClaw" >&2
    return 1
  fi
  echo "Installing idcp deps in ${IDENTYCLAW_ROOT}/idcp ..."
  (cd "${IDENTYCLAW_ROOT}/idcp" && npm install --omit=dev)
}

# Host-side idcp for one agent (IDENTYCLAW_HOME = agents/<id>/).
_idcp_host() {
  local id="${1:?}"
  shift
  local home
  home="$(agent_home "$id")"
  ensure_idcp_layout_for_agent "$id"
  IDENTYCLAW_HOME="$home" \
    IDENTYCLAW_NEAR_CREDENTIALS_DIR="$home/secrets/near-credentials" \
    node "${IDENTYCLAW_ROOT}/idcp/bin/idcp.mjs" "$@"
}

_idcp_account_id_for_agent() {
  local id="${1:?}"
  local dir home
  home="$(agent_home "$id")"
  dir="${home}/secrets/near-credentials"
  if [[ -f "$dir/.active" ]]; then
    tr -d '[:space:]' <"$dir/.active"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$dir" <<'PY'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1])
if not d.is_dir():
    sys.exit(0)
files = sorted(d.glob("*.json"))
if not files:
    sys.exit(0)
try:
    raw = json.loads(files[0].read_text())
except Exception:
    sys.exit(0)
aid = raw.get("account_id") or raw.get("implicit_account_id") or ""
if aid:
    print(aid)
PY
  fi
}

_idcp_mark_active() {
  local id="${1:?}"
  local account_id="${2:?}"
  local dir
  dir="$(agent_home "$id")/secrets/near-credentials"
  mkdir -p "$dir"
  printf '%s\n' "$account_id" >"$dir/.active"
  chmod 600 "$dir/.active" 2>/dev/null || true
  chmod 600 "$dir/${account_id}.json" 2>/dev/null || true
}

# ContactURI for purchase.identyclaw.com: scheme:authority:identifier
# Preference: explicit CONTACT_URI → telegram:telegram.com:@user → email:domain:addr
identyclaw_format_contact_uri() {
  local explicit="${1:-}" tg="${2:-}" email="${3:-}" domain
  explicit="${explicit//[[:space:]]/}"
  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi
  tg="${tg#@}"
  tg="${tg//[[:space:]]/}"
  if [[ -n "$tg" ]]; then
    printf 'telegram:telegram.com:@%s' "$tg"
    return 0
  fi
  email="${email//[[:space:]]/}"
  if [[ -n "$email" && "$email" == *@* ]]; then
    domain="${email#*@}"
    printf 'email:%s:%s' "$domain" "$email"
    return 0
  fi
  return 0
}

print_passport_field() {
  local name="$1" value="${2:-}" collect_hint="${3:-enter on purchase.identyclaw.com}"
  if [[ -n "$value" ]]; then
    printf '  %-22s [selected]  %s\n' "$name" "$value"
  else
    printf '  %-22s [collect]   %s\n' "$name" "$collect_hint"
  fi
}

print_passport_webhook_field() {
  local name="$1" value="${2:-}"
  if [[ -z "$value" ]]; then
    print_passport_field "$name" "" "public HTTPS A2A / webhook URL"
    return 0
  fi
  if [[ "$value" == *127.0.0.1* || "$value" == *localhost* ]]; then
    printf '  %-22s [collect]   %s  (loopback — paste a public HTTPS URL on the portal)\n' "$name" "$value"
    return 0
  fi
  print_passport_field "$name" "$value" ""
}

upsert_env_local_kv() {
  local file="${1:?}" key="${2:?}" value="${3:-}"
  [[ -n "$value" ]] || return 0
  python3 - "$file" "$key" "$value" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
key, value = sys.argv[2], sys.argv[3]
text = path.read_text() if path.is_file() else ""
lines = text.splitlines(True)
prefix = f"{key}="
out, found = [], False
for line in lines:
    stripped = line.lstrip()
    if stripped.startswith(prefix) and not stripped.startswith("#"):
        out.append(f"{key}={value}\n")
        found = True
    else:
        out.append(line)
if not found:
    if out and not str(out[-1]).endswith("\n"):
        out.append("\n")
    out.append(f"{key}={value}\n")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("".join(out))
PY
}

identyclaw_prompt_with_default() {
  local prompt="$1" default="${2:-}" var=""
  if [[ ! -t 0 ]] || [[ "${SKIP_SETUP_PROMPTS:-0}" == "1" ]]; then
    printf '%s' "$default"
    return 0
  fi
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " var || true
  else
    read -r -p "${prompt}: " var || true
  fi
  printf '%s' "${var:-$default}"
}

# Secret prompt (no echo). Empty / non-TTY / SKIP_SETUP_PROMPTS → stdout empty.
identyclaw_prompt_secret() {
  local prompt="$1" var=""
  if [[ ! -t 0 ]] || [[ "${SKIP_SETUP_PROMPTS:-0}" == "1" ]]; then
    return 0
  fi
  read -r -s -p "${prompt}: " var || true
  echo >&2
  printf '%s' "$var"
}

_agent_secret_present() {
  local id="${1:?}" name="${2:?}"
  [[ -s "$(agent_home "$id")/secrets/${name}" ]]
}

# LLM key, mailbox password, Telegram — only when missing. Enter skips.
# Call before Passport fields so ContactURI can use a newly collected Telegram username.
# Reuses SETUP_SHARED_LLM_KEY / SETUP_SHARED_MAIL_PASSWORD across agents in one setup run.
setup_collect_operator_secrets_one() {
  local id="${1:?}" prefix dir key pw token tg envf provider
  load_env
  prefix="$(agent_env_prefix "$id")" || return 1
  dir="$(agent_home "$id")"
  envf="$(identyclaw_env_file)"
  provider="$(openclaw_llm_provider)"

  echo ""
  echo "==> Operator secrets for ${id} (Enter skips; values already on disk are kept)"

  if [[ "$provider" == "opencode" ]]; then
    if ! _agent_secret_present "$id" OPENCODE_API_KEY; then
      key="${SETUP_SHARED_LLM_KEY:-${OPENCODE_API_KEY:-}}"
      if [[ -n "$key" && -n "${SETUP_SHARED_LLM_KEY:-}" ]]; then
        echo "    (reusing OpenCode key from earlier agent)"
      elif [[ -z "$key" ]]; then
        key="$(identyclaw_prompt_secret "  OpenCode API key (sk-..., Enter skips)")"
      fi
      if [[ -n "$key" ]]; then
        if write_opencode_api_key "$id" "$key"; then
          SETUP_SHARED_LLM_KEY="$key"
          export SETUP_SHARED_LLM_KEY
          echo "    stored secrets/OPENCODE_API_KEY"
        else
          echo "    (invalid or unwritable OpenCode key — later: ./identyclaw.sh set-opencode-key ${id})"
        fi
      else
        echo "    (no LLM key — chat needs: ./identyclaw.sh set-opencode-key ${id})"
      fi
    fi
  else
    if ! _agent_secret_present "$id" OPENROUTER_API_KEY; then
      key="${SETUP_SHARED_LLM_KEY:-${OPENROUTER_API_KEY:-}}"
      if [[ -n "$key" && -n "${SETUP_SHARED_LLM_KEY:-}" ]]; then
        echo "    (reusing OpenRouter key from earlier agent)"
      elif [[ -z "$key" ]]; then
        key="$(identyclaw_prompt_secret "  OpenRouter API key (sk-or-..., Enter skips)")"
      fi
      if [[ -n "$key" ]]; then
        if write_openrouter_api_key "$id" "$key"; then
          SETUP_SHARED_LLM_KEY="$key"
          export SETUP_SHARED_LLM_KEY
          echo "    stored secrets/OPENROUTER_API_KEY"
        else
          echo "    (invalid or unwritable OpenRouter key — later: ./identyclaw.sh set-api-key ${id})"
        fi
      else
        echo "    (no LLM key — chat needs: ./identyclaw.sh set-api-key ${id})"
      fi
    fi
  fi

  if ! _agent_secret_present "$id" imap.pass; then
    pw="${SETUP_SHARED_MAIL_PASSWORD:-$(agent_env_value "$id" PASSWORD "")}"
    if [[ -n "$pw" && -n "${SETUP_SHARED_MAIL_PASSWORD:-}" ]]; then
      echo "    (reusing mailbox password from earlier agent)"
    elif [[ -z "$pw" ]]; then
      pw="$(identyclaw_prompt_secret "  Migadu mailbox password (Enter skips)")"
    fi
    if [[ -n "$pw" ]]; then
      if write_secret_helpers "$id" "$pw"; then
        SETUP_SHARED_MAIL_PASSWORD="$pw"
        export SETUP_SHARED_MAIL_PASSWORD
      fi
    else
      echo "    (no mailbox password — later: ./identyclaw.sh set-password ${id})"
    fi
  fi

  if ! _agent_secret_present "$id" TELEGRAM_BOT_TOKEN; then
    token="$(agent_env_value "$id" TELEGRAM_BOT_TOKEN "")"
    [[ -z "$token" ]] && token="$(identyclaw_prompt_secret "  Telegram bot token (Enter skips)")"
    if [[ -n "$token" ]]; then
      write_telegram_token "$dir" "$token" "$(agent_container "$id")" \
        && echo "    stored secrets/TELEGRAM_BOT_TOKEN" \
        || echo "    (could not store Telegram token — later: ./identyclaw.sh set-telegram-token ${id})"
    else
      echo "    (no Telegram token — console chat still works; later: ./identyclaw.sh set-telegram-token ${id})"
    fi
  fi

  tg="$(agent_env_value "$id" TELEGRAM_BOT_USERNAME "")"
  tg="${tg#@}"
  if [[ -z "$tg" ]] && { _agent_secret_present "$id" TELEGRAM_BOT_TOKEN || [[ -n "${token:-}" ]]; }; then
    tg="$(identyclaw_prompt_with_default "  Telegram bot username (no @)" "")"
    tg="${tg#@}"
  fi
  if [[ -n "$tg" ]]; then
    upsert_env_local_kv "$envf" "${prefix}_TELEGRAM_BOT_USERNAME" "$tg"
    export "${prefix}_TELEGRAM_BOT_USERNAME=$tg"
  fi
}

agent_passport_webhook_url() {
  local id="${1:?}" url=""
  load_env
  url="$(agent_env_value "$id" WEBHOOK_URL "")"
  [[ -n "$url" ]] && { printf '%s' "$url"; return 0; }
  url="$(agent_ingress_base_url "$id" 2>/dev/null || true)"
  [[ -n "$url" ]] && { printf '%s' "$url"; return 0; }
  agent_webhook_url "$id" 2>/dev/null || true
}

agent_passport_avatar_url() {
  local id="${1:?}"
  load_env
  agent_env_value "$id" AVATAR_URL "${IDENTYCLAW_AVATAR_URL:-}"
}

agent_passport_contact_uri() {
  local id="${1:?}" explicit tg email
  load_env
  explicit="$(agent_env_value "$id" CONTACT_URI "")"
  tg="$(agent_env_value "$id" TELEGRAM_BOT_USERNAME "")"
  email="$(agent_env_value "$id" EMAIL "")"
  identyclaw_format_contact_uri "$explicit" "$tg" "$email"
}

agent_passport_telegram_hint() {
  local id="${1:?}" tg
  load_env
  tg="$(agent_env_value "$id" TELEGRAM_BOT_USERNAME "")"
  tg="${tg#@}"
  if [[ -n "$tg" ]]; then
    printf '@%s' "$tg"
    return 0
  fi
  if [[ -f "$(agent_home "$id")/secrets/TELEGRAM_BOT_TOKEN" ]]; then
    printf 'Telegram token is stored — message the bot after start'
    return 0
  fi
}

# Persist operator-chosen Passport fields collected during setup.
setup_collect_passport_fields_one() {
  local id="${1:?}" prefix webhook avatar contact envf
  load_env
  prefix="$(agent_env_prefix "$id")" || return 1
  envf="$(identyclaw_env_file)"
  webhook="$(agent_passport_webhook_url "$id")"
  avatar="$(agent_passport_avatar_url "$id")"
  contact="$(agent_passport_contact_uri "$id")"

  echo ""
  echo "==> Passport fields for ${id} (Enter keeps the value; empty means collect at purchase.identyclaw.com)"
  if [[ -t 0 && "${SKIP_SETUP_PROMPTS:-0}" != "1" ]]; then
    [[ -z "$webhook" || "$webhook" == *127.0.0.1* || "$webhook" == *localhost* ]] \
      && webhook="$(identyclaw_prompt_with_default "  A2A / webhook URL" "$webhook")"
    [[ -z "$avatar" ]] && avatar="$(identyclaw_prompt_with_default "  Avatar image URL" "$avatar")"
    [[ -z "$contact" ]] && contact="$(identyclaw_prompt_with_default "  ContactURI" "$contact")"
  fi

  if [[ -n "$webhook" && "$webhook" != *127.0.0.1* && "$webhook" != *localhost* ]]; then
    upsert_env_local_kv "$envf" "${prefix}_A2A_PUBLIC_BASE_URL" "$webhook"
    export "${prefix}_A2A_PUBLIC_BASE_URL=$webhook"
  fi
  if [[ -n "$avatar" ]]; then
    upsert_env_local_kv "$envf" "${prefix}_AVATAR_URL" "$avatar"
    export "${prefix}_AVATAR_URL=$avatar"
  fi
  if [[ -n "$contact" ]]; then
    upsert_env_local_kv "$envf" "${prefix}_CONTACT_URI" "$contact"
    export "${prefix}_CONTACT_URI=$contact"
  fi
}

print_passport_purchase_guide() {
  local account_id="${1:?}" webhook_url="${2:-}" avatar_url="${3:-}" contact_uri="${4:-}" label="${5:-}"
  echo ""
  echo "──────────────────────────────────────────────────────────────"
  if [[ -n "$label" ]]; then
    echo "Craft your Passport for ${label} at https://purchase.identyclaw.com"
  else
    echo "Craft your Passport at https://purchase.identyclaw.com"
  fi
  echo "──────────────────────────────────────────────────────────────"
  echo "1. Fund a SEPARATE checkout wallet with NEAR (e.g. HOT Wallet)."
  echo "   Do not paste the agent key file into chat or the portal."
  echo "2. Open: https://purchase.identyclaw.com"
  echo "3. Paste this 64-char hex as the NEAR recipient account:"
  echo ""
  echo "   ${account_id}"
  echo ""
  echo "4. Fill the Passport form. Values already collected by setup are [selected]:"
  print_passport_webhook_field "A2A / webhook URL" "$webhook_url"
  print_passport_field "Avatar image URL" "$avatar_url" "https://identyclaw.com/avatar.png (portal default) or any https image"
  print_passport_field "ContactURI" "$contact_uri" "scheme:authority:identifier  e.g. telegram:telegram.com:@YourBot  or  email:domain:you@domain"
  echo ""
  echo "   Also collect on the portal: name, creature/role, traits, longevity."
  echo "5. Connect the paying wallet, mint, wait for confirmation."
  echo "   Docs: https://www.discernible.io/  ·  https://api.identyclaw.com/.well-known/enrollment"
  echo "──────────────────────────────────────────────────────────────"
}

print_operator_chat_next_steps() {
  local id="${1:?}" tg
  tg="$(agent_passport_telegram_hint "$id" || true)"
  echo ""
  echo "After mint + start, chat as the operator:"
  echo "  Console:   ./identyclaw.sh chat ${id}"
  if [[ -n "$tg" ]]; then
    echo "  Telegram:  ${tg}"
  else
    echo "  Telegram:  ./identyclaw.sh set-telegram-token ${id}   # then message the bot"
  fi
}

# Auto-create (or reuse) a NEAR implicit account — no operator input.
# Progress goes to stderr; stdout is only the 64-char hex account id.
idcp_enroll_implicit_account() {
  local id="${1:?}" enroll_json account_id home
  home="$(agent_home "$id")"
  ensure_idcp_layout_for_agent "$id"
  echo "Creating NEAR implicit account for ${id} (automatic — no operator input) ..." >&2
  enroll_json="$(_idcp_host "$id" enroll)"
  echo "$enroll_json" >&2
  account_id="$(
    printf '%s' "$enroll_json" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    d={}
print(d.get("account_id") or "")
' 2>/dev/null || true
  )"
  account_id="${account_id//[[:space:]]/}"
  if [[ -z "$account_id" ]]; then
    account_id="$(_idcp_account_id_for_agent "$id")"
    account_id="${account_id//[[:space:]]/}"
  fi
  if [[ -z "$account_id" ]]; then
    echo "Could not determine implicit_account_id after enroll for ${id}." >&2
    return 1
  fi
  _idcp_mark_active "$id" "$account_id"
  ensure_near_credentials_active "$home" 2>/dev/null || true
  sync_identyclaw_env "$home" "" 2>/dev/null || true
  printf '%s' "$account_id"
}

# Natural IdentyClaw path: enroll (automatic) → purchase guide → ensure_session → me.
# Invoked from setup (last step) or standalone to resume after mint.
# Usage: idcp_setup_one_agent <agent-id>
idcp_setup_one_agent() {
  local id="${1:?}"
  local home account_id tmp_sess tmp_me attempt max_attempts

  home="$(agent_home "$id")"
  ensure_idcp_layout_for_agent "$id"
  write_idcp_wallet_scripts "$home" "$id" 2>/dev/null || true

  echo ""
  echo "=== IdentyClaw Passport: ${id} ==="
  account_id="$(idcp_enroll_implicit_account "$id")" || return 1
  echo "Recipient account (automatic): ${account_id}"

  tmp_sess="$(mktemp)"
  tmp_me="$(mktemp)"
  if _idcp_host "$id" ensure_session >"$tmp_sess" 2>/dev/null \
    && _idcp_host "$id" me >"$tmp_me" 2>/dev/null; then
    echo ""
    echo "Passport already active on home (api.identyclaw.com) for ${id}:"
    cat "$tmp_me"
    rm -f "$tmp_sess" "$tmp_me"
    print_operator_chat_next_steps "$id"
    return 0
  fi
  rm -f "$tmp_sess" "$tmp_me"

  print_passport_purchase_guide \
    "$account_id" \
    "$(agent_passport_webhook_url "$id")" \
    "$(agent_passport_avatar_url "$id")" \
    "$(agent_passport_contact_uri "$id")" \
    "$id"

  if [[ ! -t 0 ]]; then
    echo "Non-interactive TTY: after minting, re-run: ./identyclaw.sh idcp-setup ${id}" >&2
    echo "Account id saved under ${home}/secrets/near-credentials/" >&2
    return 0
  fi

  # shellcheck disable=SC2162
  read -r -p "Press Enter after the Passport mint confirms (Ctrl-C to pause; resume with ./identyclaw.sh idcp-setup ${id}) ... "

  attempt=1
  max_attempts=8
  while (( attempt <= max_attempts )); do
    echo "Activating home session for ${id} (attempt ${attempt}/${max_attempts}) ..."
    if _idcp_host "$id" ensure_session && _idcp_host "$id" me; then
      echo ""
      echo "IdentyClaw home session ready for ${id}."
      ensure_near_credentials_active "$home" 2>/dev/null || true
      sync_identyclaw_env "$home" "" 2>/dev/null || true
      print_operator_chat_next_steps "$id"
      return 0
    fi
    if (( attempt == max_attempts )); then
      break
    fi
    echo "Login failed — Passport may still be indexing, or mint not finished."
    # shellcheck disable=SC2162
    read -r -p "Press Enter to retry (or Ctrl-C and later: ./identyclaw.sh idcp-setup ${id}) ... "
    (( ++attempt ))
  done

  echo "Could not activate session yet for ${id}. After mint confirms:" >&2
  echo "  ./identyclaw.sh idcp-setup ${id}" >&2
  echo "  # or: ./identyclaw.sh idcp ${id} ensure_session && ./identyclaw.sh idcp ${id} me" >&2
  return 1
}
