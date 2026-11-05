#!/usr/bin/env bash
# تنصيب نظام تكاسي المجمّع على سيرفر Ubuntu جديد.
# التشغيل (كـ root):
#   curl -fsSL https://raw.githubusercontent.com/ftyo979vfemail-code/mansour-city/main/taxi-server/install.sh | bash
# إعادة تشغيله لاحقًا آمنة: يحدّث الكود ويحافظ على البيانات والإعدادات.
set -euo pipefail

REPO="https://github.com/ftyo979vfemail-code/mansour-city.git"
DIR=/opt/taxi
OLD_API="https://azvpzlsgzaglerapuayc.supabase.co/rest/v1/rpc"
OLD_KEY="sb_publishable_LSh2trzuxWteNF4ltsBDZA_otyI__gu"

say()  { printf '\n\033[1;33m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✘ %s\033[0m\n' "$*"; exit 1; }
ask()  { local p="$1" d="${2:-}" a; read -r -p "$p${d:+ [$d]}: " a </dev/tty || true; echo "${a:-$d}"; }
asks() { local a; read -r -s -p "$1: " a </dev/tty || true; echo >&2; echo "$a"; }

[ "$(id -u)" = 0 ] || die "شغّل السكربت كـ root (اكتب: sudo -i ثم أعد الأمر)"

say "تنصيب البرامج المطلوبة (Docker, git, jq)…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git jq curl ca-certificates >/dev/null
if ! command -v docker >/dev/null; then curl -fsSL https://get.docker.com | sh >/dev/null; fi
systemctl enable --now docker >/dev/null 2>&1 || true
ok "البرامج جاهزة"

say "تحميل كود النظام…"
if [ -d "$DIR/app/.git" ]; then git -C "$DIR/app" pull -q --ff-only; else mkdir -p "$DIR"; git clone -q --depth 1 "$REPO" "$DIR/app"; fi
cd "$DIR/app/taxi-server"
ok "الكود في $DIR/app"

FIRST=0
if [ ! -f .env ]; then
  FIRST=1
  IP=$(curl -4 -fsS https://api.ipify.org || hostname -I | awk '{print $1}')
  DEF_DOMAIN="${IP//./-}.sslip.io"
  echo
  echo "اكتب الدومين اللي ربطته بهذا السيرفر (مثل taxi.example.com)."
  echo "إذا بعدك ما عندك دومين، اضغط Enter ونستخدم عنوان مؤقت: $DEF_DOMAIN"
  DOMAIN=$(ask "الدومين" "$DEF_DOMAIN")
  EMAIL=$(ask "إيميل لشهادة الأمان HTTPS" "admin@${DOMAIN}")
  umask 077
  cat > .env <<EOF
DOMAIN=$DOMAIN
ACME_EMAIL=$EMAIL
POSTGRES_PASSWORD=$(openssl rand -hex 24)
AUTHENTICATOR_PASSWORD=$(openssl rand -hex 24)
EOF
  ok "الإعدادات انحفظت في $DIR/app/taxi-server/.env"
fi
set -a; . ./.env; set +a
mkdir -p backups

if command -v ufw >/dev/null && ufw status | grep -q active; then ufw allow 80/tcp >/dev/null; ufw allow 443 >/dev/null; fi

say "تشغيل قاعدة البيانات والسيرفر…"
docker compose pull -q
docker compose up -d
for i in $(seq 1 60); do docker compose exec -T db pg_isready -U postgres -d taxi >/dev/null 2>&1 && break; sleep 2; done
# the init scripts must have finished before we talk to the schema
for i in $(seq 1 60); do docker compose exec -T db psql -U postgres -d taxi -tAc "select 1 from pg_proc where proname='taxi_import'" 2>/dev/null | grep -q 1 && break; sleep 2; done
ok "السيرفر شغّال"

psqlq() { docker compose exec -T db psql -U postgres -d taxi -v ON_ERROR_STOP=1 -qtA "$@"; }

if [ "$FIRST" = 1 ] || [ -z "$(psqlq -c "select 1 from taxi_settings where k='admin_pin'")" ]; then
  echo
  echo "تنقل السيارات والسواق والسجلات من النظام الحالي؟ (رموز السواق تبقى نفسها)"
  MOVE=$(ask "نقل البيانات؟ (y/n)" "y")
  if [ "$MOVE" = "y" ] || [ "$MOVE" = "Y" ]; then
    PIN=$(asks "اكتب رمز المدير الحالي")
    say "نقل البيانات…"
    body=$(jq -cn --arg p "$PIN" '{p_pin:$p}')
    curl -fsS -X POST "$OLD_API/taxi_export" -H "apikey: $OLD_KEY" -H "Authorization: Bearer $OLD_KEY" \
         -H "Content-Type: application/json" -d "$body" -o /tmp/taxi-export.json \
      || die "ما گدرت أسحب البيانات. تأكد من رمز المدير وأعد تشغيل السكربت."
    jq -c . /tmp/taxi-export.json > /tmp/taxi-export.line
    { echo "create temp table imp(j json);"
      echo "copy imp from stdin with (format csv, quote e'\\x01', delimiter e'\\x02');"
      cat /tmp/taxi-export.line; echo '\.'
      echo "select taxi_import(j) from imp;"; } | psqlq | sed 's/^/   /'
    rm -f /tmp/taxi-export.json /tmp/taxi-export.line
    ok "انتقلت البيانات، ورمز المدير بقى نفسه"
  else
    while :; do
      PIN=$(asks "اختر رمز مدير جديد (4 أرقام أو أكثر)")
      [ ${#PIN} -ge 4 ] && break; echo "الرمز قصير"
    done
    psqlq -v pin="$PIN" <<<"select taxi_set_admin_pin(:'pin');" >/dev/null
    ok "رمز المدير انحفظ"
  fi
fi

# The update helper: `taxi-update` pulls the latest code and restarts.
cat > /usr/local/bin/taxi-update <<'EOF'
#!/bin/sh
set -e
cd /opt/taxi/app && git pull -q --ff-only && cd taxi-server && docker compose pull -q && docker compose up -d && echo "تم التحديث"
EOF
chmod +x /usr/local/bin/taxi-update

say "انتظار شهادة الأمان HTTPS…"
for i in $(seq 1 30); do curl -fsS "https://$DOMAIN/healthz" >/dev/null 2>&1 && break; sleep 3; done
if curl -fsS "https://$DOMAIN/healthz" >/dev/null 2>&1; then
  ok "كل شي جاهز"
else
  echo "الشهادة بعدها ما طلعت. تأكد إن الدومين $DOMAIN مربوط على IP هذا السيرفر، وبعد دقائق افتح الرابط."
fi

cat <<EOF

════════════════════════════════════════════
  لوحة الإدارة:  https://$DOMAIN/
  صفحة السائق:   https://$DOMAIN/#driver
  النسخ الاحتياطي اليومي: $DIR/app/taxi-server/backups
  للتحديث لاحقًا اكتب:  taxi-update
════════════════════════════════════════════
EOF
