# Alaya

Run the sample app:

```sh
lake exe alaya
```

It asks Yunwu for four independently chosen integers from 1 to 1,000,000. The app requests
uncached samples concurrently and prints them in request order. Responses are persisted in
`.alaya/cache`; rerunning the app replays the same ordered sequence without sending another
provider request.

Set `YUNWU_API_KEY` before running.