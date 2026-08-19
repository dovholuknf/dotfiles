# Using OCI free tier for an OpenZiti overlay

Notes and a working runbook for standing up an OpenZiti 2.0.2 controller and router on Oracle Cloud
Always Free compute. Written 17 Aug 2026.

## Why this is annoying

Always Free gives you two shapes, and only two:

| Shape | Flexible? | Allowance | Reality |
| --- | --- | --- | --- |
| `VM.Standard.A1.Flex` (ARM, Ampere) | yes | your OCPU/GB budget | perpetually out of capacity in Ashburn |
| `VM.Standard.E2.1.Micro` (x86, AMD) | no | 2 instances, 1 OCPU / 1 GB each | usually available |

The flexible x86 shapes (`E3.Flex`, `E4.Flex`, `E5.Flex`) are not Always Free eligible, so there is no
path to "x86 with more RAM" for free.

### A1 capacity

`Out of host capacity` with `status: 500` is Oracle refusing, not a malformed request. Shrinking the shape
does not help — 1 OCPU / 2 GB, the smallest A1 you can ask for, is refused in all three Ashburn ADs just
as readily as 2 OCPU / 8 GB. Oracle serves Always Free tenancies from leftover capacity and deprioritises
them.

Two things that actually change the outcome:

- Upgrade the tenancy to Pay-As-You-Go. Always Free resources stay free, but you get scheduled out of the
  paid capacity pool. Set a budget alert at $5 the same day.
- Use the E2.1.Micro shape instead. Different pool, usually has room.

Region is not a lever: Always Free resources must live in your home region.

### Retry cadence

At roughly three launch calls per minute you start getting `TooManyRequests` / 429. Nine attempts every
ten minutes covers about 33 hours without tripping it. A1 capacity frees on the order of hours, so pace
for a long run rather than a fast one.

### E2.1.Micro is not offered in every AD

In this tenancy the micro shape is offered in `AD-1` only. Set `$AD` to your AD id
(`oci iam availability-domain list`, form `<prefix>:US-ASHBURN-AD-1`). Check before looping:

```bash
oci compute shape list --compartment-id "$COMPARTMENT" --availability-domain "$AD" \
  --output json
```

That collapses the retry surface to one AD. If AD-1 has no capacity there is nowhere else in the region
to look.

### Fixed shapes reject `--shape-config`

`E2.1.Micro` is fixed at 1 OCPU / 1 GB. Passing `--shape-config` fails. Only `*.Flex` shapes accept it.

### Match the image architecture to the shape

A1 is `aarch64`, E2 is `x86_64`. An image OCID that works for one will not launch on the other. Resolve
the image from the shape instead of hardcoding it:

```bash
oci compute image list --compartment-id "$COMPARTMENT" --shape VM.Standard.E2.1.Micro \
  --operating-system "Canonical Ubuntu" --sort-by TIMECREATED --sort-order DESC --output json
```

Verify with the authoritative check, because the list filter is loose:

```bash
oci compute image-shape-compatibility-entry list --image-id "$IMAGE" --output json
```

### `NotAuthorizedOrNotFound` (404) on launch

OCI returns 404 rather than 403 so it does not leak resource existence. On `launch_instance` it means
something in the request did not resolve. Check, in order: the shape name itself, the subnet, the image,
the compartment.

A regional subnet has a null `availability-domain` and works in any AD. An AD-specific subnet only hosts
instances in its own AD, and launching elsewhere 404s on the subnet:

```bash
oci network subnet get --subnet-id "$SUBNET" --output json
```

### PowerShell gotchas

Variable names are case-insensitive, so `foreach ($shape in $shapes)` silently clobbers a `$Shape`
parameter. The symptom is OCI receiving `--shape System.Collections.Hashtable` and returning a 404 that
looks like a permissions problem. Log the parameters you actually send.

`--query` with backslash-escaped quotes gets mangled. Use single-quoted PowerShell strings:

```powershell
--raw-output --query 'data[0]."public-ip"'
```

### Work requests are not confirmation

The console launches asynchronously via work requests. "Accepted" is not "running" — a capacity failure
can surface minutes later. Verify state, or use `--wait-for-state RUNNING` from the CLI.

