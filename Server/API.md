# AGY iPhone gateway API

Base URL: `https://agy.yectech.uk`. All routes require `Authorization: Bearer <gateway-key>`. This is the separately delivered App gateway key, not a Google OAuth or Cloudflare token. No credentials appear in this repository.

The current zone retains Browser Integrity Check. The native App sends a mobile User-Agent identifying its iOS version and `AGY-iPhone`. External API integrations should use a compatible mobile client User-Agent too; Python's default User-Agent is rejected by the existing zone before reaching the gateway.

## Read account limits

`GET /v1/limits` returns actual structured account quota from the authenticated CLI command `agy -p /usage --output-format json`. This is a read-only CLI command, not a model prompt. Responses are cached for 30 seconds; `GET /v1/limits?refresh=1` forces a refresh.

Response shape (illustrative values):

```json
{
  "fetchedAt": 1793080000.0,
  "source": "agy /usage",
  "description": "Provider explanation of quota grouping",
  "groups": [
    {
      "name": "Gemini 4 Argon",
      "buckets": [
        {
          "id": "gemini-argon-wtu-weekly",
          "name": "Gemini 4 Argon Weekly Limit",
          "window": "weekly",
          "remaining_fraction": 0.75,
          "reset_time": "2026-11-03T06:03:08Z"
        }
      ]
    }
  ]
}
```

All groups/buckets come from AGY. `remaining_fraction` is the fraction remaining, not used: `0.75` means 75% remains. `reset_time` is the provider's UTC reset timestamp. Do not infer absolute token/request allowances from a percentage. Missing fields mean the provider did not return that value. Accounts may return shared Gemini, shared Claude/GPT and separate Gemini 4 Argon buckets depending on plan. A failed query returns 502 rather than fabricated remaining quota.

## Models and model changes

- `GET /v1/models` preserves the legacy `models` list and adds `families`: one model name with its advertised `efforts`, `defaultEffort` and canonical `variants`. `?refresh=1` bypasses the 5-minute cache. No effort is invented for a model that did not advertise one.
- `POST /v1/sessions` and `PATCH /v1/sessions/{id}` accept `{"baseModel":"gemini-4-argon","effort":"high","mode":"accept-edits","approvalMode":"review"}`. Model and thinking depth are independent. Only valid pairs resolve to a canonical variant; the subprocess receives separate `--model` and `--effort` flags. Model-only selection uses the catalog default. History and conversation ID remain intact, and a running task returns 409.
- The legacy canonical `{"model":"gemini-4-argon-high"}` remains accepted. Old sessions retain their legacy permission behavior until explicitly reconfigured; they are not silently relabeled Restriction or upgraded to Turbo.
- `PATCH /v1/sessions/{id}` with `{"name":"New name"}` renames the gateway history entry.

## Native approval and account capabilities (1.2.0)

`GET /v1/status` returns an opaque `accountProfile` and `capabilities` (`separateEffort`, `nativeApprovals`, `artifacts`). A new client refuses to send with the new presets if its server lacks the matching backend. A changed account profile invalidates client conversation/draft/pending-send/quota caches.

Permission presets are separate from `mode` (`plan` or `accept-edits`):

- `review` / Restriction: the official PreToolUse hook sends a proposed tool call to a private Unix socket. The session's `approvals` list contains `id`, `sessionID`, tool name, complete parameters, creation and expiry times. `POST /v1/sessions/{sid}/approvals/{rid}` with `{"decision":"allow"}` or `{"decision":"deny"}` resolves exactly one call. Wrong session, duplicate and expired decisions return 409. Unknown capability, socket failure, timeout, process stop or restart never grants permission. The CLI receives `auto_approve` only after the explicit one-time Allow, still subject to explicit user rules.
- `turbo`: session-only `toolPermission=always-proceed`; the bridge adds no native approval wait. Explicit CLI ask/deny rules still apply. Both presets use session-only `artifactReviewPolicy=always-proceed` so no inaccessible desktop artifact prompt remains; Restriction reviews tool arguments before the corresponding action. This is not a desktop artifact-review UI clone.

The Unix socket has mode 0600 in a private temporary directory and uses an unpredictable, per-run capability. That capability is never returned by public APIs. Approval timeout is 540 seconds, shorter than the hook's 600-second timeout. No approvals are stored as persistent allow grants. The profile's hook configuration is isolated from shared AGY and PI homes. Full account/login setup: [ACCOUNT_LOGIN.md](../ACCOUNT_LOGIN.md).

## Generated files and image previews

`GET /v1/sessions/{sid}/files?path=<URL-encoded-path>` streams a regular file up to 25 MiB with no-store, nosniff and attachment headers. A path must be under that session's workspace or its own isolated CLI brain directory. Outside paths, traversal escapes and symlink components are rejected. Upload metadata now also returns the generated `path` so the client can preview an uploaded image or download its original through this authenticated route.

