#!/usr/bin/env bash
# Sourced by monitor.sh. The webhook is passed to curl through stdin config,
# never through argv or logs.
send_notification() {
    local severity="$1" check="$2" detail="$3" threshold="$4" color payload webhook response http
    case "$severity" in critical) color=15158332 ;; warning) color=15105570 ;; recovery) color=3066993 ;; *) return 1 ;; esac
    [ -s "$WEBHOOK_FILE" ] || { echo 'Discord webhook is missing.' >&2; return 1; }
    webhook="$(< "$WEBHOOK_FILE")"
    [[ "$webhook" =~ ^https://(discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ ]] || {
        echo 'Invalid Discord webhook configuration.' >&2; return 1;
    }
    payload="$(jq -nc --arg hostname "$(hostname)" --arg severity "$severity" --arg check "$check" \
        --arg detail "$detail" --arg threshold "$threshold" --arg timestamp "$(date -u +%FT%TZ)" \
        --argjson color "$color" '{allowed_mentions:{parse:[]},embeds:[{title:("Infrastructure " + $severity),color:$color,fields:[{name:"Host",value:$hostname,inline:true},{name:"Check",value:$check,inline:true},{name:"Current",value:$detail},{name:"Expected",value:$threshold}],timestamp:$timestamp}]}')" || return 1
    # curl reads URL from stdin configuration. Its diagnostics are suppressed to
    # prevent the credential from appearing in service logs.
    http="$( { printf 'url = "%s"\n' "$webhook"; } | curl --config - --silent --output /dev/null \
        --write-out '%{http_code}' --connect-timeout 5 --max-time 12 --retry 2 --retry-delay 2 \
        --retry-all-errors -H 'Content-Type: application/json' --data-binary "$payload" 2>/dev/null)" || return 1
    [ "$http" = 204 ] || { echo "Discord returned HTTP $http" >&2; return 1; }
}
