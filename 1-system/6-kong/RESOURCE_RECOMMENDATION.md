# Resource recommendation

## Original production profile

Paste under the Kong chart `valuesObject`:

```yaml
controller:
  ingressController:
    resources:
      limits:
        memory: 500Mi
      requests:
        cpu: 300m
        memory: 300Mi
gateway:
  resources:
    limits:
      cpu: 1
      memory: 2Gi
    requests:
      cpu: 1
      memory: 2Gi
```

## KinD test profile

```yaml
gateway:
  resources:
    limits:
      cpu: 500m
      memory: 1Gi
    requests:
      cpu: 250m
      memory: 512Mi
```
