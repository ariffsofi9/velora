# createWorkspace production prerequisites

2026-11-06 (Asia/Kuala_Lumpur). LOCAL PLAN ONLY; stop at first approval checkpoint.
Decision: CONDITIONALLY READY locally; cloud prerequisites remain unverified.

## Local evidence and AUP

Source reviewed: firebase.json, functions/package.json, functions/src/index.js,
functions/src/workspace-creation.js and both deployment-readiness/availability reports.
No .firebaserc exists. Source=functions, codebase=workspace, v2 onCall=createWorkspace,
region=asia-southeast1, runtime declaration=Node 22. Use explicit velora-73222.
Prior approved Functions listing succeeded and found no functions; do not repeat it.
Prior backend 367+19 and Flutter 118 results are not rerun or cloud prerequisite proof.

No exact Acceptable Use Policy/AUP text was found in the five existing local logs
checked: firebase-debug.log, functions/firebase-debug.log, firestore-debug.log,
functions/firestore-debug.log and android/build-d2-manifest.log. Reports only repeat
that a warning was reported. Raw log contents were not emitted. The warning's source,
context and severity are NOT VERIFIED; neither harmlessness nor blocking restriction
is established. Obtain sanitized exact text or separately approve specific inspection.
The unrelated CLI firebase.json flutter-property warning is not an AUP diagnosis.

## Proposed command 1: project identity only

DO NOT EXECUTE until this individual command is explicitly approved.
Working directory: C:\Users\23000\velora.

```powershell
@'
const root = 'C:/Users/23000/AppData/Roaming/npm/node_modules/firebase-tools/lib/';
(async () => {
  const project = 'velora-73222';
  require(root + 'logger').logger.debug = () => {};
  const account = require(root + 'auth').getGlobalDefaultAccount();
  const sha = value => require('node:crypto').createHash('sha256').update(value).digest('hex');
  if (!account || sha(account.user.email.trim().toLowerCase()) !==
      '92bb9acf57b8a718ff7829e761c018feec99801d96d9b5737110e45a607ac2f4') {
    throw Error('Existing account mismatch; stop.');
  }
  await require(root + 'requireAuth').requireAuth({
    project, nonInteractive: true, user: account.user, tokens: account.tokens,
  }, true);
  const api = new (require(root + 'apiv2').Client)({
    urlPrefix: 'https://cloudresourcemanager.googleapis.com', apiVersion: 'v1',
  });
  const response = await api.get('/projects/' + project, {
    retries: 0, skipLog: {resBody: true},
  });
  const body = response.body;
  if (body.projectId !== project) throw Error('Project mismatch; stop.');
  console.log(JSON.stringify({projectId: body.projectId, projectNumber: body.projectNumber,
    lifecycleState: body.lifecycleState, httpStatus: response.status}));
})().catch(() => {
  console.error('Read-only identity inspection blocked; no remediation attempted.');
  process.exitCode = 1;
});
'@ | node
```

Operation: GET https://cloudresourcemanager.googleapis.com/v1/projects/velora-73222.
Purpose/output: exact projectId, projectNumber, lifecycleState and HTTP status only.
Permission: resourcemanager.projects.get. Existing CLI account fingerprint checked;
no login/account switch or Firebase Auth user operations. Expired tokens may refresh
automatically and update saved local CLI auth/cache state. No resource mutation.
Expected: HTTP 200, correct project and ACTIVE supports identity. Wrong target STOP;
403, unavailable auth/API/transport is BLOCKED, never automatic permission/API repair.
No retries, Firestore, invocation, deployment, secrets or broad enumeration.

This command has NOT RUN. Exact exit code/output unavailable. Its syntax is checked
locally without execution. Approval does not authorize any later command.

## Later checks: each requires its own shown command and individual approval

| Metadata | Minimum proposed read | Permission/interpretation |
| --- | --- | --- |
| Billing | GET cloudbilling.googleapis.com/v1/projects/velora-73222/billingInfo | Existing billing.resourceAssociations.list as applicable; report billingEnabled, redact account identity. Linkage alone does not prove all billing/Blaze/quota prerequisites |
| Functions API | GET serviceusage.googleapis.com/v1/projects/velora-73222/services/cloudfunctions.googleapis.com | serviceusage.services.get; prior successful listing evidence exists, not refreshed here |
| Build API | Same exact service GET for cloudbuild.googleapis.com | ENABLED PASS, DISABLED FAIL, inaccessible BLOCKED; no enable |
| Artifact API | Same service GET for artifactregistry.googleapis.com | No repository enumeration/creation |
| Run API | Same service GET for run.googleapis.com | No service enumeration |
| IAM/service identities | Scope exact deployer/runtime/build identities first | No full IAM policy dump, broad account lists, keys or grants; required permissions and identities NOT VERIFIED |
| Runtime/region | Verify supported read-only runtime/location metadata before preparing command | Node 22 engines locally compatible; current provider support/Gen 2/asia-southeast1 NOT VERIFIED |

Table is a plan, NOT a batch authorization. Verify each exact project's metadata
before proceeding; stop on mismatch, denied access or unexpected mutation prerequisite.
Eventarc triggers are not required by this HTTPS callable itself; no unrelated event
configuration/API activation should be introduced. No new Functions list is needed.

## Deployment impact and risk review

