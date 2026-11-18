#!/usr/bin/env python3
"""Offline frame/event correlation. No capture APIs; retains every scheduled event."""
import argparse
import csv
import json
from pathlib import Path

def correlate(events, frames, numer, denom):
    ordered = []
    previous = -1
    out_of_order = 0
    for frame in frames:
        try:
            time = int(frame['display_ticks'])
        except (ValueError, KeyError):
            continue
        if time < previous:
            out_of_order += 1
            continue
        previous = time
        if frame.get('status') == '0':
            ordered.append(frame)
    result = []
    for i, event in enumerate(events):
        row = dict(event)
        if not event.get('input_ticks'):
            row['observation'] = 'not-delivered'
        elif event.get('status') == 'aborted':
            row['observation'] = 'aborted'
        else:
            start, end = int(event['input_ticks']), int(event['deadline_ticks'])
            # New input supersedes the prior result's observation window.
            next_input = next((int(e['input_ticks']) for e in events[i+1:] if e.get('input_ticks')), None)
            if next_input is not None:
                end = min(end, next_input)
            matching = [f for f in ordered if start <= int(f['display_ticks']) < end and
                        all(f.get(k) == event.get(k) for k in ('run', 'show', 'revision')) and
                        f.get('digest') == event.get('expected_digest')]
            if matching:
                first = int(matching[0]['display_ticks'])
                row['observation'] = 'presented'
                row['first_frame_ticks'] = str(first)
                row['input_to_observed_frame_ms'] = (first-start) * numer / denom / 1e6
            else:
                row['observation'] = 'superseded' if next_input is not None and next_input <= int(event['deadline_ticks']) else 'timed-out'
        result.append(row)
    times = [int(f['display_ticks']) for f in ordered]
    gaps = [(b-a)*numer/denom/1e6 for a,b in zip(times,times[1:])]
    return {'events': result, 'out_of_order_frames': out_of_order, 'complete_frames': len(ordered),
            'max_complete_frame_gap_ms': max(gaps, default=None),
            'budget_verdict': 'Untested: live composition/calibration and capture perturbation must be checked; missing events and cadence uncertainty prevent a completed-only pass'}

def self_test():
    events = [dict(event=str(i), run='1', show='1', revision=str(i), expected_digest=str(10+i),
                   input_ticks=str(i*100), deadline_ticks=str(i*100+90), status='view-state') for i in range(4)]
    frames = [dict(display_ticks=str(t), status='0', run=run, show='1', revision=str(i), digest=str(d))
              for t,run,i,d in [(10,'9',0,10), (20,'1',0,999), (30,'1',0,10), (40,'1',0,10),
                               (35,'1',1,11), (150,'1',1,11), (299,'1',2,12)]]
    result = correlate(events, frames, 1, 1)
    assert [e['observation'] for e in result['events']] == ['presented','presented','timed-out','timed-out']
    assert result['out_of_order_frames'] == 1
    assert result['events'][0]['first_frame_ticks'] == '30'
    # A short interval really is censored by the next input, not removed.
    events[1]['input_ticks'] = '50'
    assert correlate(events, frames[:2], 1, 1)['events'][0]['observation'] == 'superseded'
    print('Passed: stale/corrupt identity, duplicate, out-of-order, drops, supersession, deadline and full denominator')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--events', type=Path)
    parser.add_argument('--frames', type=Path)
    parser.add_argument('--observer', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        assert all([args.events,args.frames,args.observer,args.output]) and not args.output.exists()
        receipt = json.loads(args.observer.read_text())
        report = correlate(list(csv.DictReader(args.events.open())), list(csv.DictReader(args.frames.open())),
                           receipt['timebase_numer'], receipt['timebase_denom'])
        args.output.write_text(json.dumps(report, indent=2)+'\n')
