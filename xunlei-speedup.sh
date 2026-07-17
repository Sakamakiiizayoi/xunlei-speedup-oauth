#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# 迅雷快鸟：网页 OAuth Refresh Token -> PKCE 授权 -> 快鸟 Token -> 开通试用
#
# 依赖：curl jq openssl（可选 flock）
# 首次：./xunlei_speedup_oauth.sh init
# 使用：./xunlei_speedup_oauth.sh
# 状态：~/.local/state/xunlei-speedup-oauth/state.json

STATE_FILE="${XL_STATE_FILE:-$HOME/.local/state/xunlei-speedup-oauth/state.json}"
DEBUG_DIR="${XL_DEBUG_DIR:-$HOME/.local/state/xunlei-speedup-oauth/debug}"

ACCOUNT_CLIENT_ID="${XL_ACCOUNT_CLIENT_ID:-XW5SkOhLDjnOZP7J}"
SPEEDUP_CLIENT_ID="${XL_SPEEDUP_CLIENT_ID:-ZN3CT_2NLl6a5Q7n}"

XLUSER_BASE="https://xluser-ssl.xunlei.com"
TOKEN_URL="$XLUSER_BASE/v1/auth/token"
AUTHORIZE_URL="$XLUSER_BASE/v1/user/authorize"
SPEEDUP_OPEN_URL="https://speedup.xunlei.com/v1/open"

REDIRECT_URI="https://vip.xunlei.com/pages/2023/broadband-speed/m/?referfrom=k_gw"
SIGN_OUT_URI="https://vip.xunlei.com/pages/2023/broadband-speed/m/sign-out?sso_sign_out="
SCOPE="profile user sso"

ACCOUNT_UA="${XL_ACCOUNT_UA:-Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36}"
SPEEDUP_UA="${XL_SPEEDUP_UA:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36}"

