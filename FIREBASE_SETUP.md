# Firebase Console — what you actually need to do

Short version: **nothing, unless the owner sync warning shows up in the app.** Owner accounts, roles, and subscription status are all created automatically by the app the first time each account signs in. You do not need to create any Firestore documents, users, or records by hand.

## The one thing to verify (not "set up" — verify)

The app writes a `users/{uid}` document for each owner account the first time it signs in. For that write to succeed, your Firestore **security rules** need to allow a signed-in user to read/write their own document. If your rules already do this in some form, there's nothing to change.

Go to **Firebase Console → Firestore Database → Rules**, and confirm something equivalent to this exists:

```
match /users/{userId} {
  allow read, write: if request.auth != null && request.auth.uid == userId;
}
```

**How to tell if this is missing, without opening the Rules tab:** open the app and sign in as an owner account. If you see a gold warning banner at the top of the Owner screens saying *"Owner access is active, but not saved to the server,"* that means the write failed — almost always because of this rule. The app still works (you still get full owner access, every session), it just isn't being saved to Firestore, so nothing else in Firebase (analytics on owner status, admin tooling you build later, etc.) can see it yet.

If you never see that banner, your rules are already fine and there's nothing to do here.

## What the app does automatically (no console work needed)

- Recognizes the two permanent owner accounts by their Firebase UID (not email — an email can change, the UID can't):
  - `x5cxMZN5TKTXcIwrVMAPmQJOp3R2` (teamdwlandscaping@gmail.com)
  - `bMeTRuhikKVlCU6rE8QFBp0TXAz1` (hopeseneoudom@icloud.com)
- On first sign-in for either account, creates `users/{uid}` in Firestore with:
  ```
  { "uid": "...", "email": "...", "role": "owner", "subscription": "premiumPlus", "isAdmin": true }
  ```
- On every later sign-in, reads that document directly — the UID list is only a one-time bootstrap, not something checked on every login once the document exists.
- If the document read/write ever fails (offline, rules issue), local owner access still works that session — nothing is blocked — and the app quietly retries the same auto-creation on the next sign-in.

## Adding a third owner later

Add their UID to `ownerUIDs` in `App/Auth/AccessControl.swift` (and their email to `ownerEmails` right below it, as a fallback), rebuild, and their `users/{uid}` document gets created automatically the first time they sign in — same as the first two. No Firestore document creation needed.
