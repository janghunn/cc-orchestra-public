# Running the shell suites

GitHub's Contents API creates new files without the executable bit. Run both suites explicitly
through Bash (the CI workflow does the same):

```bash
bash tests/test-policy.sh
bash tests/test-runtime.sh
bash tests/test-accepted-status.sh
```

`./install.sh` makes runtime launchers and hooks executable before use.
