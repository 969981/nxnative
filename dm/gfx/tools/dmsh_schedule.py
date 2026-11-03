"""Bounded translation batches and dependency-ready shader finishing on one worker budget."""
from collections import defaultdict, deque
import concurrent.futures as cf
import math


def run(keys, misses, pairs, translate, finish, workers, batch_size=None):
    """Call translate(batch), then finish(key) after its translation and paired pixels finish.

    A failed shader is still a completed dependency: finish retains the builder's error
    reporting and missing-pixel policy. Results follow keys, never completion order.
    Batches amortize translator startup without holding up every shader behind the last
    large batch. Translation and finishing share the same executor, including J=1.
    """
    if workers < 1: raise ValueError('shader workers must be positive')
    keys = list(keys); wanted = set(keys); missing = set(misses)
    waiting = {k: len(set(pairs.get(k, ())) & wanted) for k in keys}
    consumers = defaultdict(list)
    for key in keys:
        for pixel in set(pairs.get(key, ())) & wanted: consumers[pixel].append(key)
    # Put dependencies first so a large tail of vertex translations cannot delay all finishing.
    ordered = [k for k in keys if k in missing and not waiting[k]] + [k for k in keys if k in missing and waiting[k]]
    size = batch_size or max(1, min(256, math.ceil(len(ordered) / (4 * workers))))
    batches = deque(ordered[i:i + size] for i in range(0, len(ordered), size))
    translated = wanted - missing
    ready = deque(k for k in keys if k in translated and not waiting[k])
    results = {}
    with cf.ThreadPoolExecutor(workers) as executor:
        active = {}
        while len(results) < len(keys):
            while len(active) < workers and (ready or batches):
                if ready:
                    key = ready.popleft(); active[executor.submit(finish, key)] = ('finish', key)
                else:
                    batch = batches.popleft(); active[executor.submit(translate, batch)] = ('translate', batch)
            if not active: raise ValueError('shader dependency cycle')
            done, _ = cf.wait(active, return_when=cf.FIRST_COMPLETED)
            for future in done:
                kind, item = active.pop(future)
                value = future.result()
                if kind == 'translate':
                    translated.update(item)
                    ready.extend(k for k in item if not waiting[k])
                else:
                    results[item] = value
                    for key in consumers[item]:
                        waiting[key] -= 1
                        if not waiting[key] and key in translated: ready.append(key)
    return [results[k] for k in keys]