```bash
oci compute instance list --compartment-id "$COMPARTMENT" --all --output table
oci work-requests work-request list --compartment-id "$COMPARTMENT" --output table
```

## The hosts

Two `VM.Standard.E2.1.Micro` instances, Oracle Linux 9.8, x86_64, created through the console after the
CLI path was fixed. 946 MB RAM with 945 MB of swap already present. `vcpus: 2` — an OCPU is a physical
core, which is two hardware threads on AMD.

Real addresses are redacted. Substitute your own for the placeholders below:

| Placeholder | Meaning |
| --- | --- |
| `CTRL_PRIV` / `CTRL_PUB` | controller private / public IP |
| `ROUTER_PRIV` / `ROUTER_PUB` | router private / public IP |

| Role | ssh alias | Private | Public |
| --- | --- | --- | --- |
| controller | `ocictrl` | CTRL_PRIV | CTRL_PUB |
| router | `ocirouter` | ROUTER_PRIV | ROUTER_PUB |

Both landed in `FAULT-DOMAIN-2`, so they share a fault domain — no placement redundancy between them.

The public IPs are ephemeral. They survive reboots but not a stop/start, and the controller bakes its
advertised address into config and certificate SANs. Reserve the IPs, or use a DNS name from the start —
retrofitting means reissuing certificates.

## Runbook

### Ports

Nothing privileged, so no root binding is needed:

| Port | Host | Source | Purpose |
| --- | --- | --- | --- |
| 1280 | ctrl | 0.0.0.0/0 | controller edge/client API |
| 6262 | ctrl | 10.0.0.0/24 | router control channel |
| 3022 | router | 0.0.0.0/0 | router edge listener |

Both layers must allow the traffic. The VCN security list is only half of it — Oracle Linux images run
`firewalld` locally.

### Install the binary

```bash
curl -sSL -o /tmp/ziti.tar.gz \
  https://github.com/openziti/ziti/releases/download/v2.0.2/ziti-linux-amd64-2.0.2.tar.gz
sudo tar -xzf /tmp/ziti.tar.gz -C /usr/local/bin
sudo chmod +x /usr/local/bin/ziti
ziti version
```

The tarball holds `ziti` at its root — do not pass `--strip-components=1` or you will extract nothing.

### Do not use dnf on a 1 GB instance

`dnf --refresh list available` OOM-killed the controller box hard enough that the kernel died and OCI's
`RESTORE_INSTANCE` recovery action rebooted it. Metadata expansion does not fit in 946 MB alongside
anything else.

Worse, Oracle Linux enables `dnf-makecache.timer`, which does this to you unprompted on its own schedule.
On these instances that is an unattended reboot risk for a running controller. Disable it on every host
before you deploy anything:

```bash
sudo systemctl disable --now dnf-makecache.timer
sudo systemctl mask dnf-makecache.timer
```

Masking does not kill an in-flight run. One `makecache` that had already started left a box unreachable
over SSH for roughly 25 minutes.

So: install from the binary tarball, and configure PKI by hand. No package manager on these hosts.

### Cloud firewall from the CLI

Use a Network Security Group, not the subnet security list. `oci network security-list update
--security-rules` *replaces* the entire rule set, so one omission locks you out of SSH. NSG rules are
additive. Security lists and NSGs are evaluated as a union, so existing SSH access keeps working.

The working script is `C:\temp\oci-ziti-net.ps1`. Two traps it encodes:

- **Pass complex parameters as `file://`,** not inline JSON — PowerShell mangles embedded quotes. On
  Windows the form is `file://C:/path/x.json`. A third slash makes the CLI resolve `/C:/path` and fail
  with "did not exist".
- **`ConvertTo-Json` collapses a one-element array to a bare scalar,** which OCI rejects with
  `CannotParseRequest` (400). Build arrays element by element:

  ```powershell
  $jsonText = if ($Value -is [array]) {
      '[' + (($Value | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }) -join ',') + ']'
  } else {
      $Value | ConvertTo-Json -Depth 10 -Compress
  }
  ```

Attaching an NSG to a running instance is a VNIC update, and it replaces the list — read the current
`nsg-ids` and merge rather than overwrite.

### Host firewall

`firewalld` is running on Oracle Linux, and it is a separate layer from the VCN. Both must allow the
traffic.