Future Gen 2 deployment can upload source, execute Cloud Build, store Artifact Registry
images and create a Cloud Run-backed service/revision. Build/runtime/service-agent
permissions and artifact retention/cost/quota effects need review. No prices or current
billing eligibility are claimed. Deployer function/build/source permissions and
iam.serviceAccounts.actAs on chosen identities need verification; runtime Firestore
entity/transaction access is independent of deployer CLI permissions. Do not grant
broad roles or assume default identities have appropriate rights.

Provider orchestration can request API activation, IAM/service-agent changes or new
repositories/policies. Inspection never authorizes those. If a command requests any
such change, decline and STOP. No unexpected mutation may be accepted automatically.

Admin SDK bypasses Rules. createWorkspace independently verifies Auth/email/membership;
transport invoker IAM must be reviewed without blindly granting public access.
No explicit App Check enforcement/maxInstances/dedicated serviceAccount setting exists;
abuse, costs and default identity risks require an operator decision. Unexpected errors
log raw objects server-side; fixed client messages do not prove server-log redaction.
Authenticated Rules B transaction/query/listener behavior is not runtime verified.
Uncertain account outcomes require separately approved reconciliation before reuse.
No profile/username correction or existing user/document overwrite is permitted here.

For first deployment no known prior working function revision exists. Prefer reviewed
repair-forward; any function removal, traffic/IAM restriction or artifact action needs
separate approval. Never restore permissive Rules or automatically delete workspace
records as rollback. Publication does not approve a data-writing callable test.

## Current verification and stop point

Local codebase/export/region/runtime declarations: PASS source review.
Explicit target: PASS plan, velora-73222/workspace:createWorkspace.
Project identity/billing/Build/Artifact/Run/service identities/IAM/runtime availability:
NOT RUN/NOT VERIFIED. Cloud Functions API and function absence: prior approved listing
only. AUP: exact text/context NOT VERIFIED. Production inspection/deployment/testing:
NOT RUN. No confirmed new prerequisite failure is inferred from missing evidence.
Prior tests are not rerun during this planning step. Final syntax/document/git checks
are reported in the task response.

Readiness: CONDITIONALLY READY for per-command inspection, not READY to deploy.
STOP at the first project-identity approval checkpoint. Do not execute subsequent
commands even if identity passes; obtain independent approvals in later turns.

Database report: schema/Rules/documents/Auth users UNCHANGED; production metadata
requests NONE during preparation; Firestore reads/writes NONE; deployments NONE.
Only this local document added. No source/config/dependency changes, emulator/staging,
IAM/API/billing modifications, credential generation, Git add/commit/push. Existing
uncommitted work preserved. No automatic progression to deployment.

## Command 1 approved execution result (2026-11-06, Asia/Kuala_Lumpur)

Fresh individual approval received: "Approve Command 1 project identity GET only".
Executed exactly the proposed command above once. Existing account fingerprint
matched. Resource GET retries disabled. Exit code 0. Sanitized returned metadata:

```json
{"projectId":"velora-73222","projectNumber":"384873169563","lifecycleState":"ACTIVE","httpStatus":200}
```

PASS: exact project identity and ACTIVE lifecycle verified. This result supersedes
Command 1's pre-execution NOT RUN status above only. It does not verify billing,
Firebase plan eligibility, APIs, deployment/runtime identities/IAM, Node 22 availability,
region support, AUP warning, function health or build readiness. No other metadata
command, document request, Auth user operation, invocation or deployment was executed.
Existing CLI authentication may refresh its token/cache as described in approval;
no login/account switch or cloud resource mutation was performed.

STOP after Command 1. A billingInfo GET would require a NEW individual approval with
exact command and limited/redacted output; it was not run or approved by this result.
Schema, Rules, documents, Auth users and cloud resources unchanged. Firestore reads/
writes NONE; deployments NONE. Only this document updated. GitHub not committed/not
pushed; pre-existing changes preserved. Final git diff check is in the task report.

## Command 2 approved billing inspection (2026-11-06, Asia/Kuala_Lumpur)

Explicit individual approval: "Approve Command 2 billing GET only". The full exact
command was displayed before approval and executed once. Existing account fingerprint
matched; GET target was cloudbilling.googleapis.com/v1/projects/velora-73222/billingInfo,
resource retries disabled. ProjectId and billingInfo resource name matched exactly.
Process exit 0, HTTP 200. Sanitized result:

```json
{"projectId":"velora-73222","billingEnabled":false,"billingLinked":false,"httpStatus":200}
```

Inspection PASS; BILLING PREREQUISITE FAIL. The response indicates no linked billing
account and billing not enabled for this project at inspection time. This is NOT a
permission/transport failure and is not an instruction to attach billing or upgrade.
It is a confirmed unmet prerequisite for the intended paid-services Gen 2 deployment;
do not attempt deployment or disguise the blocker as a Flutter defect. No billing
account identity, raw body, credentials or payment information was printed/persisted.

No remediation, further metadata command, billing/API/IAM change, Firestore/Auth
operation, function invocation or deployment occurred. Existing CLI authentication
may refresh local token/cache state as disclosed. No login/account switch was made.

Readiness: BLOCKED on project billing eligibility/linkage before any deployment.
The other API/IAM/runtime/AUP checks remain NOT VERIFIED or prior evidence only.
Any billing linkage/plan change requires separate explicit authorization and cost
review; inspection approval does NOT permit it. Stop after Command 2.

Database report: schema/Rules/documents/Auth users unchanged; production Firestore
reads/writes NONE; deployments NONE. Only this prerequisites document updated with
sanitized evidence. No Git add/commit/push; pre-existing uncommitted work preserved.
