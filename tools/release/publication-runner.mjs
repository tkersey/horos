import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {appendFileSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, mkdtempSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {GitHubReader, githubCommand} from './github.mjs';
import {HorosProposalClient} from './proposal-github.mjs';
import {currentHorosSource, observation, appActor, horosBoundaryOperations} from './release-observation.mjs';
import {manifestOperations, sourceManifest} from './native-manifest.mjs';
import {computeHorosPublicationBoundary} from './publication-boundary.mjs';
import {admitHorosQualification} from './qualification.mjs';
import {workflowPages} from './workflow-artifact.mjs';
import {sealHorosPublication} from './seal.mjs';
import {readRecord} from './record.mjs';
import {readRegular} from './review-owner.mjs';
import {encodeRecord, sha256} from './encoding.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {admitPublishedRelease, attestationArguments} from './release-admission.mjs';
import {publishHoros} from './publish.mjs';

export async function publicationEnabled(client) {
  const mode = await observation(client, '/actions/variables/REPOSITORY_AUTOMATION', true);
  const publish = await observation(client, '/actions/variables/RELEASE_PUBLICATION_ENABLED', true);
  if (mode) assert.equal(mode.name, 'REPOSITORY_AUTOMATION');
  if (publish) assert.equal(publish.name, 'RELEASE_PUBLICATION_ENABLED');
  assert.ok(['off', 'propose', 'promote'].includes(mode?.value ?? 'off'));
  assert.ok(['true', 'false'].includes(publish?.value ?? 'false'));
  return mode?.value !== undefined && mode.value !== 'off' && publish?.value === 'true';
}

export function publicationServices({controlDirectory, nativePath, identity, command = githubCommand}) {
  if (!identity) return {enabled: async () => false,
    disabledReason: 'Repository-local App credential is missing; publication remains disabled.'};
  const root = realpathSync(controlDirectory), client = new HorosProposalClient();
  const git = args => execFileSync('git', ['-c', 'core.hooksPath=/dev/null', ...args], {cwd: root, encoding: 'utf8'}).trim();
  const controlCommit = git(['rev-parse', 'HEAD']);
  assert.match(controlCommit, /^[0-9a-f]{40}$/);
  assert.equal(git(['status', '--porcelain', '--untracked-files=all']), '', 'trusted publication checkout must be clean');
  if (process.env.GITHUB_SHA) assert.equal(controlCommit, process.env.GITHUB_SHA);
  const workflowPath = '.github/workflows/repository-release.yml';
  const admission = {path: workflowPath, commit: controlCommit, sha256: sha256(readRegular(join(root, workflowPath), 1024 * 1024))};
  const native = manifestOperations(nativePath);
  return {client, enabled: () => publicationEnabled(client), prepare: async () => {
    const source = await currentHorosSource(client);
    assert.equal(source.commit, controlCommit, 'publication control is no longer the accepted main source');
    assert.ok(identity, 'repository-local App credential is missing');
    const actor = await appActor(identity, command);
    const boundary = await computeHorosPublicationBoundary({source}, horosBoundaryOperations({client, native, actor, command}));
    if (boundary.status !== 'ready') return {status: boundary.status, source, version: boundary.version};
    const reader = new GitHubReader('tkersey/horos', command);
    const runs = await workflowPages(reader, `actions/workflows/zig.yml/runs?head_sha=${source.commit}&event=push`, 'workflow_runs');
    assert.ok(runs.length <= 1, 'duplicate landed qualification cannot authorize publication');
    if (runs.length === 0 || runs[0].status !== 'completed') return {status: 'landed-qualification-pending', source};
    const qualification = await admitHorosQualification({runId: runs[0].id, ...source}, command);
    const manifestBytes = await sourceManifest(client, source.commit);
    const node = {name: 'node', version: process.versions.node, platform: `${process.platform}-${process.arch === 'x64' ? 'x86_64' : process.arch}`,
      sha256: sha256(readRegular(process.execPath, 256 * 1024 * 1024))};
    return {status: 'ready', ...sealHorosPublication({boundary, qualification, manifestBytes, admission, node})};
  }, verifyAttestation: async (path, record) => {
    const verified = parseEvidenceJson(await command(attestationArguments(path, record)));
    assert.ok(Array.isArray(verified) && verified.length > 0, 'publication admission attestation missing');
  }, verifyPublished: async ({release, recordBytes}) => {
    const directory = mkdtempSync(join(tmpdir(), 'horos-published-'));
    try {
      const admitted = await admitPublishedRelease({repository: 'tkersey/horos', releaseId: release.id, outputDirectory: join(directory, 'release')}, command);
      assert.equal(admitted.recordSha256, sha256(recordBytes));
      return admitted;
    } finally {rmSync(directory, {recursive: true, force: true});}
  }};
}

export async function preparePublication(directory, services) {
  if (!await services.enabled()) return {status: 'disabled',
    ...(services.disabledReason ? {reason: services.disabledReason} : {})};
  const prepared = await services.prepare();
  if (prepared.status !== 'ready') return prepared;
  const record = readRecord(prepared.recordBytes);
  mkdirSync(directory, {mode: 0o700});
  const assets = join(realpathSync(directory), 'assets'); mkdirSync(assets, {mode: 0o700});
  writeFileSync(join(assets, 'release.json'), prepared.recordBytes, {flag: 'wx', mode: 0o400});
  for (const artifact of record.artifacts) {
    const bytes = prepared.payloads.get(artifact.name);
    assert.equal(bytes.length, artifact.bytes); assert.equal(sha256(bytes), artifact.sha256);
    writeFileSync(join(assets, artifact.name), bytes, {flag: 'wx', mode: 0o400});
  }
  assert.equal(prepared.payloads.size, record.artifacts.length);
  writeFileSync(join(directory, 'plan.json'), encodeRecord({schema: 'repository-publication-plan/v1',
    source: record.source, recordSha256: sha256(prepared.recordBytes)}), {flag: 'wx', mode: 0o400});
  return {status: 'ready', source: record.source.commit, tag: record.tag, recordSha256: sha256(prepared.recordBytes)};
}

export async function publishPrepared(directory, services, publish = publishHoros) {
  const root = realpathSync(directory), assets = join(root, 'assets');
  const recordBytes = readRegular(join(assets, 'release.json'), 1024 * 1024), record = readRecord(recordBytes);
  const plan = parseEvidenceJson(readRegular(join(root, 'plan.json'), 1024 * 1024));
  assert.equal(plan.schema, 'repository-publication-plan/v1'); assert.equal(plan.recordSha256, sha256(recordBytes));
  assert.deepEqual(plan.source, record.source);
  assert.deepEqual(readdirSync(assets).sort(), ['release.json', ...record.artifacts.map(value => value.name)].sort());
  const payloads = new Map(record.artifacts.map(artifact => {
    const bytes = readRegular(join(assets, artifact.name), 512 * 1024 * 1024);
    assert.equal(bytes.length, artifact.bytes); assert.equal(sha256(bytes), artifact.sha256);
    return [artifact.name, bytes];
  }));
  const admit = async ({stage, recordBytes: actual}) => {
    assert.deepEqual(actual, recordBytes);
    await services.verifyAttestation(join(assets, 'release.json'), record);
    if (stage === 'existing') return;
    assert.equal(await services.enabled(), true, 'publication disabled');
    const current = await services.prepare();
    assert.equal(current.status, 'ready', 'frozen publication is no longer admissible');
    assert.deepEqual(current.recordBytes, recordBytes, 'original publication evidence or source changed');
    assert.deepEqual(current.payloads, payloads, 'qualified publication payload changed');
  };
  return publish({recordBytes, payloads, admit, verifyPublished: services.verifyPublished});
}

if (import.meta.main) {
  const [operation, controlDirectory, nativePath, outputDirectory, identityPath] = process.argv.slice(2);
  assert.ok(['prepare', 'publish'].includes(operation)); assert.ok(outputDirectory);
  const identity = identityPath ? parseEvidenceJson(readFileSync(resolve(identityPath))) : null;
  if (operation === 'publish') assert.ok(identity, 'repository-local App credential is missing');
  const services = publicationServices({controlDirectory, nativePath, identity});
  try {
    const result = operation === 'prepare' ? await preparePublication(resolve(outputDirectory), services) :
      await publishPrepared(resolve(outputDirectory), services);
    process.stdout.write(`${JSON.stringify(result)}\n`);
    if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `status=${result.status}\n`);
    if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `Publication: ${JSON.stringify(result)}\n`);
  } catch (error) {
    if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `Publication blocked: ${error.message}\n`);
    throw error;
  }
}