```bash
# controller
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --permanent \
  --add-rich-rule='rule family=ipv4 source address=10.0.0.0/24 port port=6262 protocol=tcp accept'
sudo firewall-cmd --reload

# router
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --reload
```

### `sudo` drops /usr/local/bin

`sudo ziti ...` fails with `command not found` because `secure_path` excludes `/usr/local/bin`. Use the
absolute path: `sudo /usr/local/bin/ziti`.

## Controller

### SPIFFE is mandatory in ziti 2.x

The controller refuses to start without a SPIFFE trust domain, and the requirements are specific. Three
successive failures, each a separate rule:

1. `error determining a trust domain from a SPIFFE id in the root identity` — the root CA needs
   `--trust-domain`.
2. `invalid SPIFFE id path: /controller, should have /controller/ prefix` — the id path needs a segment
   *under* `controller`, e.g. `controller/ctrl1`.
3. `spiffe id 'OCI Ziti Controller Client', does not match subject identifier 'ctrl1'` — the certificate
   CN must equal the last segment of the SPIFFE path.

So the CN, the SPIFFE path tail, and the raft server id all have to be the same string.

```bash
Z=/usr/local/bin/ziti
PKI=/opt/ziti/pki

sudo $Z pki create ca --pki-root $PKI --ca-file root-ca \
  --ca-name 'OCI Ziti Root CA' --trust-domain ociziti

sudo $Z pki create intermediate --pki-root $PKI --ca-name root-ca \
  --intermediate-file intermediate-ca --intermediate-name 'OCI Ziti Intermediate CA'

sudo $Z pki create intermediate --pki-root $PKI --ca-name root-ca \
  --intermediate-file signing-ca --intermediate-name 'OCI Ziti Edge Signing CA'

sudo $Z pki create server --pki-root $PKI --ca-name intermediate-ca \
  --server-file ctrl-server --server-name ctrl1 \
  --dns localhost,ocictrl --ip 127.0.0.1,CTRL_PRIV,CTRL_PUB \
  --spiffe-id controller/ctrl1

sudo $Z pki create client --pki-root $PKI --ca-name intermediate-ca \
  --client-file ctrl-client --key-file ctrl-server --client-name ctrl1 \
  --spiffe-id controller/ctrl1
```

Verify before going further — a missing SAN costs a full PKI rebuild:

```bash
sudo openssl x509 -in $PKI/intermediate-ca/certs/ctrl-server.cert -noout -text \
  | grep -A3 'Subject Alternative Name'
```

Expect `URI:spiffe://ociziti/controller/ctrl1` alongside the DNS and IP entries.

### `ZITI_CTRL_EDGE_ALT_ADVERTISED_ADDRESS` silently wins

Setting the ALT address overrode `ZITI_CTRL_EDGE_ADVERTISED_ADDRESS`, so the generated config advertised
the private IP and no external client could enroll. Leave ALT unset unless you actually need a second
address.

### The env file

`/opt/ziti/etc/ziti.env`. Advertise the control channel on the *private* IP so 6262 never needs public
exposure, and the edge API on the public IP so clients can reach it.

```bash
export ZITI_HOME=/opt/ziti
export ZITI_NETWORK_NAME=oci
export ZITI_CTRL_BIND_ADDRESS=0.0.0.0
export ZITI_CTRL_ADVERTISED_ADDRESS=CTRL_PRIV
export ZITI_CTRL_ADVERTISED_PORT=6262
export ZITI_CTRL_EDGE_BIND_ADDRESS=0.0.0.0
export ZITI_CTRL_EDGE_ADVERTISED_ADDRESS=CTRL_PUB
export ZITI_CTRL_EDGE_ADVERTISED_PORT=443
export ZITI_CTRL_DATABASE_FILE=/opt/ziti/db/ctrl.db
export ZITI_PKI_CTRL_CA=/opt/ziti/pki/root-ca/certs/root-ca.cert
export ZITI_PKI_CTRL_CERT=/opt/ziti/pki/intermediate-ca/certs/ctrl-client.chain.pem
export ZITI_PKI_CTRL_SERVER_CERT=/opt/ziti/pki/intermediate-ca/certs/ctrl-server.chain.pem
export ZITI_PKI_CTRL_KEY=/opt/ziti/pki/intermediate-ca/keys/ctrl-server.key
export ZITI_PKI_SIGNER_CERT=/opt/ziti/pki/signing-ca/certs/signing-ca.cert
export ZITI_PKI_SIGNER_KEY=/opt/ziti/pki/signing-ca/keys/signing-ca.key
export ZITI_PKI_EDGE_CA=/opt/ziti/pki/root-ca/certs/root-ca.cert
export ZITI_PKI_EDGE_CERT=/opt/ziti/pki/intermediate-ca/certs/ctrl-client.chain.pem
export ZITI_PKI_EDGE_SERVER_CERT=/opt/ziti/pki/intermediate-ca/certs/ctrl-server.chain.pem
export ZITI_PKI_EDGE_KEY=/opt/ziti/pki/intermediate-ca/keys/ctrl-server.key
```

