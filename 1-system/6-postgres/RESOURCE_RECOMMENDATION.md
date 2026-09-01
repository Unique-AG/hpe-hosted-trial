# Resource recommendation

## Original production profile

Paste under the CloudNativePG `spec.resources` field:

```yaml
resources:
  limits:
    cpu: 4
    memory: 32Gi
  requests:
    cpu: 2
    memory: 28Gi
```

## KinD test profile

```yaml
resources:
  limits:
    cpu: 2
    memory: 8Gi
  requests:
    cpu: 1
    memory: 4Gi
```
