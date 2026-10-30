import {repositories} from './record.mjs';

const commit = 'a'.repeat(40), tree = 'b'.repeat(40), hash = 'c'.repeat(64);
const tool = {name: 'zig', version: '0.17.0', platform: 'linux-x86_64', sha256: hash};

function source(name = 'horos') {
  return {commit, tree, version: '1.0.0', manifestSha256: hash,
    packageIdentity: `${name}-1.0.0-${'a'.repeat(44)}`, lockSha256: name === 'protean' ? hash : null};
}

export function metadata(name = 'horos') {
  const repository = `tkersey/${name}`;
  return {
    schema: 'repository-release/v1', repository: {name: repository, id: repositories[repository]},
    source: source(name), tag: 'v1.0.0',
    admission: {workflow: {path: '.github/workflows/repository-release.yml', commit, sha256: hash}},
    dependencies: (name === 'horos' ? [] : name === 'kosmos' ? ['horos'] : ['horos', 'kosmos']).map(upstream => ({
      repository: {name: `tkersey/${upstream}`, id: repositories[`tkersey/${upstream}`]}, source: source(upstream),
      release: {id: 1, tag: 'v1.0.0', recordSha256: hash},
    })),
    artifacts: [
      {name: 'source.tar', role: 'source', platform: null, bytes: 1, sha256: hash},
      {name: 'inventory.json', role: 'inventory', platform: null, bytes: 1, sha256: hash},
      {name: 'evidence.json', role: 'evidence', platform: null, bytes: 1, sha256: hash},
    ],
    qualification: {
      workflow: {path: '.github/workflows/zig.yml', commit, sha256: hash},
      run: {id: 1, attempt: 1, event: 'push', commit, tree},
      results: [{platform: 'linux-x86_64', profile: 'safe', evidence: 'evidence.json'}],
      aggregate: {name: 'native', evidence: 'evidence.json'},
    },
    review: {
      owner: 'actuating', executionMode: 'cas',
      policy: {repository: 'tkersey/dotfiles', definition: {path: 'agents/skills/actuating/references/review-contract.json', commit, sha256: hash}},
      tools: [{...tool, name: 'cas', version: '0.8.4'}], subject: {base: commit, head: commit, tree},
      landing: {commit, tree, evidence: 'evidence.json'}, closeout: 'evidence.json', originalEvidence: ['evidence.json'],
    },
    compatibility: {impact: 'patch', disposition: 'compatible', rationale: 'Test-only metadata.', contracts: ['test'], evidence: 'evidence.json'},
    toolchains: [tool],
  };
}
