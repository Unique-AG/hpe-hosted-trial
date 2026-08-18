# Resource recommendation

## Original production profile

Paste into the Redis custom resource:

```yaml
kubernetesConfig:
  resources:
    limits:
      memory: 2Gi
    requests:
      cpu: 500m
      memory: 2Gi
redisExporter:
  resources:
    limits:
      cpu: 100m
      memory: 128Mi
    requests:
      cpu: 50m
      memory: 64Mi
```

## KinD test profile

```yaml
kubernetesConfig:
  resources:
    limits:
      cpu: 1
      memory: 1Gi
    requests:
      cpu: 250m
      memory: 512Mi
redisExporter:
  resources:
    limits:
      cpu: 100m
      memory: 128Mi
    requests:
      cpu: 50m
      memory: 64Mi
```