log()  { printf '[*] %s\n' "$*" >&2; }
ok()   { printf '[+] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf -- "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

new_tmp() {
  mktemp "$TMP_DIR/response.XXXXXX"
}

for cmd in curl jq openssl mktemp date sed grep; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖：$cmd"
done

mkdir -p "$(dirname "$STATE_FILE")" "$DEBUG_DIR"
chmod 700 "$(dirname "$STATE_FILE")" "$DEBUG_DIR" 2>/dev/null || true

# 防止 cron 或手动运行发生并发刷新，导致 refresh_token 轮换冲突。
if command -v flock >/dev/null 2>&1; then
  exec 9>"${STATE_FILE}.lock"
  flock -n 9 || die '已有另一个实例正在运行'
fi

state_init_empty() {
  [[ -f "$STATE_FILE" ]] || printf '{}\n' >"$STATE_FILE"
  chmod 600 "$STATE_FILE"
  jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1 || die "状态文件不是有效 JSON：$STATE_FILE"
}

state_get() {
  local key="$1"
  jq -r --arg key "$key" '.[$key] // empty' "$STATE_FILE"
}

state_atomic_update() {
  local filter="$1"
  shift
  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  if ! jq "$@" "$filter" "$STATE_FILE" >"$tmp"; then
    rm -f "$tmp"
    die '更新状态文件失败'
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

mask_value() {
  local value="$1" n=${#1}
  if (( n <= 12 )); then
    printf '<已设置，长度 %d>' "$n"
  else
    printf '%s…%s（长度 %d）' "${value:0:6}" "${value:n-4:4}" "$n"
  fi
}

init_command() {
  state_init_empty

  local device_id account_device_sign refresh_token
  device_id="${XL_DEVICE_ID:-$(state_get device_id)}"
  account_device_sign="${XL_ACCOUNT_DEVICE_SIGN:-$(state_get account_device_sign)}"
  refresh_token="${XL_ACCOUNT_REFRESH_TOKEN:-}"

  if [[ -z "$device_id" ]]; then
    read -r -p '账号中心请求中的 x-device-id：' device_id
  else
    printf '账号中心 x-device-id [%s]：' "$device_id"
    local input=''
    read -r input
    [[ -z "$input" ]] || device_id="$input"
  fi

  if [[ -z "$account_device_sign" ]]; then
    read -r -p '账号中心请求中的 x-device-sign（可留空尝试）：' account_device_sign
  else
    printf '账号中心 x-device-sign 已存在，直接回车保留；输入新值覆盖：'
    local sign_input=''
    read -r sign_input
    [[ -z "$sign_input" ]] || account_device_sign="$sign_input"
  fi

  if [[ -z "$refresh_token" ]]; then
    read -r -s -p 'credentials_XW5SkOhLDjnOZP7J 中最新的 refresh_token：' refresh_token
    printf '\n'
  fi

  [[ -n "$device_id" ]] || die 'x-device-id 不能为空'
  [[ -n "$refresh_token" ]] || die 'refresh_token 不能为空'

  state_atomic_update '
    .device_id = $device_id
    | .account_device_sign = $account_device_sign
    | .refresh_token = $refresh_token
    | .account_client_id = $account_client_id
    | .speedup_client_id = $speedup_client_id
  ' \
    --arg device_id "$device_id" \
    --arg account_device_sign "$account_device_sign" \
    --arg refresh_token "$refresh_token" \
    --arg account_client_id "$ACCOUNT_CLIENT_ID" \
    --arg speedup_client_id "$SPEEDUP_CLIENT_ID"

  ok "初始化完成：$STATE_FILE"
  warn 'refresh_token 会轮换；以后以状态文件中的新值为准，不要再使用旧值。'
}

status_command() {
  state_init_empty
  local device_id sign refresh user_id saved_at
  device_id="$(state_get device_id)"
  sign="$(state_get account_device_sign)"
  refresh="$(state_get refresh_token)"
  user_id="$(state_get user_id)"
  saved_at="$(state_get token_saved_at)"

  printf '状态文件：%s\n' "$STATE_FILE"
  printf 'user_id：%s\n' "${user_id:-<未知>}"
  printf 'device_id：%s\n' "${device_id:-<未设置>}"
  printf 'device_sign：%s\n' "$( [[ -n "$sign" ]] && mask_value "$sign" || printf '<未设置>' )"
  printf 'refresh_token：%s\n' "$( [[ -n "$refresh" ]] && mask_value "$refresh" || printf '<未设置>' )"
  printf '最近刷新时间戳：%s\n' "${saved_at:-<无>}"
}

account_headers() {
  ACCOUNT_HEADERS=(
    -H 'accept: */*'
    -H 'accept-language: zh-CN'
    -H 'content-type: application/json'
    -H 'origin: https://i.xunlei.com'
    -H 'referer: https://i.xunlei.com/'
    -H "user-agent: $ACCOUNT_UA"
    -H "x-client-id: $ACCOUNT_CLIENT_ID"
    -H 'x-client-version: 1.1.13'
    -H "x-device-id: $DEVICE_ID"
    -H 'x-device-model: chrome%2F150.0.0.0'
    -H 'x-device-name: Mobile-Chrome'
    -H 'x-net-work-type: NONE'
    -H 'x-os-version: Win32'
    -H 'x-platform-version: 3'
    -H 'x-protocol-version: 301'
    -H 'x-provider-name: NONE'
    -H 'x-sdk-version: 9.1.2'
  )
  [[ -z "$ACCOUNT_DEVICE_SIGN" ]] || ACCOUNT_HEADERS+=( -H "x-device-sign: $ACCOUNT_DEVICE_SIGN" )
}

pretty_or_cat() {
  local file="$1"
  jq . "$file" 2>/dev/null || cat "$file"
}

save_debug() {
  local name="$1" file="$2"
  if [[ "${XL_DEBUG:-0}" == '1' ]]; then
    cp "$file" "$DEBUG_DIR/$name"
    chmod 600 "$DEBUG_DIR/$name"
    warn "已保存调试响应：$DEBUG_DIR/$name"
  fi
}

refresh_account_token() {
  local body response http new_access new_refresh user_id expires_in expires_at now
  response="$(new_tmp)"

  body="$(jq -nc \
    --arg grant_type 'refresh_token' \
    --arg refresh_token "$ACCOUNT_REFRESH_TOKEN" \
    --arg client_id "$ACCOUNT_CLIENT_ID" \
    '{grant_type:$grant_type,refresh_token:$refresh_token,client_id:$client_id}')"

  log '1/4 刷新迅雷账号中心 Token'
  http="$(curl --silent --show-error --compressed \
    --connect-timeout 15 --max-time 60 \
    --output "$response" --write-out '%{http_code}' \
    --request POST "$TOKEN_URL" \
    "${ACCOUNT_HEADERS[@]}" \
    --data-raw "$body")"

  save_debug '01-refresh.json' "$response"

  new_access="$(jq -r '.access_token // empty' "$response" 2>/dev/null || true)"
  new_refresh="$(jq -r '.refresh_token // empty' "$response" 2>/dev/null || true)"
  user_id="$(jq -r '.user_id // .sub // empty' "$response" 2>/dev/null || true)"
  expires_in="$(jq -r '.expires_in // 7200' "$response" 2>/dev/null || printf '7200')"

  if [[ "$http" != 2* || -z "$new_access" || -z "$user_id" ]]; then
    warn "账号中心 Token 刷新失败（HTTP $http）"
    pretty_or_cat "$response" >&2
    return 1
  fi

  # 服务器会轮换 refresh_token。必须在后续网络步骤之前立即原子保存。
  [[ -n "$new_refresh" ]] || new_refresh="$ACCOUNT_REFRESH_TOKEN"
  now="$(date +%s)"
  expires_at="$((now + expires_in))"

  state_atomic_update '
    .refresh_token = $refresh_token
    | .account_access_token = $access_token
    | .user_id = $user_id
    | .account_access_expires_at = ($expires_at | tonumber)
    | .token_saved_at = ($saved_at | tonumber)
  ' \
    --arg refresh_token "$new_refresh" \
    --arg access_token "$new_access" \
    --arg user_id "$user_id" \
    --arg expires_at "$expires_at" \
    --arg saved_at "$now"

  ACCOUNT_ACCESS_TOKEN="$new_access"
  ACCOUNT_REFRESH_TOKEN="$new_refresh"
  USER_ID="$user_id"
  ok "账号中心 Token 刷新成功，user_id=$USER_ID；新 refresh_token 已落盘"
}

base64url_sha256() {
  printf '%s' "$1" \
    | openssl dgst -sha256 -binary \
    | openssl base64 -A \
    | tr '+/' '-_' \
    | tr -d '='
}

generate_pkce() {
  CODE_VERIFIER="$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n')"
  CODE_CHALLENGE="$(base64url_sha256 "$CODE_VERIFIER")"
  OAUTH_STATE="state-$(openssl rand -hex 12)"
}

extract_authorization_code() {
  local file="$1" candidate code

  # 兼容 code 直接返回、嵌套返回，或返回 redirect URL 的不同结构。
  while IFS= read -r candidate; do
    [[ -n "$candidate" && "$candidate" != 'null' ]] || continue

    if [[ "$candidate" == a1.* ]]; then
      printf '%s' "$candidate"
      return 0
    fi

    code="$(printf '%s' "$candidate" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')"
    if [[ -n "$code" ]]; then
      printf '%s' "$code"
      return 0
    fi
  done < <(
    jq -r '
      [
        .code,
        .authorization_code,
        .data.code,
        .result.code,
        .redirect_uri,
        .redirect_url,
        .url,
        .location,
        .data.redirect_uri,
        .data.redirect_url,
        .data.url,
        .data.location,
        .result.redirect_uri,
        .result.redirect_url,
        .result.url,
        .result.location,
        (if type == "string" then . else empty end)
      ]
      | .[]
      | select(type == "string" and length > 0)
    ' "$file" 2>/dev/null || true
  )

  # 最后再从原始正文中直接寻找 a1.xxx。
  code="$(grep -Eo 'a1\.[A-Za-z0-9_-]+' "$file" | head -n1 || true)"
  [[ -n "$code" ]] && { printf '%s' "$code"; return 0; }
  return 1
}

request_speedup_authorization_code() {
  local body response http code
  response="$(new_tmp)"

  body="$(jq -nc \
    --arg client_id "$SPEEDUP_CLIENT_ID" \
    --arg response_type 'code' \
    --arg redirect_uri "$REDIRECT_URI" \
    --arg state "$OAUTH_STATE" \
    --arg scope "$SCOPE" \
    --arg code_challenge "$CODE_CHALLENGE" \
    --arg code_challenge_method 'S256' \
    --arg sign_out_uri "$SIGN_OUT_URI" \
    '{client_id:$client_id,response_type:$response_type,redirect_uri:$redirect_uri,state:$state,scope:$scope,code_challenge:$code_challenge,code_challenge_method:$code_challenge_method,sign_out_uri:$sign_out_uri}')"

  log '2/4 使用账号中心 Token 获取快鸟 OAuth 授权码'
  http="$(curl --silent --show-error --compressed \
    --connect-timeout 15 --max-time 60 \
    --output "$response" --write-out '%{http_code}' \
    --request POST "$AUTHORIZE_URL" \
    "${ACCOUNT_HEADERS[@]}" \
    -H "authorization: Bearer $ACCOUNT_ACCESS_TOKEN" \
    --data-raw "$body")"

  save_debug '02-authorize.json' "$response"

  if [[ "$http" != 2* ]]; then
    warn "获取授权码失败（HTTP $http）"
    pretty_or_cat "$response" >&2
    return 1
  fi

  code="$(extract_authorization_code "$response" || true)"
  if [[ -z "$code" ]]; then
    warn '接口返回成功，但未能从响应中识别 authorization code'
    pretty_or_cat "$response" >&2
    warn '请使用 XL_DEBUG=1 重新运行并提供 02-authorize.json（先遮盖 Token）。'
    return 1
  fi

  AUTHORIZATION_CODE="$code"
  ok '已取得快鸟 OAuth 授权码'
}

exchange_speedup_token() {
  local body response http access user_id expires_in callback_referer
  response="$(new_tmp)"

  body="$(jq -nc \
    --arg code "$AUTHORIZATION_CODE" \
    --arg grant_type 'authorization_code' \
    --arg code_verifier "$CODE_VERIFIER" \
    --arg redirect_uri "$REDIRECT_URI" \
    --arg client_id "$SPEEDUP_CLIENT_ID" \
    '{code:$code,grant_type:$grant_type,code_verifier:$code_verifier,redirect_uri:$redirect_uri,client_id:$client_id}')"

  callback_referer="${REDIRECT_URI}&code=${AUTHORIZATION_CODE}&expires_in=120&scope=profile+user+sso&state=${OAUTH_STATE}"

  log '3/4 使用授权码兑换快鸟 Access Token'
  http="$(curl --silent --show-error --compressed \
    --connect-timeout 15 --max-time 60 \
    --output "$response" --write-out '%{http_code}' \
    --request POST "$TOKEN_URL" \
    -H 'accept: */*' \
    -H 'accept-language: en' \
    -H 'content-type: application/json' \
    -H 'origin: https://vip.xunlei.com' \
    -H "referer: $callback_referer" \
    -H "user-agent: $SPEEDUP_UA" \
    -H "x-client-id: $SPEEDUP_CLIENT_ID" \
    -H "x-device-id: $DEVICE_ID" \
    -H 'x-protocol-version: 301' \
    -H 'x-sdk-version: 7.0.8' \
    --data-raw "$body")"

  save_debug '03-speedup-token.json' "$response"

  access="$(jq -r '.access_token // empty' "$response" 2>/dev/null || true)"
  user_id="$(jq -r '.user_id // .sub // empty' "$response" 2>/dev/null || true)"
  expires_in="$(jq -r '.expires_in // 7200' "$response" 2>/dev/null || printf '7200')"

  if [[ "$http" != 2* || -z "$access" || -z "$user_id" ]]; then
    warn "兑换快鸟 Token 失败（HTTP $http）"
    pretty_or_cat "$response" >&2
    return 1
  fi

  SPEEDUP_ACCESS_TOKEN="$access"
  USER_ID="$user_id"

  state_atomic_update '
    .user_id = $user_id
    | .speedup_access_expires_at = ($expires_at | tonumber)
  ' \
    --arg user_id "$USER_ID" \
    --arg expires_at "$(( $(date +%s) + expires_in ))"

  ok '快鸟 Access Token 兑换成功'
}

open_speedup() {
  local body response http ret msg error_code
  response="$(new_tmp)"

  body="$(jq -nc --arg exp_ver '2' --arg user_id "$USER_ID" '{exp_ver:$exp_ver,user_id:$user_id}')"

  log '4/4 调用快鸟开通/试用接口'
  http="$(curl --silent --show-error --compressed \
    --connect-timeout 15 --max-time 60 \
    --output "$response" --write-out '%{http_code}' \
    --request POST "${SPEEDUP_OPEN_URL}?user_id=${USER_ID}" \
    -H 'accept: application/json, text/plain, */*' \
    -H 'accept-language: zh-CN,zh;q=0.9' \
    -H "authorization: $SPEEDUP_ACCESS_TOKEN" \
    -H 'channel;' \
    -H 'content-type: application/json' \
    -H 'origin: https://vip.xunlei.com' \
    -H 'platform: web' \
    -H "referer: $REDIRECT_URI" \
    -H "user-agent: $SPEEDUP_UA" \
    -H 'version-name;' \
    -H "x-device-id: $DEVICE_ID" \
    --data-raw "$body")"

  save_debug '04-open.json' "$response"

  printf '%s\n' '----- 快鸟接口响应 -----'
  pretty_or_cat "$response"
  printf '%s\n' '------------------------'

  if [[ "$http" != 2* ]]; then
    warn "快鸟接口 HTTP 异常：$http"
    return 20
  fi

  ret="$(jq -r '.ret // empty' "$response" 2>/dev/null || true)"
  msg="$(jq -r '.msg // .message // empty' "$response" 2>/dev/null || true)"
  error_code="$(jq -r '.error_code // empty' "$response" 2>/dev/null || true)"

  case "$ret" in
    0)
      ok "提速/试用开通成功${msg:+：$msg}"
      return 0
      ;;
    11)
      warn "今天的试用机会已用完${msg:+：$msg}${error_code:+（error_code=$error_code）}"
      return 11
      ;;
    16)
      warn "快鸟登录鉴权失败${msg:+：$msg}"
      return 16
      ;;
    '')
      warn '响应里没有 ret 字段，请根据上方 JSON 判断结果'
      return 21
      ;;
    *)
      warn "快鸟返回业务状态 ret=$ret${msg:+：$msg}${error_code:+（error_code=$error_code）}"
      return 22
      ;;
  esac
}

