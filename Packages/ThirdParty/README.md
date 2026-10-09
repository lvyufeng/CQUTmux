# Third-party forks

## `swift-nio-ssh`

A copy of upstream **0.15.0**, carrying one addition: SSH agent forwarding.

### Why a fork rather than a dependency

Upstream models the SSH channel requests that RFC 4254 defines and stops there.
`auth-agent-req@openssh.com` is one of OpenSSH's own extensions, so it is absent
— and it cannot be added from outside the package, because both the request
type (`SSHMessage.ChannelRequestMessage.RequestType`) and the child-channel
request mechanism (`_actuallyTriggerOutboundEvent0`) are internal. Sending the
request means changing the package, and changing a package means vendoring it.

Only four files differ from 0.15.0, and `patches/agent-forwarding.patch` is the
diff. `Sources/` here is otherwise byte-identical to the upstream tag, which is
what makes the patch re-appliable:

```sh
git clone --depth 1 --branch 0.15.0 https://github.com/apple/swift-nio-ssh new-upstream
git -C new-upstream apply ../patches/agent-forwarding.patch
```

### What the patch does

| File | Change |
|---|---|
| `SSHMessages.swift` | `RequestType.authAgent` — encodes to and parses from `auth-agent-req@openssh.com`, and writes the request name (the request carries no further fields) |
| `SSHMessages.swift` | `ChannelType.authAgent` for the inbound direction, `auth-agent@openssh.com` |
| `Child Channels/ChildChannelUserEvents.swift` | `SSHChannelRequestEvent.AgentForwardingRequest`, and the two conversions between it and the message |
| `Child Channels/SSHChildChannel.swift` | dispatch of the new event in `_actuallyTriggerOutboundEvent0` and in the inbound request switch |
| `Child Channels/SSHChannelType.swift` | the public `authAgent` case and the string/type conversions around it |

### The one thing worth knowing when sending it

**Send the request before the `shell` request.** In the other order sshd still
acknowledges it (`server_input_channel_req … reply 0`) and then never creates
the agent socket, so `SSH_AUTH_SOCK` arrives unset and `ssh-add -l` reports
"Could not open a connection to your authentication agent". Nothing in the
protocol refuses, and the failure looks exactly like a server built without
agent forwarding. Verified against OpenSSH 10.3 on macOS: the request after
`shell` produces no `unix_listener_tmp` line in the sshd log, the request
before it produces one.

### Upgrading

Re-apply the patch to the new tag, then run both checks in
`Packages/CQUTTransport/Tests/` — the protocol one needs no server, the
forwarding one needs an sshd with `AllowAgentForwarding yes`. The forwarding
check is indirect on purpose: it opens a session and, inside it, has the host
SSH to itself using the forwarded agent, so it fails if the channel is never
served even though the request was accepted.