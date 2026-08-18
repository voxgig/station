# CI

`github-build.yml` is the GitHub Actions workflow for this repo (every
port's suite + the shared conformance corpus; see the file's header).

It lives here rather than in `.github/workflows/` because the
automation credential that authored it cannot push workflow files
(no `workflow` OAuth scope). To activate it:

```bash
mkdir -p .github/workflows
git mv ci/github-build.yml .github/workflows/build.yml
```
