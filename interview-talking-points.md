# Interview Talking Points — AVD Technical Lead

## Opening framing (30 seconds)
"I don't have production AVD ownership on my CV yet, so rather than talk about it
abstractly, I built a working pilot — host pool, FSLogix, autoscaling, session
hosts — in a focused session to show you how I approach picking up a platform
fast, and I can walk you through both what's there and what I'd deliberately
add before this went to 1,000 users."

## If asked "what's your AVD experience"
Bridge from RDS: "I've run RDS infra — broker, gateway, licensing, session
collections. AVD moves the control plane to Microsoft-managed PaaS, so the job
shifts from 'keep the broker alive' to 'get the IaC, autoscale policy, and
FSLogix profile layer right.' That's exactly where I focused this build."

## If asked to walk through the architecture
Walk the README's build sequence: networking → FSLogix storage → host pool/
workspace/app group → session hosts → scaling plan. Emphasize the *order* was
deliberate — storage and identity before compute, because a session host is
useless without a place to put the user's profile.

## If asked about security
- No public IP / inbound RDP on session hosts — access only via the AVD service
- Entra ID join, no AD DS dependency for the pilot
- Storage locked to the pilot subnet via network ACL (with Private Endpoint as
  the stated production upgrade)
- Least-privilege RBAC: users get Desktop Virtualization User scoped to the
  app group (feed visibility) plus Virtual Machine User Login scoped to each
  host (sign-in rights) — never host pool admin or VM Contributor

## If asked about cost
Point to the scaling plan: ramp-up 07:30, peak 09:00, ramp-down 17:30, off-peak
19:00, scaling to minimum overnight. Frame it as the single biggest cost lever
in AVD — the difference between an always-on RDS-style farm and elastic PaaS.

## If asked "how would you scale this to 1,000 users"
Reference the wider design without overclaiming it's built:
- Multiple host pools split by persona/department, not one giant pool
- Golden image via Compute Gallery + Image Builder, versioned rollout
- CI/CD with What-If gates and staged/ring deployment by department wave
- Multi-storage-account FSLogix split if concurrent connection limits are a
  concern at that scale
- Licensing entitlement tracking (M365 E3/E5 vs RDS CALs) as an ongoing
  governance task, not a one-time setup

## If asked "would this sit inside a landing zone in production"
"Yes — the pilot VNet is standalone deliberately, to keep the build scoped to
what I could finish in the time I had. In production I'd peer it as a spoke
into an existing hub, which gets you centralized egress through Azure
Firewall, shared DNS, and Private DNS zones for the Private Endpoints this
pilot doesn't have yet. That's the same landing zone pattern I've already
built in another one of my repos, so it's not new territory for me."

## If asked "why is this two separate deployments"
"The host pool's registration token isn't reliably readable as a template
output in the same deployment that creates the host pool — it's an ARM
timing quirk, not a design preference. Rather than fight that, I split it
into two deployments: create the control plane and infrastructure first,
fetch the token via CLI once it's actually settled, then deploy session
hosts with it as a plain parameter. It's actually closer to how you'd
manage host pool token rotation in production anyway, since tokens expire
and get regenerated independently of the infrastructure around them."

## If pushed on gaps / "you've only had 6 hours with this"
Own it directly, don't oversell: "This pilot proves I can move fast and make
sound design calls under time pressure — I've already wired it into GitHub
Actions with OIDC auth and a What-If/approval gate, so the golden image
pipeline and Private Endpoint hardening are the next things I'd build, and
they're the same patterns I've already used on Bicep/GitHub Actions in other
projects." (Reference other portfolio repos if asked for evidence of that
IaC/CI-CD pattern elsewhere.)

## Close
"I'd want the first 30/60/90 days to be: get visibility into the current
FSLogix and login-storm pain points if any exist, audit the licensing
entitlement mapping, and put the environment under IaC if it isn't already —
because that's where AVD environments usually accumulate the most risk and
the most manual toil."
