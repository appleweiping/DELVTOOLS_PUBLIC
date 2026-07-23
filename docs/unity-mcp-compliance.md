# Unity MCP integration and compliance gate

This repository tracks the source provenance and bootstrap wiring for
[`IvanMurzak/Unity-MCP`](https://github.com/IvanMurzak/Unity-MCP), but checking
out the source is intentionally separate from allowing an agent to operate the
Unity Editor.

## Locked dependency

- Upstream release: `0.86.1`
- Commit: `e59211c610a1481ef2a8a1e6e7fe8010e7e5a509`
- License: Apache-2.0
- Intended checkout: `third_party/Unity-MCP`
- Intended runtime: Unity 6.3 LTS on Windows x64

The submodule commit is the reproducible source lock. npm packages, Unity
Editors, project `Library` directories, credentials, and generated MCP server
binaries are local runtime dependencies and are never committed here.

## Mandatory authorization gate

Unity's Terms of Service were updated on June 30, 2026. Sections 17.2(ff) and
17.2(gg), together with the definition of **Authorized Agentic Access**, place
specific conditions on AI agents, MCP clients/servers, and third-party Unity
integrations:

- <https://unity.com/legal/terms-of-service>
- <https://unity.com/pages/license-compliance>

The dependency may be downloaded, inspected, tested without invoking Unity,
and tracked as source before authorization is established. It must not be used
to invoke, query, instruct, or otherwise automate the Unity Editor until one of
the following is recorded and independently verifiable:

1. an official Unity allowlist or documentation entry covering the exact
   package, client/server, and selected transport;
2. an applicable Unity Asset Store or Verified Solutions listing whose terms
   explicitly authorize this integration;
3. applicable Additional Terms or Commercial Terms; or
4. written approval from Unity covering the intended use.

Authentication to `ai-game.dev` or a successful local stdio connection is not
by itself proof of Unity authorization.

Unity staff also stated publicly on July 1, 2026 that third-party MCPs remain
allowed through authorized channels, including documented Unity Core Standards
or documented not-banned status:
<https://discussions.unity.com/t/new-terms-of-service-is-unity-restricting-local-ai-tools-and-ai-training/1724661/6>.
That general clarification does not identify this pinned package, client/model,
gateway, or transport, so it does not replace an exact allowlist entry or the
account-specific written approval described above.

Public provenance inquiry:
<https://github.com/IvanMurzak/Unity-MCP/issues/930>

## Unity support request template

Submit this request from the Unity account and organization that will own the
project:

> We plan to use Unity 6.3 LTS for a commercial Windows PC game and are
> evaluating IvanMurzak/Unity-MCP release 0.86.1. Please confirm in writing
> whether `com.ivanmurzak.unity.mcp`, `unity-mcp-cli`, the `ai-game.dev`
> pinned/cloud endpoint, and local self-hosted/stdio operation qualify as
> Authorized Agentic Access under the Unity Terms of Service updated June 30,
> 2026. If only specific transports or versions are authorized, please identify
> them and link the applicable allowlist, documentation, Additional Terms, or
> Commercial Terms.

Do not commit the support conversation if it contains account or organization
information. Record only the case identifier, decision date, authorized scope,
and a public evidence link or a locally stored redacted approval record.

## Enablement checklist

Before enabling the MCP in an agent configuration:

- confirm the Unity subscription tier is still eligible;
- confirm the authorization covers the exact pinned dependency and transport;
- verify the upstream release/commit and npm package integrity;
- keep OAuth/device credentials in the machine credential store only;
- generate agent configuration without embedded tokens;
- run the MCP smoke suite in a disposable Unity project;
- re-check the Terms and authorization status before each dependency upgrade.

If the gate cannot be satisfied, keep the source checkout for inspection and
use a Unity-operated or Unity-designated authorized workflow instead.
