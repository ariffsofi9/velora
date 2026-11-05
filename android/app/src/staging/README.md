# Reserved staging source set

Application ID: `com.example.velora.staging`. Flavor: `staging`.

After separately approved Firebase Android app registration, place the genuine
`velora-fyp-staging` configuration at `android/app/src/staging/google-services.json`.
Never copy the root legacy file here. No configuration is supplied in this batch.
Gradle rejects missing/mismatched configuration before Google Services processing.
Even valid configuration remains blocked pending native verification approval.
See `docs/FIREBASE_STAGING.md` for approval gates and future commands.
