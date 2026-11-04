#!/bin/zsh
# Switch the SMS sender number the Cloud Functions use, in ONE step.
#
#   scripts/sms-sender.sh 866    # approval day: switch to the toll-free number
#   scripts/sms-sender.sh 289    # revert: back to the old local number
#   scripts/sms-sender.sh status # show current sender + verification status, change nothing
#
# Why a script: every deployed function is PINNED to a secret version
# (TWILIO_PHONE_NUMBER@2 as of 2026-11-04). Setting a new value alone
# changes nothing until the functions are redeployed, and redeploying
# only some of them would leave a half-switched state where the test
# SMS and the shift texts use different numbers. This does both, for
# every function that sends SMS, and checks the result.
#
# Safety: refuses to switch to 866 unless Twilio reports its toll-free
# verification as TWILIO_APPROVED. Before approval every message from it
# is blocked (error 30032) and still billed. It never edits, resubmits
# or withdraws the verification, and never buys or releases a number.

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="whyte-routes"
TOLLFREE="+18663217121"
LOCAL="+12898026468"
# Every function that reads TWILIO_PHONE_NUMBER (see functions/index.js).
SMS_FUNCTIONS="functions:sendCustomerNotification,functions:sendShiftStartNotifications,functions:sendMorningSummaries,functions:sendTestNotification,functions:sendTrackingLink"

secret() {
  firebase functions:secrets:access "$1" --project "$PROJECT" 2>/dev/null | grep -vE "^(Error|ERROR|$)" | head -1
}

tfv_status() {
  local sid tok
  sid=$(secret TWILIO_ACCOUNT_SID | grep -oE 'AC[0-9a-f]{32}')
  tok=$(secret TWILIO_AUTH_TOKEN | grep -oE '^[0-9a-f]{32}$')
  curl -s -u "$sid:$tok" "https://messaging.twilio.com/v1/Tollfree/Verifications?TollfreePhoneNumberSid=PNe275990cf4e56bb961ef2f13af40370e" \
    | python3 -I -c 'import json,sys; v=json.load(sys.stdin).get("verifications",[]); print(v[0]["status"] if v else "NONE")'
}

current=$(secret TWILIO_PHONE_NUMBER)
echo "Current sender:            $current"
echo "866 verification status:   $(tfv_status)"

case "${1:-}" in
  status) exit 0 ;;
  866)
    target="$TOLLFREE"
    st=$(tfv_status)
    if [[ "$st" != "TWILIO_APPROVED" ]]; then
      echo "✋ Refusing: the 866 verification is '$st', not TWILIO_APPROVED. Nothing changed."
      exit 1
    fi
    ;;
  289) target="$LOCAL" ;;
  *) echo "Usage: $0 866 | 289 | status"; exit 2 ;;
esac

if [[ "$current" == "$target" ]]; then
  echo "Already sending from $target. Redeploying anyway so every function is on the latest version."
else
  echo "Setting TWILIO_PHONE_NUMBER -> $target ..."
  printf '%s' "$target" | firebase functions:secrets:set TWILIO_PHONE_NUMBER --data-file=- --project "$PROJECT" --non-interactive
  now=$(secret TWILIO_PHONE_NUMBER)
  if [[ "$now" != "$target" ]]; then
    echo "❌ Secret reads back as '$now', expected '$target'. Stopping before deploy."
    exit 1
  fi
fi

echo "Redeploying the SMS functions so they pick up the new value ..."
# One retry: the Nov 4 deploy failed once on a transient Secret Manager
# request and succeeded on the second try.
firebase deploy --only "$SMS_FUNCTIONS" --project "$PROJECT" --non-interactive \
  || { echo "Deploy failed once, retrying in 15s ..."; sleep 15; firebase deploy --only "$SMS_FUNCTIONS" --project "$PROJECT" --non-interactive; }

echo "✅ Done. Sender is now $(secret TWILIO_PHONE_NUMBER) for all SMS functions."
echo "Next: send ONE in-app Test SMS, then check Twilio Console > Monitor > Logs > Messaging."
