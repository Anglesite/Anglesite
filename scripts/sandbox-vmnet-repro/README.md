# SandboxVmnetRepro

Minimal reproduction for [#775](https://github.com/Anglesite/Anglesite/issues/775),
filed with Apple as **FB24610664** (2026-09-01, Developer Technologies & SDKs →
Virtualization Framework): on macOS 27 betas, a **sandboxed** process holding
`com.apple.security.virtualization` can no longer create a
`VMNET_SHARED_MODE` vmnet network. `vmnet_network_create()` fails with
`VMNET_MEM_FAILURE` (1002) — or, in larger apps, sometimes never returns.

This is also the cheap **per-seed retest** for #775: after each macOS 27 seed
update, run `./build-and-run.sh` (~30 seconds). When the `sandboxed` variant
prints `RESULT: PASS`, the OS bug is fixed — close #775 (recording the seed
range) and delete the `com.apple.NetworkSharing` temporary-exception workaround
from `Resources/Anglesite-Debug.entitlements` (#842). Until then, the full-app
A/B documented in #775's comments is only needed when the sample and the app
disagree.

## Regression range

| Build | Result (sandboxed) |
|---|---|
| macOS 27 seed 26A5378j and earlier | works |
| 26A5378n | broken |
| 26A5388g | broken |
| 26A5406e | broken |
| 26A5425a | broken |

## Run it

```sh
./build-and-run.sh
```

Builds one ~60-line C program (`main.c`) that calls
`vmnet_network_configuration_create(VMNET_SHARED_MODE, …)` then
`vmnet_network_create(…)`, and runs it under three ad-hoc signing variants:

| Variant | Entitlements | Expected | Actual on affected seeds |
|---|---|---|---|
| `sandboxed` | app-sandbox + virtualization + network client/server | PASS | **FAIL: `VMNET_MEM_FAILURE` (1002)** |
| `sandboxed-with-exception` | same + `temporary-exception.mach-lookup.global-name` for `com.apple.NetworkSharing` | PASS | PASS |
| `unsandboxed` | virtualization only | PASS | PASS |

Output on 26A5425a (2026-09-01):

```
== sandboxed ==
RESULT: FAIL vmnet_network_create returned NULL (status=1002; VMNET_MEM_FAILURE=1002)
== sandboxed-with-exception ==
RESULT: PASS vmnet_network_create succeeded (status=1000)
== unsandboxed ==
RESULT: PASS vmnet_network_create succeeded (status=1000)
```

## Root cause visible in the unified log

The `VMNET_MEM_FAILURE` is not a memory failure. vmnet's NAT setup
(`_NETRBCreateNetwork`) performs a mach bootstrap look-up of
`com.apple.NetworkSharing`, and the App Sandbox profile on these seeds denies
it; the dead XPC connection is then surfaced as `VMNET_MEM_FAILURE`:

```
repro-sandboxed: (Netrb)        [com.apple.NetworkSharing:framework.netrb] connection … to daemon created
repro-sandboxed: (libxpc.dylib) [com.apple.xpc:connection] activating connection: mach=true … name=com.apple.NetworkSharing
repro-sandboxed: (libxpc.dylib) [com.apple.xpc:connection] failed to do a bootstrap look-up: xpc_error=[159: Unknown error: 159]
repro-sandboxed: (libxpc.dylib) [com.apple.xpc:connection] invalidated after a failed init
repro-sandboxed: (Netrb)        [com.apple.NetworkSharing:framework.netrb] xpc_connection_send_message_with_reply_sync() received Connection invalid
repro-sandboxed: (Netrb)        [com.apple.NetworkSharing:framework.netrb] _NETRBCreateNetwork: __NETRBNetworkCreateGlobalClient
repro-sandboxed: (vmnet)        [com.apple.NetworkSharing:framework.vmnet] vmnet_network_create: _NETRBCreateNetwork
```

The `sandboxed-with-exception` variant passing isolates the failure to exactly
that one denied look-up.

## Impact

Any sandboxed app (including Mac App Store apps) using Virtualization.framework
or the Containerization framework with NAT networking loses all VM networking
on these seeds. In a real app (Anglesite, a sandboxed macOS site builder that
boots per-site Linux containers), every VM boot has been dead since 26A5378n;
on 26A5406e and 26A5425a the failure additionally manifests as
`vmnet_network_create` never returning, hanging the calling thread. The
temporary-exception entitlement is not viable for App Store distribution.

## Notes

- The `sandboxed` variant works as a bare CLI because the binary embeds an
  Info.plist (`-sectcreate __TEXT __info_plist`) giving the sandbox a bundle
  identifier for container creation.
- Ad-hoc signing is sufficient; no provisioning profile or team identity is
  needed to reproduce.
