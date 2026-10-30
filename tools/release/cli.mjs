import assert from 'node:assert/strict';
import {resolve} from 'node:path';
import {admitPublishedRelease} from './release-admission.mjs';
import {admitHorosQualification} from './qualification.mjs';
import {invokeOwner, readRegular} from './review-owner.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {installReviewTools} from './review-tools.mjs';

export async function main(args) {
  const [command, ...values] = args;
  if (command === 'setup-review-tools') {
    assert.equal(values.length, 1, 'usage: setup-review-tools OUTPUT_DIRECTORY');
    return installReviewTools(resolve(values[0]));
  }
  if (command === 'review-owner') {
    assert.equal(values.length, 1, 'usage: review-owner CONFIG_JSON');
    return invokeOwner(parseEvidenceJson(readRegular(resolve(values[0]), 4 * 1024 * 1024)));
  }
  if (command === 'admit-release') {
    assert.equal(values.length, 3, 'usage: admit-release OWNER/REPOSITORY RELEASE_ID OUTPUT_DIRECTORY');
    assert.match(values[1], /^[1-9][0-9]*$/);
    const admitted = await admitPublishedRelease({repository: values[0], releaseId: Number(values[1]), outputDirectory: resolve(values[2])});
    return {id: admitted.id, recordSha256: admitted.recordSha256, source: admitted.record.source,
      paths: Object.fromEntries(admitted.paths)};
  }
  if (command === 'check-qualification') {
    assert.equal(values.length, 3, 'usage: check-qualification RUN_ID COMMIT TREE');
    assert.match(values[0], /^[1-9][0-9]*$/);
    const admitted = await admitHorosQualification({runId: Number(values[0]), commit: values[1], tree: values[2]});
    return {runId: admitted.run.id, workflow: admitted.workflow, jobs: admitted.jobs.map(job => ({id: job.id, name: job.name}))};
  }
  throw new Error('expected setup-review-tools, review-owner, admit-release or check-qualification');
}

if (import.meta.main) process.stdout.write(`${JSON.stringify(await main(process.argv.slice(2)))}\n`);
