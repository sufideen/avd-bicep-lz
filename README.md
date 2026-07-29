# avd-bicep-lz — AVD Enterprise Pilot (Proof of Concept)

A working, deployable Bicep proof-of-concept for organizations evaluating a
move from on-premises Remote Desktop Services (RDS) to Azure Virtual Desktop:
1 host pool, 2 pilot session hosts, FSLogix profile storage, a scaling plan,
and network isolation. Scoped deliberately small — a pilot, not a production
rollout — so it's fast to stand up, walk through, and use as a concrete
starting point for scoping an enterprise adoption.

See [docs/architecture-reference.md](docs/architecture-reference.md) for the
architecture diagram, user access model, an RDS↔AVD terminology map, and the
security posture behind this build.

**Status:** Phase 1 and Phase 2 are both deployed and verified working in
`rg-avd-poc` (uksouth) — both session hosts (`avdpoc-avdhost-01`,
`avdpoc-avdhost-02`) are registered and `Available` in the host pool. Getting
there surfaced a real registration bug in the MSI install path; see
[Troubleshooting: session hosts not registering](#troubleshooting-session-hosts-not-registering-in-the-host-pool)
before you hit the same thing.

## What this pilot demonstrates
- An AVD environment can go from concept to **running infrastructure-as-code**
  in hours, not weeks — a realistic timeline for the pilot phase of an
  enterprise adoption plan
- The AVD-specific pieces that don't exist in classic RDS are addressed, not
  glossed over: host pool registration tokens, FSLogix Kerberos auth on Azure
  Files, autoscale plans
- Security-conscious defaults hold even at pilot scale: no public IP/inbound
  RDP on hosts, Entra ID join (no AD DS dependency), storage locked to the
  VNet — the same controls a production rollout needs, not shortcuts that get
  dropped later
- What's *deliberately deferred* for a pilot vs what's required for production
  is made explicit (see "Roadmap to production scale" below) — an honest
  scoping baseline rather than an oversold demo

## Deploy (two phases — the host pool registration token can't be reliably
## read back inside the same deployment that creates it, so session hosts are
## a deliberate second pass)

> Commands below are PowerShell syntax (`` ` `` for line continuation, not `\`).

### Phase 1 — networking, storage, host pool, workspace, scaling plan

```powershell
az login
az account set --subscription "<sub-id>"

az group create --name rg-avd-poc --location uksouth

az deployment group what-if `
  --resource-group rg-avd-poc `
  --template-file main.bicep `
  --parameters params/pilot.bicepparam

az deployment group create `
  --resource-group rg-avd-poc `
  --template-file main.bicep `
  --parameters params/pilot.bicepparam
```

Grab two outputs you'll need for Phase 2:
```powershell
$subnetId = az deployment group show --resource-group rg-avd-poc --name main --query "properties.outputs.subnetId.value" -o tsv
$hostPoolName = az deployment group show --resource-group rg-avd-poc --name main --query "properties.outputs.hostPoolName.value" -o tsv
```

### Phase 2 — fetch the registration token, then deploy session hosts

> **Capture the token from the `update` call itself — don't fetch it with a
> separate `show` afterward.** `az desktopvirtualization hostpool show` does
> not return `registrationInfo` at all (confirmed empirically: empty even
> seconds after a valid token was set), so a two-step update-then-show
> pattern silently gets you an empty string every time — which is exactly
> what caused a real DSC deployment failure on this pilot (`RegistrationToken`
> argument is null or empty). Query `registrationInfo.token` directly off the
> `update` response instead, as below. Also note the CLI's JSON output is
> already flattened — there's no `properties.` prefix on the query path.

```powershell
# Refresh/generate the token AND capture it in the same call (valid 7 days
# per hostpool.bicep default) — see the callout above for why this must be
# one step, not update-then-show.
$token = az desktopvirtualization hostpool update `
  --name $hostPoolName `
  --resource-group rg-avd-poc `
  --registration-info expiration-time="$((Get-Date).AddDays(7).ToString('yyyy-MM-ddTHH:mm:ssZ'))" registration-token-operation=Update `
  --query "registrationInfo.token" -o tsv

$adminPassword = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | % {[char]$_})

az deployment group what-if `
  --resource-group rg-avd-poc `
  --template-file main-sessionhosts.bicep `
  --parameters subnetId=$subnetId hostPoolName=$hostPoolName hostPoolRegistrationToken=$token adminUsername=avdlocaladmin adminPassword=$adminPassword

az deployment group create `
  --resource-group rg-avd-poc `
  --template-file main-sessionhosts.bicep `
  --parameters subnetId=$subnetId hostPoolName=$hostPoolName hostPoolRegistrationToken=$token adminUsername=avdlocaladmin adminPassword=$adminPassword
```

Session hosts take ~10-15 min to register into the host pool after deploy
(extension provisioning + AVD agent install). Check registration status:

```powershell
az rest --method get --url "https://management.azure.com/subscriptions/<sub-id>/resourceGroups/rg-avd-poc/providers/Microsoft.DesktopVirtualization/hostpools/$hostPoolName/sessionHosts?api-version=2023-09-05"
```

> The `az desktopvirtualization sessionhost` subcommand isn't in stock az CLI
> 2.87 (`'sessionhost' is misspelled or not recognized`) — use the REST call
> above, or install the `desktopvirtualization` extension
> (`az extension add --name desktopvirtualization`) if you want the native
> command.

A healthy, registered host looks like `"status": "Available"` with a recent
`lastHeartBeat` and a `sessionHostHealthCheckResults` array of all
`HealthCheckSucceeded`. If the array comes back empty (`"value": []`) after
15+ minutes, see the troubleshooting section below.

## Troubleshooting: session hosts not registering in the host pool

**Symptom:** VMs are provisioned and Entra-joined, `RDAgent` and
`RDAgentBootLoader` services show `Running` on the host, but the host never
appears in `sessionHosts` list (empty `"value": []`) and the host pool /
workspace show 0 session hosts.

This happened on this exact pilot. Root causes, in the order they'll bite you:

1. **The MSI install path's `commandToExecute` was broken** (fixed in this
   repo — see `modules/sessionHosts.bicep`). It appended
   `-RegistrationToken "..."` after `-EncodedCommand <blob>`. PowerShell's
   `-EncodedCommand`/`-Command` do **not** support trailing named parameters
   the way `-File` does — anything after them is parsed by `powershell.exe`'s
   own argument binder, not handed to the decoded script. This fails
   immediately with exit code `-196608`: *"Cannot process command because a
   command is already specified with -Command or -EncodedCommand."* The
   installer script never even starts — `az vm get-instance-view` on the
   extension shows this exact message. **If you're on an older clone of this
   repo, pull the fix or check your own `commandToExecute` for the same
   pattern.**

2. **An empty/null token silently reaches the extension.** This will happen
   if you fetch the token with `hostpool show` instead of capturing it from
   `hostpool update`'s own output — see the callout in the Phase 2 section
   above. The DSC extension's failure mode is unambiguous
   (`ParameterBindingValidationException: ... 'RegistrationToken' ... is null
   or empty`); the MSI path's `msiexec` will just install the agent
   unregistered without erroring loudly, which is far more confusing to spot.

3. **Reinstalling over an already-installed agent is a no-op for
   registration.** If you retry by re-running `msiexec /i AVDAgent.msi
   REGISTRATIONTOKEN=<token>` (or re-running `install-avd-agent.ps1`) against
   a host where the agent is already installed, Windows Installer sees the
   product as already present and skips the custom action that processes
   `REGISTRATIONTOKEN` — services stay `Running`, but
   `HKLM:\SOFTWARE\Microsoft\RDInfraAgent\IsRegistered` stays blank. You have
   to uninstall cleanly first:

   ```powershell
   $agent = Get-WmiObject Win32_Product | Where-Object Name -eq 'Remote Desktop Services Infrastructure Agent'
   $bootLoader = Get-WmiObject Win32_Product | Where-Object Name -eq 'Remote Desktop Agent Boot Loader'
   Stop-Service RDAgentBootLoader, RDAgent -Force -ErrorAction SilentlyContinue
   Start-Process msiexec.exe -Wait -ArgumentList @('/x', $bootLoader.IdentifyingNumber, '/quiet', '/norestart')
   Start-Process msiexec.exe -Wait -ArgumentList @('/x', $agent.IdentifyingNumber, '/quiet', '/norestart')
   # ...then re-run install-avd-agent.ps1 with a freshly captured token
   ```

   `RDAgent` will briefly show `Stopped` right after the fresh install while
   it completes the registration handshake and restarts — that's normal, not
   a new failure. Give it 15-30 seconds and re-check.

**Diagnostic commands used to find all of the above** (all read-only, safe to
run against a live pilot):

```powershell
# Extension-level failure detail (the ARM resource-list "Succeeded" status
# can be stale/cached — this is the authoritative source):
az vm get-instance-view -g rg-avd-poc -n <vm-name> --query "instanceView.extensions[].statuses[].message"

# Deployment-level failure detail:
az deployment operation group list -g rg-avd-poc -n <deployment-name> --query "[?properties.provisioningState=='Failed']"

# Was the host pool's token even valid at the time? (only shows immediately
# after a write — see callout above):
az desktopvirtualization hostpool update ... --query "registrationInfo.token" -o tsv

# On the VM itself, via run-command (registration state ground truth):
az vm run-command invoke -g rg-avd-poc -n <vm-name> --command-id RunPowerShellScript `
  --scripts "Get-ItemProperty HKLM:\SOFTWARE\Microsoft\RDInfraAgent | Select IsRegistered"
```

**Things that turned out NOT to be the problem** (worth ruling out fast, but
weren't it here): outbound network connectivity — this VNet has no NAT
Gateway or public IP, but `Test-NetConnection rdbroker.wvd.microsoft.com -Port
443` from the host succeeded fine, so default outbound access was still
working for this subscription. Don't assume that holds for yours if Microsoft
has enforced the default-outbound-access retirement on it — check before
ruling it out.

## Assign a pilot user

```powershell
az role assignment create `
  --assignee <user-object-id-or-upn> `
  --role "Desktop Virtualization User" `
  --scope <appGroup resourceId output from Phase 1 deployment>
```

User connects via https://client.wvd.microsoft.com/arm/webclient or the
Windows App client, signs in with Entra ID, sees the pilot desktop.

## Get this into a GitHub repo with CI/CD (OIDC, no stored secrets)

**1. Push the code**
```powershell
cd avd-bicep-lz
git init
git add .
git commit -m "Initial AVD pilot POC"
gh repo create avd-bicep-lz --private --source=. --remote=origin
git push -u origin main
```

**2. Create an Entra ID app registration for OIDC federation**

> **The subject claim must match what GitHub actually sends — don't guess it
> from the "standard" `repo:OWNER/REPO:ref:refs/heads/BRANCH` pattern.** Two
> things bit this exact repo:
> 1. The `deploy` job sets `environment: production` (for the manual approval
>    gate). Any job with an `environment:` key gets an OIDC subject of
>    `repo:OWNER/REPO:environment:ENV_NAME` — **not** the ref-based one —
>    regardless of which branch/event triggered it.
> 2. Some GitHub accounts/orgs have OIDC subject-claim customization enabled,
>    which qualifies the owner and repo with their numeric IDs:
>    `repo:owner@OWNER_ID/repo@REPO_ID:...` instead of plain names. You can't
>    tell this is on ahead of time — it only shows up as a mismatch.
>
> If login fails with `AADSTS700213: No matching federated identity record
> found for presented assertion subject '...'`, the error **tells you the
> exact subject GitHub presented** — copy it verbatim into a new federated
> credential rather than reasoning about what it "should" be.

```powershell
az ad app create --display-name "avd-bicep-lz-github-oidc"
# note the appId from the output — this is your AZURE_CLIENT_ID

$APP_ID = "<appId from above>"
az ad sp create --id $APP_ID

# Credential for the deploy job (environment: production) — subject uses
# "environment:production", not "ref:refs/heads/main", because the job
# declares an environment:
az ad app federated-credential create `
  --id $APP_ID `
  --parameters '{\"name\": \"avd-bicep-lz-deploy-env\", \"issuer\": \"https://token.actions.githubusercontent.com\", \"subject\": \"repo:<owner>/<repo>:environment:production\", \"audiences\": [\"api://AzureADTokenExchange\"]}'

# Credential for the what-if job (plain pull_request, no environment):
az ad app federated-credential create `
  --id $APP_ID `
  --parameters '{\"name\": \"avd-bicep-lz-pr\", \"issuer\": \"https://token.actions.githubusercontent.com\", \"subject\": \"repo:<owner>/<repo>:pull_request\", \"audiences\": [\"api://AzureADTokenExchange\"]}'
```
> PowerShell needs the inner double-quotes escaped (`\"`) inside a single-quoted
> JSON string — that's a Windows/PowerShell quirk, not an az CLI thing.
>
> If the first `deploy` run fails on OIDC login, read the `AADSTS700213`
> error's `subject` value and re-create the `avd-bicep-lz-deploy-env`
> credential with that exact string — on this repo it turned out to be
> `repo:sufideen@2108143/avd-bicep-lz@1315582616:environment:production`, not
> the plain-name form above.

**3. Grant the app Contributor on the target resource group**

If `rg-avd-poc` doesn't exist yet, scope to the subscription for the first run
instead (the workflow's `az group create` step needs subscription-level
rights to create it) and narrow to the RG afterward. If it already exists —
as it does once you've run Phase 1 manually per this README — scope directly
to the RG; no need for subscription-wide Contributor:
```powershell
az role assignment create `
  --assignee $APP_ID `
  --role Contributor `
  --scope /subscriptions/<your-subscription-id>/resourceGroups/rg-avd-poc
```

**4. Add repo secrets** (Settings → Secrets and variables → Actions)
| Secret | Value |
|---|---|
| `AZURE_CLIENT_ID` | the appId from step 2 |
| `AZURE_TENANT_ID` | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | `az account show --query id -o tsv` |
| `AVD_ADMIN_PASSWORD` | reserved for Phase 2 automation — see note below |

> **`AVD_ADMIN_PASSWORD` isn't consumed by the workflow yet.** `main.bicep`
> (Phase 1, what the workflow deploys) has no `adminPassword` parameter — only
> `main-sessionhosts.bicep` (Phase 2) does. An earlier version of this
> workflow passed `adminPassword` to the Phase 1 deployment anyway, which
> fails validation outright (`unrecognized template parameter 'adminPassword'.
> Allowed parameters: location, maxSessionLimit, namePrefix,
> subnetAddressPrefix, vnetAddressPrefix`) — confirmed via `az deployment
> group validate` and fixed by dropping the parameter from both jobs. The
> secret is kept here for whenever Phase 2 gets its own CI job (it isn't one
> yet — see the comment at the top of `deploy-avd.yml`).

**5. Set up the approval gate**
Settings → Environments → New environment → `production` → add yourself as a
required reviewer. This means every merge to `main` pauses for your manual
approval before `az deployment group create` runs — the same staged-apply
pattern recommended for any production Azure landing zone rollout.

**How it runs**
- Open a PR touching any `.bicep`/`.bicepparam` file → `security-scan` and
  `what-if` jobs run automatically, both show as checks on the PR
- Merge to `main` → `security-scan` runs again (catches anything that
  changed between PR review and merge), then `deploy` waits for your
  approval in the `production` environment, then applies

## Security scanning

Every PR and push runs a `security-scan` job with two static-analysis tools
against the Bicep templates — no Azure credentials needed, so it runs even on
forked-repo PRs:

- **[Checkov](https://www.checkov.io/)** (`bridgecrewio/checkov-action`) —
  general IaC misconfiguration scanning. **Hard gate**: it fails the build.
- **[PSRule for Azure](https://azure.github.io/PSRule.Rules.Azure/)**
  (`microsoft/ps-rule`) — Azure Well-Architected Framework security-pillar
  rules. Currently **non-blocking** (`continueOnError: true`) — see the
  `TODO` in `deploy-avd.yml`: it couldn't be validated locally in the
  environment this was built in (PSRule's Bicep expansion needs a standalone
  `bicep` binary on PATH; only `az bicep` was available there), so the first
  real CI run needs a human to review its findings before it's safe to flip
  to blocking. Do that before relying on it as a gate.

### Security scanning suppressions

Checkov was run locally against this repo, and every finding was triaged —
fixed if it was a real, cheap fix; suppressed inline (`// checkov:skip=...`
comments in the resource body, with a one-line reason) if it was a false
positive or a documented pilot-scope tradeoff. Current suppressions:

| Check | Resource | Why suppressed |
|---|---|---|
| `CKV_AZURE_43` (storage naming rules) | `fslogixStorage.bicep` storage account | False positive — the name is built from `take()`/`uniqueString()`, which Checkov's static analysis can't evaluate; the actual deployed name (`avdpocfsld5ntrmzyh2uvu`) is a valid 22-char lowercase-alphanumeric name |
| `CKV_AZURE_206` (storage replication) | same | LRS is a deliberate pilot/cost tradeoff — see "Known limitations" |
| `CKV_AZURE_50` (VM extensions present) | `sessionHosts.bicep` VMs | Required, not incidental — `AADLoginForWindows` and the AVD agent installer *are* how a host joins Entra and registers; there's no extension-free path for AVD |
| `CKV_AZURE_178`, `CKV_AZURE_1` (Linux SSH-key auth) | same | Not applicable — these are Windows VMs (marketplace `win11-23h2-avd` image); the checks are Linux-specific and misfire on any Windows VM resource |
| `CKV_AZURE_97` (Encryption at Host) | same | Deferred — needs the `Microsoft.Compute/EncryptionAtHost` feature registered on the subscription first (a subscription-wide change); owner decision to defer rather than register it for a same-day pilot |
| `CKV_AZURE_151` (Azure Disk Encryption) | same | Deferred to production — see "Roadmap to production scale" below. Needs a Key Vault + the ADE extension, a bigger lift than a pilot warrants; disks already get platform-managed encryption at rest by default regardless |

**Note for anyone editing these `checkov:skip` comments:** keep each one to
a single line. Checkov's Bicep grammar can't reliably parse a multi-line
wrapped comment following a skip directive — it silently fails to parse the
*entire resource* (reports it as a parsing error, with zero checks run
against it) if a continuation line trips its parser. Confirmed while adding
these; a wrapped line starting with `(` was enough to break it. If you need
more explanation than fits on one line, put it here in the README instead
and reference it from the code comment.

| Time | Task |
|---|---|
| 0:00–0:45 | Resource group, networking module (VNet/subnet/NSG), deploy + verify |
| 0:45–1:45 | FSLogix storage module — storage account, AADKERB auth, share, deploy + verify |
| 1:45–2:30 | Host pool + workspace + app group modules, deploy + verify registration token generation |
| 2:30–3:45 | Session hosts module (2 VMs, Entra join, AVD DSC registration), deploy + wait for registration |
| 3:45–4:15 | Scaling plan module, attach to host pool |
| 4:15–4:45 | Assign pilot user, test end-to-end login via web client |
| 4:45–5:30 | RBAC/least-privilege pass (Desktop Virtualization User role scoped to app group only), NSG review |
| 5:30–6:00 | README and supporting docs; capture screenshots of the working session |

Indicative build effort only — a useful planning input when scoping a client's
own pilot, not a fixed quote.

## Roadmap to production scale

What's out of scope for a pilot, and what a production engagement would need
to add:
- **Golden image pipeline** (Azure Compute Gallery + Image Builder) — pilot uses
  marketplace image directly to save build time; production needs a versioned,
  patched, FSLogix-preinstalled image
- **Private Endpoint on the AVD control plane feed** — pilot relies on default
  public feed; production should use Private Link end-to-end
- ~~CI/CD with staged rings~~ — **done for Phase 1**:
  `.github/workflows/deploy-avd.yml` with OIDC auth, What-If on PR, manual
  approval gate before apply on merge to `main`. Phase 2 (session hosts) is
  still a manual step — it needs a registration token fetched live via CLI
  immediately before deploy, which doesn't fit a plain `deployment create`
  job without extra scripting to fetch-then-deploy in one step
- **Conditional Access policy** — documented as a requirement, not yet codified
  (portal config, then codify via Graph/ARM once validated)
- **MSIX app attach** — not needed for a 2-user desktop pilot, becomes relevant
  once app delivery scales beyond what's baked into the image
- **Multi-host-pool segmentation by persona/department** — single pool is fine
  for a pilot; at production scale (1,000+ users) this splits by persona or
  department instead of one shared pool
- **Landing zone integration** — this pilot's VNet is standalone by design to
  keep the build scoped; production places it as a spoke peered to an
  existing hub landing zone, consuming shared egress/firewall, centralized
  DNS, and Private DNS zones for the FSLogix Private Endpoint

## Known limitations of this POC
- Local admin credentials passed via parameter — for anything beyond a same-day
  pilot this should come from Key Vault
- Registration token has a 7-day expiry — regenerate for longer-running pilots
- No Private Endpoint on storage yet — network ACL restricts to the pilot subnet
  only, which is an acceptable interim control, not the production posture
- **Redeploying `main.bicep` silently rotates the host pool's registration
  token.** `hostpool.bicep` always sends `registrationTokenOperation: 'Update'`
  with a fresh `dateTimeAdd(utcNow(), 'P7D')` expiry — there's no way in Bicep
  to make this conditional/idempotent. This doesn't de-register hosts that are
  already registered (confirmed: rotating the token live left both pilot hosts
  `Available`), but it does mean any token you fetched earlier for a Phase 2
  redeploy is invalid the moment someone reruns Phase 1 — always fetch fresh,
  immediately before the Phase 2 deploy.
- `az desktopvirtualization sessionhost list` isn't available in stock az CLI
  (needs the `desktopvirtualization` extension); this repo's instructions use
  a plain `az rest` call instead so there's no extension dependency.