Generate the config and initialize. `edge init` bootstraps a single-node raft cluster — ziti 2.x always
uses raft, and the server id comes out as `ctrl1`:

```bash
sudo bash -c 'set -a
source /opt/ziti/etc/ziti.env
/usr/local/bin/ziti create config controller -o /opt/ziti/etc/ctrl.yaml'

PW=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
sudo /usr/local/bin/ziti controller edge init /opt/ziti/etc/ctrl.yaml -u admin -p "$PW"
printf 'admin\n%s\n' "$PW" | sudo tee /opt/ziti/etc/admin.creds
```

### Binding 443 without root

`AmbientCapabilities=CAP_NET_BIND_SERVICE` lets the service run as an unprivileged user on a privileged
port. `OOMScoreAdjust=-500` matters on 1 GB — it makes the kernel reach for something else first.

`/etc/systemd/system/ziti-controller.service`:

```ini
[Unit]
Description=OpenZiti Controller
After=network-online.target
Wants=network-online.target

[Service]
User=ziti
Group=ziti
WorkingDirectory=/opt/ziti
ExecStart=/usr/local/bin/ziti controller run /opt/ziti/etc/ctrl.yaml
Restart=always
RestartSec=5
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
```

```bash
sudo chown -R ziti:ziti /opt/ziti
sudo chmod 600 /opt/ziti/etc/admin.creds
sudo systemctl daemon-reload
sudo systemctl enable --now ziti-controller
```

Verify locally and then from off-box, because the two failure modes look nothing alike:

```bash
ss -ltnp | grep -E ':443|:6262'
curl -sk -o /dev/null -w '%{http_code}\n' https://CTRL_PUB:443/edge/client/v1/version
```

## Overlay configuration

ziti 2.x creates no default policies, so the router and service policies must be made explicitly or
nothing routes.

```bash
Z="sudo -u ziti /usr/local/bin/ziti"

$Z edge login 127.0.0.1:443 -u admin -p "$PW" \
  --ca /opt/ziti/pki/root-ca/certs/root-ca.cert -y

$Z edge create edge-router ocirouter --tunneler-enabled \
  --jwt-output-file /opt/ziti/etc/ocirouter.jwt

$Z edge create edge-router-policy all-endpoints --edge-router-roles '#all' --identity-roles '#all'
$Z edge create service-edge-router-policy all-services --edge-router-roles '#all' --service-roles '#all'
```

The router is `--tunneler-enabled`, so it can host services itself. That is what lets it reach port 22 on
both boxes over the VCN without a tunneler installed on either.

```bash
$Z edge create config ocictrl-ssh.host   host.v1 '{"protocol":"tcp","address":"CTRL_PRIV","port":22}'
$Z edge create config ocirouter-ssh.host host.v1 '{"protocol":"tcp","address":"ROUTER_PRIV","port":22}'

$Z edge create config ocictrl-ssh.intercept intercept.v1 \
  '{"protocols":["tcp"],"addresses":["ocictrl.ziti"],"portRanges":[{"low":22,"high":22}]}'
$Z edge create config ocirouter-ssh.intercept intercept.v1 \
  '{"protocols":["tcp"],"addresses":["ocirouter.ziti"],"portRanges":[{"low":22,"high":22}]}'

$Z edge create service ocictrl-ssh   -a ssh --configs ocictrl-ssh.host,ocictrl-ssh.intercept
$Z edge create service ocirouter-ssh -a ssh --configs ocirouter-ssh.host,ocirouter-ssh.intercept

$Z edge create service-policy ssh-bind Bind --service-roles '#ssh' --identity-roles '@ocirouter'
$Z edge create service-policy ssh-dial Dial --service-roles '#ssh' --identity-roles '#ssh-clients'

$Z edge create identity clint -a ssh-clients --jwt-output-file /opt/ziti/etc/clint.jwt
```

