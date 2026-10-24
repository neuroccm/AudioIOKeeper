import pathlib, re, collections
source = pathlib.Path('AudioIOKeeper/KeeperEngine.swift').read_text()
def constant(name):
    return float(re.search(r'static let '+name+r'(?:\s*:\s*\w+)?\s*=\s*(\d+)', source)[1])
budget, window, base, cap = [constant(n) for n in ['immediateBudget','window','baseCooldown','maxCooldown']]
restores, cooldowns = [], []
history = []
until = None
now = 0.0
# A competitor immediately switches away after each restore. Account for the
# worker debounce on each following observation. Retry at the armed deadline.
while now < 3600:
    history = [t for t in history if now-t < window]
    if until is not None:
        if now < until:
            now = until
            continue
        until = None
        allow = True
    elif len(history) < budget:
        allow = True
    else:
        duration = min(cap, base * 2 ** (len(history)-int(budget)))
        until = now+duration
        cooldowns.append(duration)
        now = until
        continue
    if allow:
        history = [t for t in history if now-t < window]
        history.append(now)
        restores.append(now)
        now += 0.05
assert len(restores) > 3
assert max(cooldowns) < cap
assert max(cooldowns) == 32
assert min(cooldowns[20:]) < max(cooldowns)
print('Model confirms rolling-window expiry reduces cooldowns during an uninterrupted conflict.')
print('First 15 cooldowns (seconds):', cooldowns[:15])
print('Cooldown distribution:', dict(sorted(collections.Counter(cooldowns).items())))
print('Restores in 3600 simulated seconds:', len(restores))
print('Restores during final 600 simulated seconds:',sum(t >= 3000 for t in restores))
print('Maximum cooldown:',max(cooldowns),'seconds; configured cap:',cap)
print('PASS: assertions reproduce failure to reach cap, with later backoff regression.')
