# SMS approval-day runbook (toll-free +1 866-321-7121)

Prepared 2026-11-04. Nothing in here has been applied. The sender is still
+12898026468 until Hope says, in her own words, "swap to the 866 number".

Rules that hold the whole way through:
- The 866 toll-free verification is never edited, resubmitted or withdrawn from here.
- Real customers stay opted OUT. Test recipients: Hope (+16472225239) and,
  once confirmed, Devon (on the internal test route only).
- No number is bought, released or deleted.

---

## 0. Before approval day (once)
- [ ] App built from `v1.1-dev` (af477bb or later) installed on Hope's phone via Xcode.
      It has the new test screen (green only for confirmed delivery, SID, sender).
- [ ] Twilio balance topped up / auto-recharge on (it was $13.95 USD on 2026-11-04).
- [ ] Internal test route exists (section 4). NOT created yet; waiting on decisions.

## 1. Confirm approval
Claude runs (read-only):

```bash
scripts/sms-sender.sh status
```

Expected: `866 verification status: TWILIO_APPROVED`.
Anything else (IN_REVIEW, TWILIO_REJECTED): stop here. If rejected, read
`rejection_reasons` and `edit_allowed`/`edit_expiration` (there is a 7-day
edit window) and bring them to Hope. Nothing gets resubmitted without her go.

## 2. Swap (only after Hope says "swap to the 866 number")

```bash
scripts/sms-sender.sh 866
```

What it does: re-checks approval (refuses otherwise), sets
`TWILIO_PHONE_NUMBER` to +18663217121 (a new secret version), reads it back,
then redeploys every SMS function (sendCustomerNotification,
sendShiftStartNotifications, sendMorningSummaries, sendTestNotification,
sendTrackingLink) so none is left on the old version. About 2-3 minutes.

## 3. Test 1: one in-app Test SMS to Hope's phone
1. App > Settings > Test Notifications > `+16472225239` > **Send Test SMS**.
2. Expected on screen: **"✅ Delivered - the carrier confirmed it reached the phone."**,
   "Sent from +18663217121", and a Twilio SID.
3. The verdict comes from **Twilio's log**, not the app:
   Twilio Console > Monitor > Logs > Messaging > open the newest message.
   PASS = From **+18663217121**, Status **Delivered**, no error code.
   (Claude can also read it by API and report SID / status / error.)

FAIL = anything else (Undelivered, Failed, any error code) → go to section 6.

## 4. Test 2: shift-start on the internal test route
Setup (pending Hope's decisions, see the report of 2026-11-04):
- A route named e.g. "SMS Test Route", whose driver is Hope, with exactly two stops.
- Two test customers, opted in: Hope (+16472225239) and Devon (number + his OK pending).
- No real customer on this route. Real customers' opt-in untouched.

Run:
1. As the driver on that route, tap **Start Shift**.
2. Both phones should get: "DW Landscaping: We're on our way for your service today.
   Track us live: https://whyte-routes.web.app/t/… Reply STOP to opt out."
   (Starts with "WHYTE ROUTES:" instead if the company turned off
   Settings > "Show business name in customer texts".)
3. Twilio log: two new messages, both From **+18663217121**, Status **Delivered**.
4. Optional: mark one stop **Completed** → that customer gets the completion receipt;
   check the log the same way.

Expected function log line (Claude reads it):
`📣 shiftStart route <id> (company ...): 2/2 accepted`

## 5. After both tests pass
- Texts are live. Real customers only start receiving them once each one is
  opted in on their customer record (owner's decision, per real consent).
- The 289 number keeps costing $1.15/month. Release it only on Hope's say-so,
  ideally after a week or two of clean 866 traffic.

## 6. Revert (any failure in sections 3-4)

```bash
scripts/sms-sender.sh 289
```

Puts every SMS function back on +12898026468 (same redeploy path), so nothing
is left half-switched. Then: read the failed message's error code in Twilio and
bring it to Hope before trying again.