The iPhone does not attach the gateway token to external downloads; external redirects are HTTPS-only and have authorization/cookie headers removed. SVG previews are local rendering with external resources/scripts rejected. Server filesystem paths are never opened as device-local files.

## Upload and send attachments

1. Create a session with `POST /v1/sessions`, or use an existing session ID.
2. `POST /v1/sessions/{id}/attachments?name=<URL-encoded-filename>` with the raw file bytes, its MIME `Content-Type`, and `Content-Length`. Do not wrap the body in JSON or multipart. Response: `{"id":"uuid","name":"photo.jpg","mime":"image/jpeg","size":12345}`.
3. `POST /v1/sessions/{id}/messages` with `{"text":"Read these files","requestID":"client-generated-uuid","attachments":["attachment-id"]}`. Empty text with one or more attachments is allowed. The upload IDs must belong to this session. Maximum 8 files, 25 MiB each and 50 MiB total per message.

The gateway stores files under the session workspace's `.agy-uploads/{session}/` directory with generated names. It checks real workspace boundaries and opens directories/files without following symlinks. A name cannot overwrite source files or inject a workspace instruction file. Actual paths are attached to the CLI turn so AGY reads the files with its existing image/file tools. The iPhone photo picker normalizes orientation and downsamples to 2048 pixels; arbitrary document bytes are preserved.

Reusing a message request ID with the same text and upload IDs returns the originally admitted message without re-executing it. A different payload under that ID returns 409. Uploads by themselves never invoke a model. Gateway history deletion preserves AGY's own original conversation and its referenced files.

Existing session GET, SSE events, stop and delete endpoints preserve their response shape with optional new fields. Arbitrary TUI interactions and the official Remote Control history are not part of this API. Directory browsing and mentions are provided by the 1.3.0 endpoints below.


## Phone file browser and file/folder mentions (1.3.0)

Status capabilities `fileBrowser` and `directoryMentions` advertise the matching backend. The native app reports that deployment is required if these capabilities are absent.

- `GET /v1/workspace?cwd=<allowed-workspace>&path=<relative-directory>` browses before creating a session. `cwd` must resolve inside a configured root. The phone uses this for selecting a project folder, without typing a server path.
- `GET /v1/sessions/{sid}/entries?scope=workspace|uploads|artifacts&path=<relative-directory>` lists the session workspace, its uploads, or its isolated AGY brain artifacts. Missing uploads/artifacts return an empty list. Artifacts do not include another conversation's brain directory. Shared project files remain shared within a workspace.
- Responses: `{"root":"/server/project","path":"资料","entries":[{"name":"合同.pdf","path":"/server/project/资料/合同.pdf","directory":false,"size":12,"modified":1793000000.0}]}`. The phone displays only relative labels. Folders sort first; the phone can filter names, show hidden entries, sort by modification date, and navigate back to root.
- Directory traversal, links and special filesystem entries are refused. Credential/configuration directories are excluded. Listing is limited to 5000 entries per directory. Downloads retain the 25 MiB per-file limit. Directory download/ZIP creation, delete/rename and moving files are not exposed.
- Upload from Files or Photos uses the existing binary attachment endpoint immediately, without sending a task. Upload names in the browser retain their original names; generated storage names prevent overwrites. A batch selects up to 8 files; the 50 MiB total applies when sending uploaded attachments in a single chat message.
- `POST /v1/sessions/{sid}/messages` additionally accepts `"references":["/server/project/src","/server/project/资料/合同.pdf"]`. Up to 8 distinct file/folder references are accepted; references alone can form a message. The server validates every path with no-follow directory traversal before admitting the request. Unavailable/forbidden paths fail without adding a user message. Request deduplication covers the reference list as well as text and upload IDs.
- A folder is one reference with MIME `inode/directory`, not a ZIP or recursively pasted contents. The headless prompt passes the full selected paths and their file/directory types as explicit context records. Names and paths are JSON-escaped, preserving spaces, Unicode and literal control characters without creating fake context records. Permission checks still apply when AGY reads these paths.

The phone opens the picker on a trailing `@`, or via “@ 引用工作文件”. Rows offer navigation/preview and a separate `@` action, including whole-folder references and a current-folder action. Draft reference chips show relative paths, survive reopening a session, and are included in the keychain-protected pending-send payload. An account change clears them with other account caches.

Reference semantics follow [Google's official mentions documentation](https://antigravity.google/docs/at-mentions): paths identify context, and contents are read when needed. This headless integration does not implement the TUI's interactive suggestion protocol or a private binary mention format.
