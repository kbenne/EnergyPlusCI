# Dispatcher

The dispatcher watches GitHub for queued workflow runs and uses the Proxmox API to
spin up a single ephemeral runner VM at a time. It generates a registration token,
renders cloud-init user-data, uploads it as a snippet, then clones and boots the
template VM.

## Cloud-Init User-Data (Manual Testing)

Use the runner user-data template:

```
runners/ubuntu-2404/cloud-init/runner-user-data.pkrtpl
```

In normal operation the dispatcher renders this template automatically. For manual
testing it expects these values:

- `repo_url` (e.g., `https://github.com/NREL/EnergyPlus`)
- `runner_name`
- `runner_labels`
- `registration_token`

Generate a short-lived registration token with the GitHub CLI:

```bash
gh api \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  /repos/NREL/EnergyPlus/actions/runners/registration-token \
  --jq .token
```

Registration tokens are short-lived secrets issued by GitHub to enroll a runner. They are used once during runner registration and expire quickly, so generate them just before boot.

Default runner labels:

```
energyplus,linux,x64,ubuntu-24.04
```