The `#ssh` role attribute on both services means one Bind and one Dial policy cover them, and any future
ssh service picks up the same access by tagging alone.

## kdump steals half your RAM

The single biggest trap on these instances. The Oracle Linux kernel command line carries:

```
crashkernel=1G-64G:448M,64G-:512M
```

On a 946 MB instance that reserves **448 MB** for kdump — a crash dump facility you will never use. The
symptom is that `free -m` reports 498 MB instead of 946 MB.

It is inconsistent, which makes it worse. On first boot the reservation can fail (`systemctl is-active
kdump` returns `failed`) and you get the full 946 MB. A later clean reboot succeeds and silently halves
your memory. A controller sized against 946 MB will OOM after a reboot it survived fine before.

Fix it on every host, before deploying anything:

```bash
sudo systemctl disable --now kdump
sudo systemctl mask kdump
sudo grubby --update-kernel=ALL --remove-args=crashkernel
sudo shutdown -r +0
```

Confirm `free -m` reports the full amount afterwards.

Note also that swap is already configured by the image — 945 MB, roughly 1:1 with RAM. Do not bother
adding more. Swap is why a memory-starved box thrashes unreachably for 25 minutes instead of OOM-killing
in 10 seconds; more of it lengthens the outage rather than preventing it.

### Other scheduled jobs worth pruning

`systemctl list-unit-files --type=timer --state=enabled` on a fresh Oracle Linux instance shows three.
`dnf-automatic` is not among them, which is one less thing to worry about.

`mlocate-updatedb.timer` walks the entire filesystem daily to build the `locate` database. Stale `locate`
results are a fair trade on 946 MB:

```bash
sudo systemctl disable --now mlocate-updatedb.timer
```

Leave `ksplice-agent.timer` alone. Live kernel patching is a security feature, and disabling it is a
downgrade in exchange for very little memory.

## Router

### The generated CSR omits IP addresses

`ziti create config router edge` logs a warning that is easy to skim past:

```
DNS provided (ROUTER_PUB) appears to be an IP, ignoring for DNS entry
```

It puts the advertised address in the DNS SAN list, discards it for being an IP, and never adds it to the
IP SAN list. The router enrolls successfully and then refuses to start:

```
one or more advertise addresses are invalid: [invalid listeners.binding.advertise: ROUTER_PUB:443,
error: identity is not valid for provided host: [ROUTER_PUB].
is valid for: [127.0.0.1, ::1, instance-20260817-1432, localhost]]
```

Patch `csr.sans.ip` in `router.yaml` **before** enrolling, since the CSR is what the enrollment cert is
built from:

```yaml
  csr:
    sans:
      dns:
        - localhost
        - instance-20260817-1432
      ip:
        - "127.0.0.1"
        - "::1"
        - "ROUTER_PRIV"
        - "ROUTER_PUB"
```

If you already enrolled, the token is consumed and you need a fresh one from the controller. Delete the
old certs or the stale identity is reused:

```bash
# on the controller
sudo -u ziti /usr/local/bin/ziti edge re-enroll edge-router ocirouter \
  --jwt-output-file /opt/ziti/etc/ocirouter.jwt

# on the router
sudo rm -f /opt/ziti/certs/*
```

### Full router setup

`/opt/ziti/etc/ziti.env`:

```bash
export ZITI_HOME=/opt/ziti
export ZITI_ROUTER_NAME=ocirouter
export ZITI_CTRL_ADVERTISED_ADDRESS=CTRL_PRIV
export ZITI_CTRL_ADVERTISED_PORT=6262
export ZITI_ROUTER_ADVERTISED_ADDRESS=ROUTER_PUB
export ZITI_ROUTER_PORT=443
export ZITI_ROUTER_BIND_ADDRESS=0.0.0.0
```

