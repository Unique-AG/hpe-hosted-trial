# Resource recommendation

## Original production profile

Paste under the Loki chart `valuesObject`:

```yaml
singleBinary:
  resources:
    limits:
      cpu: 3
      memory: 4Gi
    requests:
      cpu: 2
      memory: 2Gi
chunksCache:
  allocatedMemory: 8192
  allocatedCPU: 500m
  resources:
    requests:
      cpu: 500m
      memory: 9830Mi
    limits:
      memory: 9830Mi
```

## KinD test profile

```yaml
chunksCache:
  allocatedMemory: 512
  allocatedCPU: 100m
  resources:
    limits:
      cpu: 200m
      memory: 1Gi
    requests:
      cpu: 100m
      memory: 768Mi
singleBinary:
  resources:
    limits:
      cpu: 1
      memory: 2Gi
    requests:
      cpu: 500m
      memory: 1Gi
```
