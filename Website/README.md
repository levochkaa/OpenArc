# OpenArc Website

`https://openarc.su` serves the build in `dist`: the React landing page from `src` and the static pages `public/privacy`, `public/support` and `public/terms`. Copy it to the server with `COPYFILE_DISABLE=1`.

To work on the landing page:

```bash
npm install
npm run dev
npm run build
```

It loads releases from `VITE_RELEASES_API_URL`, defaulting to `https://api.openarc.su/v1/releases`, served by `Backend`. Download buttons take the latest stable release, or the newest beta while there is none. The release list shows stable releases only, three at first, and stays hidden until the first one ships.
