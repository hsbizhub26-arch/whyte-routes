# Firestore rules tests

Executable proof that the security rules do what the comments in
`firestore.rules` claim. Requires Java (the Firestore emulator).

    cd firestore-tests && npm install && npm test

Covers cross-tenant isolation, driver stop scoping, the tracking-link
lifecycle, tracking-token enumeration/repointing, and privilege
escalation via `users/{uid}`.

These run entirely against the emulator. They never touch production
data and never send an SMS.