`--private` suppresses the link listener, which a single-router overlay does not need. `--tunnelerMode
host` lets the router host services itself, which is what allows it to reach port 22 on both boxes over
the VCN with no tunneler installed on either.

```bash
sudo bash -c 'set -a
source /opt/ziti/etc/ziti.env
/usr/local/bin/ziti create config router edge --routerName ocirouter \
  --tunnelerMode host --private -o /opt/ziti/etc/router.yaml'

# patch csr.sans.ip here, then:
sudo bash -c 'set -a
source /opt/ziti/etc/ziti.env
/usr/local/bin/ziti router enroll /opt/ziti/etc/router.yaml --jwt /opt/ziti/etc/ocirouter.jwt'
```

The systemd unit is identical to the controller's apart from the `ExecStart` line:

```ini
ExecStart=/usr/local/bin/ziti router run /opt/ziti/etc/router.yaml
```

```bash
sudo chown -R ziti:ziti /opt/ziti
sudo systemctl daemon-reload
sudo systemctl enable --now ziti-router
```

### Verify

The CLI session expires, and the resulting 401 reads like a credentials problem rather than an expiry.
Just log in again.

```bash
sudo -u ziti /usr/local/bin/ziti edge login 127.0.0.1:443 -u admin -p "$PW" \
  --ca /opt/ziti/pki/root-ca/certs/root-ca.cert -y

sudo -u ziti /usr/local/bin/ziti edge list edge-routers   # ONLINE must be true
sudo -u ziti /usr/local/bin/ziti edge list terminators    # one row per hosted service
```

Terminators are the real check. A router that is online but has no terminators means the Bind policy is
not matching, so nothing can be dialed.

### Test the router's port from outside, separately

An online router with healthy terminators still tells you nothing about whether clients can reach it. The
router's control channel is *outbound* to the controller, so it registers, reports online, and binds its
services perfectly while its own edge listener is firewalled off from the internet. Client enrollment then
fails with nothing wrong on the controller side.

Check every host's public port independently:

```bash
timeout 12 bash -c "cat < /dev/tcp/ROUTER_PUB/443" && echo REACHABLE || echo NOT_REACHABLE
curl -sk -o /dev/null -w '%{http_code}\n' https://CTRL_PUB:443/edge/client/v1/version
```

## Result

```
ID         NAME        ONLINE  ALLOW TRANSIT  COST
hdNepWzGy  ocirouter   true    true           0

SERVICE        ROUTER     BINDING  ADDRESS
ocictrl-ssh    ocirouter  tunnel   1nsgeDhEU9KRyDjWlyWgJo
ocirouter-ssh  ocirouter  tunnel   4KqdBwcB5VMGxyEL1NXRSm
```

Enrol an identity in a tunneler and `ssh opc@ocictrl.ziti` / `ssh opc@ocirouter.ziti` resolve through the
overlay. The login user is `opc`.

Both hosts were rebooted after the build to confirm durability. The controller came back with the full
946 MB, both systemd units started on their own, the router reconnected without intervention, terminators
re-registered, and the ephemeral public IPs survived. A reboot is safe; a stop/start is not, because the
public IPs would change and they are baked into the certificate SANs and advertised addresses.

## Summary of the traps, in the order they bite

1. `dnf` on a 1 GB instance OOMs the box. `dnf-makecache.timer` does it to you unprompted.
2. `crashkernel=...:448M` silently reserves half the RAM, but only on boots where the reservation
   succeeds.
3. `sudo` excludes `/usr/local/bin`.
4. ziti 2.x requires a SPIFFE trust domain, a path under `controller/`, and a CN matching the path tail.
5. `ZITI_CTRL_EDGE_ALT_ADVERTISED_ADDRESS` silently overrides the non-ALT variant.
6. The router CSR generator discards an IP advertised address from both SAN lists.
7. Binding 443 needs `AmbientCapabilities=CAP_NET_BIND_SERVICE`, not root.
8. ziti 2.x ships no default edge-router or service-edge-router policies.
9. A router reports `ONLINE: true` with healthy terminators even when its own edge listener is firewalled
   off from the internet, because its control channel is outbound. Test each public port from outside.

