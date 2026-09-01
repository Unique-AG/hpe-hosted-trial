# Resource recommendation

## Original production profile

Paste under the Qdrant chart `valuesObject`:

```yaml
resources:
  requests:
    cpu: 500m
    memory: 6Gi
  limits:
    memory: 6Gi
```

## KinD test profile

```yaml
resources:
  requests:
    cpu: 250m
    memory: 1Gi
  limits:
    cpu: 1
    memory: 2Gi
```
