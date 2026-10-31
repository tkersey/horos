export function ownerCapture(output, commands = []) {
  const final = Buffer.from(JSON.stringify(output));
  const events = [{type: 'thread.started', thread_id: 'owner-retention-test'},
    ...commands.flatMap(item => [{type: 'item.started', item: {...item, status: 'in_progress', aggregated_output: ''}},
      {type: 'item.completed', item}]),
    {type: 'item.completed', item: {id: 'final', type: 'agent_message', text: final.toString()}},
    {type: 'turn.completed'}];
  return {events: Buffer.from(events.map(event => JSON.stringify(event)).join('\n') + '\n'), final};
}

export function reviewCommand(output, name, bytes, index = 0) {
  return {id: `command-${index}`, type: 'command_execution', status: 'completed', exit_code: 0,
    command: `/tools/cas review start --wait --json --cwd /candidate --base ${output.base} --codex-path /tools/codex --thread-start-params-json @/capture/settings.json --store-root /owner/cas --workflow-binding-json @/owner/${name}.binding`,
    aggregated_output: bytes.toString()};
}

export function ownerCaptures(output, receipts) {
  return output.requests.map((request, index) => {
    const current = {...output, requests: output.requests.slice(0, index + 1),
      status: index === output.requests.length - 1 ? output.status : 'pending',
      epochClosed: index === output.requests.length - 1 ? output.epochClosed : false};
    const capture = ownerCapture(current, [reviewCommand(output, request.receipt, receipts.get(request.receipt), index)]);
    return {events: capture.events.toString('base64'), final: capture.final.toString('base64')};
  });
}
