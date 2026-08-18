# Resource recommendation

## Original production profile

Paste under the MinIO chart `valuesObject`:

```yaml
resources:
  requests:
    cpu: 2
    memory: 16Gi
  limits:
    cpu: 4
    memory: 18Gi
```

## KinD test profile

```yaml
resources:
  requests:
    cpu: 500m
    memory: 2Gi
  limits:
    cpu: 1
    memory: 4Gi
```