run_command() {
  state_init_empty

  DEVICE_ID="$(state_get device_id)"
  ACCOUNT_DEVICE_SIGN="$(state_get account_device_sign)"
  ACCOUNT_REFRESH_TOKEN="$(state_get refresh_token)"

  # 首次也允许从环境变量导入；一旦轮换完成，以状态文件为准。
  [[ -n "$DEVICE_ID" ]] || DEVICE_ID="${XL_DEVICE_ID:-}"
  [[ -n "$ACCOUNT_DEVICE_SIGN" ]] || ACCOUNT_DEVICE_SIGN="${XL_ACCOUNT_DEVICE_SIGN:-}"
  [[ -n "$ACCOUNT_REFRESH_TOKEN" ]] || ACCOUNT_REFRESH_TOKEN="${XL_ACCOUNT_REFRESH_TOKEN:-}"

  [[ -n "$DEVICE_ID" ]] || die "尚未配置 x-device-id，请先运行：$0 init"
  [[ -n "$ACCOUNT_REFRESH_TOKEN" ]] || die "尚未配置 refresh_token，请先运行：$0 init"

  # 确保首次由环境变量导入的值被保存。
  state_atomic_update '
    .device_id = $device_id
    | .account_device_sign = $account_device_sign
    | .refresh_token = $refresh_token
    | .account_client_id = $account_client_id
    | .speedup_client_id = $speedup_client_id
  ' \
    --arg device_id "$DEVICE_ID" \
    --arg account_device_sign "$ACCOUNT_DEVICE_SIGN" \
    --arg refresh_token "$ACCOUNT_REFRESH_TOKEN" \
    --arg account_client_id "$ACCOUNT_CLIENT_ID" \
    --arg speedup_client_id "$SPEEDUP_CLIENT_ID"

  account_headers
  refresh_account_token
  generate_pkce
  request_speedup_authorization_code
  exchange_speedup_token
  open_speedup
}

