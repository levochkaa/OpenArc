# OpenArc Website

Production serves only the static pages `public/privacy`, `public/support` and `public/terms` from `https://openarc.su`, with `public/favicon.svg`. Copy them to the server with `COPYFILE_DISABLE=1`.

The React landing page in `src` is not deployed. To work on it:

```bash
npm install
npm run dev
npm run build
```

It loads release notes and downloads from `VITE_RELEASES_API_URL`, defaulting to `https://api.openarc.su/v1/releases`, served by `Backend`.
