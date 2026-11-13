This is a canary for an automated test setup. Do exactly this, nothing else:

1. Run `gh api user -q .login` and `km --version`.
2. Write the file `canary.txt` in the current folder with the single line `ok`.
3. Reply with four lines: the login; the km version; whether step 2 worked; the full paths of every CLAUDE.md or memory file loaded into this session, or `none`. Then a last line that is exactly KM-E2E-DONE.
