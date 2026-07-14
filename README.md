# Alaya

Run the sample app:

```sh
lake exe alaya
```

It asks Yunwu to generate a small, documented function, requesting two candidates concurrently and
retrying whenever a reply fails structured-output validation. Each response is schema-validated,
parsed into typed fields, and printed. Responses are persisted in `.alaya/cache`; rerunning the app
replays them without sending another provider request.

Set `YUNWU_API_KEY` before running.