usage() {
  cat <<EOF
用法：
  $0 init       首次写入 device_id、device_sign、refresh_token
  $0 run        完整执行（默认）
  $0 refresh    只测试账号中心 refresh_token 刷新
  $0 status     查看状态（不会输出完整 Token）

环境变量：
  XL_STATE_FILE                自定义状态文件路径
  XL_DEVICE_ID                 首次导入 x-device-id
  XL_ACCOUNT_DEVICE_SIGN       首次导入账号中心 x-device-sign（可选）
  XL_ACCOUNT_REFRESH_TOKEN     首次导入 refresh_token
  XL_DEBUG=1                   保存各步骤响应到调试目录
EOF
}

command="${1:-run}"
case "$command" in
  init)
    init_command
    ;;
  run)
    run_command
    ;;
  refresh)
    state_init_empty
    DEVICE_ID="$(state_get device_id)"
    ACCOUNT_DEVICE_SIGN="$(state_get account_device_sign)"
    ACCOUNT_REFRESH_TOKEN="$(state_get refresh_token)"
    [[ -n "$DEVICE_ID" ]] || die '未配置 device_id'
    [[ -n "$ACCOUNT_REFRESH_TOKEN" ]] || die '未配置 refresh_token'
    account_headers
    refresh_account_token
    ;;
  status)
    status_command
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
