#!/usr/bin/env python3
"""Derive the hosted Azure test plan from the committed BYOC plan.

Regenerating rather than hand-editing keeps the two in step: every fix made to
plans/plan1-managed-cassandra.yaml flows into the test plan on the next run.

Set AZ_SUBSCRIPTION_ID and AZ_TENANT_ID in the environment before running. They
are read rather than hardcoded so no account identifier lands in the repository,
and the generated plan is gitignored for the same reason.
"""
import os, re, yaml, sys

SRC = 'plans/plan1-managed-cassandra.yaml'
DST = '.test/plan1-hosted.yaml'
AZ_SUB = os.environ.get('AZ_SUBSCRIPTION_ID')
AZ_TEN = os.environ.get('AZ_TENANT_ID')
if not AZ_SUB or not AZ_TEN:
    sys.exit('set AZ_SUBSCRIPTION_ID and AZ_TENANT_ID in the environment')
DEAD = {'backupBucketName','backupRegion','backupStorageProvider',
        'backupCredentialsType','medusaStorageAccount','medusaStorageKey'}

s = open(SRC).read()

# hosted on the onboarded Azure subscription, replacing the byoa block
lines, out, i = s.split('\n'), [], 0
while i < len(lines):
    if lines[i].startswith('deployment:'):
        out += ['deployment:',
                '  hostedDeployment:',
                f'    azureSubscriptionId: "{AZ_SUB}"',
                f'    azureTenantId: "{AZ_TEN}"']
        i += 1
        while i < len(lines) and (lines[i].startswith((' ','\t','#')) or not lines[i].strip()):
            if not lines[i].strip() and i+1 < len(lines) and not lines[i+1].startswith((' ','\t','#')):
                break
            i += 1
        continue
    out.append(lines[i]); i += 1
s = '\n'.join(out)

s = s.replace('name: Managed Cassandra\n', 'name: Managed Cassandra Hosted Test\n', 1)
s = s.replace('REPLACE_ME_STRIPE_PRODUCT_ID', 'prod_test_placeholder')
s = s.replace('name: Standard_E4as_v5', 'name: Standard_D4as_v7')
s = s.replace('enableDeletionProtection: true', 'enableDeletionProtection: false')
s = s.replace('enableMultiZone: true', 'enableMultiZone: false')
# single unpinned rack: one node, and the AZ-label question stays out of the way
s = re.sub(r'(\n\s*)racks:\n(?:\s*- name: rack\d\n(?:\s*nodeAffinityLabels:\n)?(?:\s*topology\.kubernetes\.io/zone:.*\n)?)+',
           lambda m: f"{m.group(1)}racks:\n{m.group(1)}  - name: rack1\n", s)
s = re.sub(r'\nbillingProviders:\n(?:  .*\n|    .*\n)+', '\n', s)
# medusa needs a real bucket, so it is out of scope for this stage
s = re.sub(r'\n(\s*)medusa:\n(?:\1  .*\n|\1    .*\n|\1      .*\n)+', '\n', s)
s = re.sub(r'\n      backupConfiguration:\n(?:        .*\n)+', '\n', s)

d = yaml.safe_load(s)
svc = d['services'][0]
for verb in ('backup','restore','deleteBackup'):
    svc['systemWorkflows'].pop(verb, None)
svc['apiParameters'] = [p for p in svc['apiParameters'] if p['key'] not in DEAD]
# the operator and its CRDs are a deployment-cell amenity
svc['operatorCRDConfiguration']['helmChartDependencies'] = []
# drop every workflow parameter that referenced a removed apiParameter
def strip(n):
    if isinstance(n, dict):
        for k, v in list(n.items()):
            if k == 'parameters' and isinstance(v, list):
                n[k] = [e for e in v if not (isinstance(e, dict) and e.get('name') in DEAD)]
                if not n[k]: del n[k]
            else: strip(v)
    elif isinstance(n, list):
        for v in n: strip(v)
strip(svc['systemWorkflows'])
# smallest shape that still exercises the operator
SMALL = {'clusterSize': '1', 'storageSizeGi': '32', 'heapSizeGi': '2'}
for p in svc['apiParameters']:
    if p['key'] in SMALL:
        p['defaultValue'] = SMALL[p['key']]

open(DST,'w').write(yaml.safe_dump(d, sort_keys=False, width=200))

# invariants the platform will not check for us
txt = yaml.safe_dump(svc['systemWorkflows'])
declared = {p['key'] for p in svc['apiParameters']}
undeclared = set(re.findall(r'\$var\.(\w+)', txt)) - declared - {'failedReplicaId'}
assert not undeclared, f"workflow references undeclared apiParameters: {sorted(undeclared)}"

# customWorkflows carry their own apiParameters list, so they need the same
# check against that list rather than the service's.
for cw in svc.get('customWorkflows', []):
    own = {p['key'] for p in cw.get('apiParameters', [])} | declared
    refs = set(re.findall(r'\$var\.(\w+)', yaml.safe_dump(cw['workflow'])))
    missing = refs - own
    assert not missing, \
        f"customWorkflow {cw['verb']} references undeclared apiParameters: {sorted(missing)}"

# cass-operator takes twelve job commands and types the field as a free-form
# string, so an unsupported value is accepted by the API server and only shows
# up as "unknown job command" in the operator log while the CR sits at active=1.
CASS_TASK_COMMANDS = {
    'cleanup', 'rebuild', 'rolling_restart', 'replacenode', 'upgradesstables',
    'scrub', 'compaction', 'move', 'flush', 'garbagecollect', 'refresh',
    'ts_reload',
}
for wf in list(svc.get('systemWorkflows', {}).values()) + \
          [c['workflow'] for c in svc.get('customWorkflows', [])]:
    for t in wf.get('templates', []):
        man = t.get('resource', {}).get('manifest', '')
        if 'kind: CassandraTask' not in man:
            continue
        for cmd in re.findall(r'^\s*command:\s*(\S+)\s*$', man, re.M):
            assert cmd in CASS_TASK_COMMANDS, \
                f"CassandraTask command {cmd!r} is not one of {sorted(CASS_TASK_COMMANDS)}"

body = open(DST).read().replace('\\"', '"')
assert 'size: "{{inputs.parameters.clusterSize}}"' not in body, \
    "datacenters[].size must be an unquoted integer; the CRD rejects a string"
print(f"wrote {DST}")
print(f"  verbs: {sorted(svc['systemWorkflows'])}")
print(f"  custom: {[c['verb'] for c in svc.get('customWorkflows', [])]}")
print(f"  params: {sorted(declared)}")
